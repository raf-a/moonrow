import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "tabula-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
@Suite struct QueryHistoryTests {
    @Test func newestFirstOncePerStatement() {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "select 1", date: Date(timeIntervalSince1970: 1)))
        history.add(.init(sql: "  select 2\n", date: Date(timeIntervalSince1970: 2), ms: 5))
        history.add(.init(sql: "select 1", date: Date(timeIntervalSince1970: 3), ok: false))
        history.add(.init(sql: "   "))
        #expect(history.entries.map(\.sql) == ["select 1", "select 2"])
        #expect(history.entries[0].ok == false)

        let reloaded = QueryHistory(fileURL: url)
        #expect(reloaded.entries == history.entries)
        #expect(reloaded.entries[1].ms == 5)
    }

    @Test func multiLineStatementsSurviveAndSearchIgnoresCase() {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "SELECT *\nFROM Users\nWHERE id = 1"))
        history.add(.init(sql: "select * from orders"))
        let reloaded = QueryHistory(fileURL: url)
        #expect(reloaded.search("from users").map(\.sql) == ["SELECT *\nFROM Users\nWHERE id = 1"])
        #expect(reloaded.search("").count == 2)
    }

    @Test func compactsPastTheLimit() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url, limit: 10)
        for i in 0..<30 { history.add(.init(sql: "select \(i)")) }
        #expect(history.entries.count == 10)
        #expect(history.entries.first?.sql == "select 29")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count <= 11)
        #expect(QueryHistory(fileURL: url, limit: 10).entries.map(\.sql) == history.entries.map(\.sql))
    }

    @Test func skipsUnreadableLines() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "select 1"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        history.add(.init(sql: "select 2"))
        #expect(QueryHistory(fileURL: url).entries.map(\.sql) == ["select 2", "select 1"])
    }

    @Test func removeAndClear() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "a"))
        history.add(.init(sql: "b"))
        try history.remove(history.entries[0])
        #expect(QueryHistory(fileURL: url).entries.map(\.sql) == ["a"])
        try history.clear()
        #expect(QueryHistory(fileURL: url).entries.isEmpty)
    }
}

@MainActor
@Suite struct SavedQueriesTests {
    @Test func saveListRenameDelete() throws {
        let store = SavedQueries(directory: tempDir())
        #expect(store.queries.isEmpty)
        let q = try store.save("select 1", as: "Daily totals")
        try store.save("select 2", as: "active users.sql")
        #expect(store.queries.map(\.name) == ["active users", "Daily totals"])
        #expect(try store.text(of: q) == "select 1")

        #expect(throws: SavedQueries.StoreError.self) { try store.save("x", as: "daily totals") }
        try store.save("select 3", as: "Daily totals", overwrite: true)
        #expect(try store.text(of: store.query(named: "Daily totals")!) == "select 3")

        let renamed = try store.rename(store.query(named: "Daily totals")!, to: "Totals by day")
        #expect(store.queries.map(\.name) == ["active users", "Totals by day"])
        #expect(throws: SavedQueries.StoreError.self) { try store.rename(renamed, to: "Active Users") }
        // Changing only the case is allowed.
        try store.rename(renamed, to: "totals by day")
        #expect(store.queries.map(\.name) == ["active users", "totals by day"])

        try store.delete(store.queries[0])
        #expect(store.queries.map(\.name) == ["totals by day"])
    }

    @Test func fileNames() {
        #expect(SavedQueries.fileName(for: "  a/b:c  ") == "a-b-c")
        #expect(SavedQueries.fileName(for: "..hidden.sql") == "hidden")
        #expect(SavedQueries.fileName(for: " ") == "")
        #expect(throws: SavedQueries.StoreError.self) { try SavedQueries(directory: tempDir()).save("x", as: "...") }
    }
}

@MainActor
@Suite struct SchemaCatalogTests {
    @Test func loadsColumnsOnDemand() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        _ = try await db.execute("CREATE TABLE users (id INTEGER, email TEXT)")
        let catalog = SchemaCatalog(connection: db)
        catalog.setObjects(try await db.objects(schema: nil))
        #expect(catalog.completionCatalog.tables == ["users"])
        var changes = 0
        catalog.onChange = { changes += 1 }
        catalog.loadColumns(of: ["USERS", "missing"])
        catalog.loadColumns(of: ["users"])
        await catalog.idle()
        #expect(changes == 1)
        #expect(catalog.completionCatalog.columns(of: "Users") == ["id", "email"])
    }
}
