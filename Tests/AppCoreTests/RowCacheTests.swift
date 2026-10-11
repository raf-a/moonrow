import DBKit
import Foundation
import Testing
@testable import AppCore

/// Records every fetch and answers with rows whose only value is their index.
private actor FakeTable {
    let rowCount: Int
    var calls: [Int] = []
    var failAt: Int?

    init(rowCount: Int, failAt: Int? = nil) {
        self.rowCount = rowCount
        self.failAt = failAt
    }

    func fetch(_ offset: Int, _ limit: Int) throws -> [[DBValue]] {
        calls.append(offset)
        if offset == failAt { throw DatabaseError("boom") }
        return (offset..<min(offset + limit, rowCount)).map { [.integer(Int64($0))] }
    }
}

@MainActor
private func makeCache(_ table: FakeTable, blockSize: Int = 10, maxBlocks: Int = 4) -> RowCache {
    RowCache(rowCount: table.rowCount, blockSize: blockSize, maxBlocks: maxBlocks) { offset, limit in
        try await table.fetch(offset, limit)
    }
}

@MainActor
private func settle(_ cache: RowCache) async throws {
    let deadline = Date().addingTimeInterval(5)
    while cache.isLoading {
        guard Date() < deadline else { throw DatabaseError("cache never settled") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Suite struct RowCacheTests {
    @Test func loadsVisibleBlocksThenNeighbours() async throws {
        let table = FakeTable(rowCount: 100)
        let cache = makeCache(table)
        #expect(cache.row(at: 25) == nil)

        cache.setVisibleRows(25..<35)
        try await settle(cache)

        // Blocks 2 and 3 are on screen; 4 below and 1 above are prefetched, in that order.
        #expect(await table.calls == [20, 30, 40, 10])
        #expect(cache.row(at: 25) == [.integer(25)])
        #expect(cache.row(at: 49) == [.integer(49)])
        #expect(cache.row(at: 50) == nil)
    }

    @Test func reportsLoadedRanges() async throws {
        let table = FakeTable(rowCount: 15)
        let cache = makeCache(table)
        var loaded: [Range<Int>] = []
        cache.onLoad = { loaded.append($0) }

        cache.setVisibleRows(0..<5)
        try await settle(cache)

        // The last block is short and its range stops at the row count.
        #expect(loaded == [0..<10, 10..<15])
    }

    @Test func evictsLeastRecentlySeenButNeverVisible() async throws {
        let table = FakeTable(rowCount: 1000)
        let cache = makeCache(table, maxBlocks: 4)

        cache.setVisibleRows(0..<10)
        try await settle(cache)
        cache.setVisibleRows(500..<510)
        try await settle(cache)

        // Loading 49 made five blocks; block 0 was seen longest ago, so it went.
        #expect(cache.loadedBlocks == [1, 49, 50, 51])
    }

    @Test func clampsToRowCount() async throws {
        let table = FakeTable(rowCount: 5)
        let cache = makeCache(table)
        cache.setVisibleRows(0..<50)
        try await settle(cache)
        #expect(await table.calls == [0])
        #expect(cache.row(at: 4) == [.integer(4)])
    }

    @Test func emptyTableNeverFetches() async throws {
        let table = FakeTable(rowCount: 0)
        let cache = makeCache(table)
        cache.setVisibleRows(0..<20)
        try await settle(cache)
        #expect(await table.calls.isEmpty)
    }

    @Test func stopsAfterAnError() async throws {
        let table = FakeTable(rowCount: 100, failAt: 30)
        let cache = makeCache(table)
        var errors = 0
        cache.onError = { _ in errors += 1 }

        cache.setVisibleRows(25..<35)
        try await settle(cache)
        cache.setVisibleRows(60..<70)
        try await settle(cache)

        #expect(errors == 1)
        #expect(await table.calls == [20, 30])
    }

    @Test func rowsUsesCacheOrFetchesOnce() async throws {
        let table = FakeTable(rowCount: 100)
        let cache = makeCache(table)
        cache.setVisibleRows(0..<5)
        try await settle(cache)
        let before = await table.calls.count

        #expect(try await cache.rows(2..<4) == [[.integer(2)], [.integer(3)]])
        #expect(await table.calls.count == before)

        #expect(try await cache.rows(70..<72) == [[.integer(70)], [.integer(71)]])
        #expect(await table.calls.last == 70)
    }
}
