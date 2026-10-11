import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

/// M2's acceptance check: for every way the grid can edit a table, the SQL shown in the commit
/// preview is exactly what SQLite reports running (its statement trace, values expanded inline).
@Suite struct EditRoundTripTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func write(_ s: String) { lock.withLock { lines.append(s) } }
        func take() -> [String] { lock.withLock { defer { lines = [] }; return lines } }
    }

    private struct Fixture {
        let db: SQLiteConnection
        let log = Log()

        init() async throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "tabula-\(UUID().uuidString).db")
            db = try SQLiteConnection(path: url.path)
            _ = try await db.transaction([
                SQLStatement("""
                    CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER DEFAULT 0,
                      price REAL, note TEXT DEFAULT 'none', added TEXT DEFAULT CURRENT_TIMESTAMP)
                    """),
                SQLStatement("""
                    INSERT INTO items (id, name, qty, price, note) VALUES
                      (1, 'apple', 3, 1.5, 'red'), (2, 'pear', 5, NULL, 'it''s green'), (3, 'fig', 0, 2.25, NULL)
                    """),
                SQLStatement("CREATE TABLE nokey (a TEXT, b INTEGER)"),
                SQLStatement("INSERT INTO nokey VALUES ('x', 1), ('y', 2), ('y', 2)"),
            ])
            let log = log
            await db.setStatementLog { log.write($0) }
        }

        func browser(_ table: String) async throws -> (TableBrowser, [[DBValue]]) {
            let browser = try await TableBrowser.open(TableRef(table), on: db)
            let rows = try await browser.fetcher(GridQuery(sort: [SortKey("rowid")]))(0, 100)
            return (browser, rows)
        }

        /// Commits, and returns what the preview showed next to what the database ran.
        func commit(_ browser: TableBrowser, _ edits: StagedEdits) async throws -> (preview: [String], ran: [String]) {
            let preview = browser.preview(edits).map { String($0.dropLast()) }
            _ = log.take()
            try await browser.commit(edits)
            let ran = log.take().filter { !["BEGIN", "COMMIT", "ROLLBACK"].contains($0) }
            return (preview, ran)
        }

        func rows(_ sql: String) async throws -> [[DBValue]] {
            try await db.execute(sql).rows
        }
    }

    @Test func cellEdits() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("items")
        var e = StagedEdits(baseRowCount: rows.count)
        e.set(.value(CellInput.parse("plum's", typeName: "TEXT")), row: 0, column: 1, original: rows[0])
        e.set(.value(CellInput.parse("7", typeName: "INTEGER")), row: 0, column: 2, original: rows[0])
        e.set(.value(CellInput.parse("0.75", typeName: "REAL")), row: 0, column: 3, original: rows[0])
        e.set(.value(.null), row: 1, column: 4, original: rows[1])         // Set Value ▸ NULL
        e.set(.value(.text("")), row: 2, column: 1, original: rows[2])     // Set Value ▸ EMPTY
        e.set(.defaultValue, row: 2, column: 4, original: rows[2])         // Set Value ▸ DEFAULT
        e.set(.defaultValue, row: 1, column: 5, original: rows[1])         // DEFAULT CURRENT_TIMESTAMP

        let (preview, ran) = try await f.commit(b, e)
        #expect(preview == [
            #"UPDATE "items" SET "name" = 'plum''s', "qty" = 7, "price" = 0.75 WHERE "id" = 1"#,
            #"UPDATE "items" SET "note" = NULL, "added" = CURRENT_TIMESTAMP WHERE "id" = 2"#,
            #"UPDATE "items" SET "name" = '', "note" = ('none') WHERE "id" = 3"#,
        ])
        #expect(ran == preview)
        #expect(try await f.rows("SELECT name, qty, price, note FROM items ORDER BY id") == [
            [.text("plum's"), .integer(7), .double(0.75), .text("red")],
            [.text("pear"), .integer(5), .null, .null],
            [.text(""), .integer(0), .double(2.25), .text("none")],
        ])
    }

    @Test func editingThePrimaryKey() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("items")
        var e = StagedEdits(baseRowCount: rows.count)
        e.set(.value(.integer(10)), row: 1, column: 0, original: rows[1])
        let (preview, ran) = try await f.commit(b, e)
        #expect(preview == [#"UPDATE "items" SET "id" = 10 WHERE "id" = 2"#])
        #expect(ran == preview)
        #expect(try await f.rows("SELECT id FROM items ORDER BY id") == [[.integer(1)], [.integer(3)], [.integer(10)]])
    }

    @Test func insertDuplicateAndDelete() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("items")
        var e = StagedEdits(baseRowCount: rows.count)
        e.addRow([1: .value(.text("kiwi")), 2: .value(.integer(4))])
        e.addRow([1: .value(.text("blank"))])
        // Duplicate: every value but the primary key, which takes its default.
        let pk = Set(b.columns.indices.filter { b.columns[$0].primaryKeyPosition != nil })
        e.addRow(Dictionary(uniqueKeysWithValues: rows[0].indices.filter { !pk.contains($0) }.map { ($0, CellChange.value(rows[0][$0])) }))
        e.delete(rows: [2], original: { rows[$0] })

        let (preview, ran) = try await f.commit(b, e)
        #expect(preview.count == 4)
        #expect(preview[0] == #"DELETE FROM "items" WHERE "id" = 3"#)
        #expect(preview[1] == #"INSERT INTO "items" ("name", "qty") VALUES ('kiwi', 4)"#)
        #expect(ran == preview)
        #expect(try await f.rows("SELECT name, qty, note FROM items ORDER BY id") == [
            [.text("apple"), .integer(3), .text("red")],
            [.text("pear"), .integer(5), .text("it's green")],
            [.text("kiwi"), .integer(4), .text("none")],
            [.text("blank"), .integer(0), .text("none")],
            [.text("apple"), .integer(3), .text("red")],
        ])
    }

    @Test func insertWithEveryColumnDefault() async throws {
        let f = try await Fixture()
        _ = try await f.db.execute("CREATE TABLE d (id INTEGER PRIMARY KEY, v TEXT DEFAULT 'x')")
        let (b, rows) = try await f.browser("d")
        var e = StagedEdits(baseRowCount: rows.count)
        e.addRow()
        let (preview, ran) = try await f.commit(b, e)
        #expect(preview == [#"INSERT INTO "d" DEFAULT VALUES"#])
        #expect(ran == preview)
    }

    @Test func tableWithoutPrimaryKey() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("nokey")
        #expect(!b.hasPrimaryKey)
        var e = StagedEdits(baseRowCount: rows.count)
        e.set(.value(.text("z")), row: 0, column: 0, original: rows[0])
        let (preview, ran) = try await f.commit(b, e)
        #expect(preview == [#"UPDATE "nokey" SET "a" = 'z' WHERE "a" = 'x' AND "b" = 1"#])
        #expect(ran == preview)
    }

    @Test func duplicateRowsAreNotTouched() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("nokey")
        var e = StagedEdits(baseRowCount: rows.count)
        e.set(.value(.text("first")), row: 0, column: 0, original: rows[0])
        e.delete(rows: [1], original: { rows[$0] })   // matches both ('y', 2) rows
        await #expect(throws: DatabaseError.self) { try await b.commit(e) }
        // Rolled back, including the statement that succeeded.
        #expect(try await f.rows("SELECT a FROM nokey ORDER BY rowid") == [[.text("x")], [.text("y")], [.text("y")]])
    }

    @Test func rowChangedMeanwhileFailsTheCommit() async throws {
        let f = try await Fixture()
        let (b, rows) = try await f.browser("items")
        var e = StagedEdits(baseRowCount: rows.count)
        e.addRow([1: .value(.text("new"))])
        e.set(.value(.text("gone")), row: 0, column: 1, original: rows[0])
        _ = try await f.db.execute("DELETE FROM items WHERE id = 1")
        await #expect(throws: DatabaseError.self) { try await b.commit(e) }
        #expect(try await f.rows("SELECT count(*) FROM items") == [[.integer(2)]])
    }

    @Test func pagingSortAndFilterSQL() async throws {
        let f = try await Fixture()
        let b = try await TableBrowser.open(TableRef("items"), on: f.db)
        let query = GridQuery(
            filter: Filter([FilterCondition(.column("name"), .contains, "p")]),
            sort: [SortKey("qty", ascending: false)],
            page: Paging(pageSize: 1, offset: 1))
        #expect(b.select(query, offset: 0, limit: 1).inlined(for: b.dialect) == #"""
            SELECT * FROM "items" WHERE CAST("name" AS TEXT) LIKE '%p%' ESCAPE '\' ORDER BY "qty" DESC LIMIT 1 OFFSET 1
            """#)
        #expect(try await b.count(filter: query.filter) == 2)
        _ = f.log.take()
        let rows = try await b.fetcher(query)(0, 1)
        #expect(rows.map { $0[1] } == [.text("apple")])
        #expect(f.log.take() == [b.select(query, offset: 0, limit: 1).inlined(for: b.dialect)])
    }
}
