import DBKit
import Foundation
import Testing
@testable import AppCore

private func tempDB(rows: Int) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "tabula-\(UUID().uuidString).db")
    // Created through the driver directly; the factory refuses missing files.
    let config = ConnectionConfig(filePath: url.path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let db = try await ConnectionFactory.open(config)
    _ = try await db.transaction([
        SQLStatement("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)"),
        SQLStatement("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rows))
            INSERT INTO t SELECT i, 'row ' || i FROM n
            """),
    ])
    await db.close()
    return url
}

@Suite struct ConnectionFactoryTests {
    @Test func refusesMissingFile() async {
        let config = ConnectionConfig(filePath: "/nonexistent/\(UUID().uuidString).db")
        await #expect(throws: DatabaseError.self) { try await ConnectionFactory.test(config) }
        #expect(!FileManager.default.fileExists(atPath: config.filePath))
    }

    @Test func refusesFolder() async {
        let config = ConnectionConfig(filePath: FileManager.default.temporaryDirectory.path)
        await #expect(throws: DatabaseError.self) { try await ConnectionFactory.test(config) }
    }

    @Test func refusesNonDatabaseFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tabula-\(UUID().uuidString).txt")
        try Data(String(repeating: "definitely not sqlite ", count: 100).utf8).write(to: url)
        await #expect(throws: DatabaseError.self) {
            try await ConnectionFactory.test(ConnectionConfig(filePath: url.path))
        }
    }

    @Test func readOnlyRejectsWrites() async throws {
        let url = try await tempDB(rows: 1)
        let db = try await ConnectionFactory.open(ConnectionConfig(filePath: url.path, readOnly: true))
        await #expect(throws: DatabaseError.self) { _ = try await db.execute("DELETE FROM t") }
        await db.close()
    }
}

@MainActor
@Suite struct TableBrowserTests {
    @Test func countsAndFetchesBlocks() async throws {
        let url = try await tempDB(rows: 2500)
        let db = try await ConnectionFactory.open(ConnectionConfig(filePath: url.path))
        let browser = try await TableBrowser.open(TableRef("t"), on: db)
        #expect(browser.columns.map(\.name) == ["id", "label"])
        #expect(try await browser.count() == 2500)

        let rows = try await browser.fetcher()(2000, 500)
        #expect(rows.count == 500)
        #expect(rows.first == [.integer(2001), .text("row 2001")])
        #expect(rows.last == [.integer(2500), .text("row 2500")])
        await db.close()
    }

    @Test func cellText() {
        #expect(CellText.display(.null) == nil)
        #expect(CellText.display(.text("a\nb\tc")) == "a b c")
        let long = CellText.display(.text(String(repeating: "x", count: 1000)))
        #expect(long?.count == CellText.maxLength + 1)
        #expect(long?.hasSuffix("…") == true)
        #expect(CellText.tsv([[.integer(1), .null, .text("a\tb")]]) == "1\t\ta b")
    }
}
