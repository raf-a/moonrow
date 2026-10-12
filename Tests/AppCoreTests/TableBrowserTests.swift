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

        let rows = try await browser.fetcher(GridQuery(page: Paging(pageSize: nil)))(2000, 500)
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

/// Which SQL the grid sends to page and count.
@MainActor
@Suite struct BrowseSQLTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "int", primaryKeyPosition: 1),
        ColumnInfo(name: "name", typeName: "text"),
    ]

    @Test func unsortedPagesAreOrderedByKeyOnServers() {
        let page = GridQuery(page: Paging(pageSize: 300, offset: 300))
        func select(_ d: any Dialect, _ columns: [ColumnInfo]) -> String {
            let b = TableBrowser(connection: ScriptedConnection(d), table: TableRef("big"), columns: columns)
            return b.select(page, offset: 0, limit: 300).inlined(for: d)
        }
        #expect(select(MySQLDialect(), columns) == "SELECT * FROM `big` ORDER BY `id` ASC LIMIT 300 OFFSET 300")
        #expect(select(PostgresDialect(), columns) == #"SELECT * FROM "big" ORDER BY "id" ASC LIMIT 300 OFFSET 300"#)
        #expect(select(SQLiteDialect(), columns) == #"SELECT * FROM "big" LIMIT 300 OFFSET 300"#)
        // Without a key nothing orders the page.
        let heap = columns.map { var c = $0; c.primaryKeyPosition = nil; return c }
        #expect(select(MySQLDialect(), heap) == "SELECT * FROM `big` LIMIT 300 OFFSET 300")
        // A sort replaces the key order.
        var sorted = page
        sorted.sort = [SortKey("name", ascending: false)]
        let b = TableBrowser(connection: ScriptedConnection(MySQLDialect()), table: TableRef("big"), columns: columns)
        #expect(b.select(sorted, offset: 0, limit: 10).inlined(for: MySQLDialect())
                == "SELECT * FROM `big` ORDER BY `name` DESC LIMIT 10 OFFSET 300")
    }

    private func count(estimate: Int64?, filter: Filter? = nil, dialect: any Dialect = PostgresDialect(),
                       estimateFails: Bool = false) async throws -> (RowCount, [String]) {
        var answers: [(String, Result<QueryResult, DatabaseError>)] = [("SELECT COUNT(*)", ScriptedConnection.rows([[.integer(42)]]))]
        if estimateFails {
            answers.append(("SELECT reltuples", .failure(DatabaseError("relation does not exist"))))
        } else if let estimate {
            answers.append(("SELECT reltuples", ScriptedConnection.rows([[.integer(estimate)]])))
        }
        let db = ScriptedConnection(dialect, table: TableRef(schema: "public", "big"), columns: columns, answers: answers)
        let b = TableBrowser(connection: db, table: TableRef(schema: "public", "big"), columns: columns)
        return (try await b.rowCount(filter: filter), db.sent)
    }

    @Test func largePostgresTablesShowTheEstimate() async throws {
        let (big, sent) = try await count(estimate: 1_000_000)
        #expect(big == RowCount(1_000_000, isEstimate: true))
        #expect(sent == [#"SELECT reltuples::bigint FROM pg_class WHERE oid = '"public"."big"'::regclass"#])
        #expect(Paging(pageSize: 300).describe(total: big.value, estimated: true).hasSuffix("of ~\(1_000_000.formatted(.number))"))
    }

    @Test func smallFilteredOrUnknownTablesAreCounted() async throws {
        // 999,999 estimated rows are counted; estimates start at 1,000,000.
        #expect(try await count(estimate: 999_999).0 == RowCount(42))
        #expect(try await count(estimate: 99_999).0 == RowCount(42))
        #expect(try await count(estimate: -1).0 == RowCount(42))   // never analyzed
        #expect(try await count(estimate: nil, estimateFails: true).0 == RowCount(42))

        let filtered = Filter([.init(.column("name"), .equal, "a")])
        let (n, sent) = try await count(estimate: 1_000_000, filter: filtered)
        #expect(n == RowCount(42))
        #expect(sent == [#"SELECT COUNT(*) FROM "public"."big" WHERE "name" = 'a'"#])

        let (my, mySent) = try await count(estimate: 1_000_000, dialect: MySQLDialect())
        #expect(my == RowCount(42))
        #expect(mySent == ["SELECT COUNT(*) FROM `public`.`big`"])
    }
}
