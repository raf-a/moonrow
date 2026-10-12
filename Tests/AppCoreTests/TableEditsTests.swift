import DBKit
import Testing
@testable import AppCore

private let columns = [
    ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
    ColumnInfo(name: "name", typeName: "TEXT"),
    ColumnInfo(name: "qty", typeName: "INTEGER", defaultExpression: "0"),
]
private let rows: [[DBValue]] = [
    [.integer(1), .text("apple"), .integer(3)],
    [.integer(2), .text("pear"), .integer(5)],
]
private let dialect = SQLiteDialect()

private func sql(_ edits: TableEdits) -> [String] {
    dialect.statements(for: edits.changeSet(dialect: dialect)).map { $0.inlined(for: dialect) }
}

private func newEdits(_ cols: [ColumnInfo] = columns) -> TableEdits { TableEdits(table: TableRef("t"), columns: cols) }

@Suite struct TableEditsTests {
    @Test func settingTheLoadedValueUnstages() {
        var e = newEdits()
        e.set(.value(.text("plum")), column: 1, in: rows[0])
        #expect(e.state(of: rows[0]) == .edited)
        #expect(e.change(in: rows[0], column: 1) == .value(.text("plum")))
        #expect(e.summary == "1 edited")
        e.set(.value(.text("apple")), column: 1, in: rows[0])
        #expect(e.state(of: rows[0]) == .unchanged)
        #expect(e.isEmpty)
    }

    @Test func updatesLocateRowsByOriginalKey() {
        var e = newEdits()
        e.set(.value(.integer(20)), column: 0, in: rows[1])
        e.set(.value(.null), column: 1, in: rows[1])
        #expect(sql(e) == [#"UPDATE "t" SET "id" = 20, "name" = NULL WHERE "id" = 2"#])
    }

    /// Rows are found again by key whenever they load: on another page, sorted differently, or
    /// after the database changed other columns.
    @Test func editsFollowTheRowNotTheGridPosition() {
        var e = newEdits()
        e.set(.value(.text("plum")), column: 1, in: rows[1])
        e.delete(rows[0])
        let reloaded: [[DBValue]] = [[.integer(2), .text("pear"), .integer(99)], [.integer(1), .text("apple"), .integer(3)]]
        #expect(e.state(of: reloaded[0]) == .edited)
        #expect(e.change(in: reloaded[0], column: 1) == .value(.text("plum")))
        #expect(e.state(of: reloaded[1]) == .deleted)
        #expect(e.state(of: nil) == .unchanged)   // not loaded yet
        // Statements come out in the order rows were first staged; the delete goes first.
        #expect(sql(e) == [#"DELETE FROM "t" WHERE "id" = 1"#, #"UPDATE "t" SET "name" = 'plum' WHERE "id" = 2"#])
    }

    @Test func defaultIsOmittedFromInsertAndWrittenInUpdate() {
        var e = newEdits()
        e.set(.defaultValue, column: 2, in: rows[0])
        let new = e.addRow([1: .value(.text("fig")), 2: .defaultValue])
        #expect(new == 0)
        e.addRow()
        #expect(e.summary == "1 edited, 2 new")
        #expect(sql(e) == [
            #"UPDATE "t" SET "qty" = (0) WHERE "id" = 1"#,
            #"INSERT INTO "t" ("name") VALUES ('fig')"#,
            #"INSERT INTO "t" DEFAULT VALUES"#,
        ])
    }

    @Test func deletingDropsCellEditsAndRemovesInserts() {
        var e = newEdits()
        e.addRow([1: .value(.text("a"))])
        e.addRow([1: .value(.text("b"))])
        e.set(.value(.text("x")), column: 1, in: rows[1])
        e.delete(rows[1])
        e.removeInserted([0])
        #expect(e.insertedRowCount == 1)
        #expect(e.inserts[0][1] == .value(.text("b")))
        #expect(e.state(of: rows[1]) == .deleted)
        #expect(e.updatedRowCount == 0)
        // Editing a deleted row does nothing; the delete uses the loaded key.
        e.set(.value(.text("y")), column: 1, in: rows[1])
        #expect(sql(e) == [#"DELETE FROM "t" WHERE "id" = 2"#, #"INSERT INTO "t" ("name") VALUES ('b')"#])
    }

    @Test func withoutPrimaryKeyEveryColumnLocatesTheRow() {
        let noKey = columns.map { var c = $0; c.primaryKeyPosition = nil; return c }
        var e = newEdits(noKey)
        e.set(.value(.integer(9)), column: 2, in: [.integer(1), .null, .integer(3)])
        #expect(!e.hasPrimaryKey)
        #expect(sql(e) == [#"UPDATE "t" SET "qty" = 9 WHERE "id" = 1 AND "name" IS NULL AND "qty" = 3"#])
        // Identical rows share the key, so both show the edit; the commit refuses to hit two.
        #expect(e.state(of: [.integer(1), .null, .integer(3)]) == .edited)
    }

    @Test func rebaseFollowsColumnsByName() {
        var e = newEdits()
        e.set(.value(.text("plum")), column: 1, in: rows[0])
        e.set(.value(.integer(8)), column: 2, in: rows[0])
        e.addRow([1: .value(.text("fig")), 2: .value(.integer(1))])
        // qty dropped, a column added in front.
        let now = [ColumnInfo(name: "sku", typeName: "TEXT"), columns[0], columns[1]]
        e.rebase(columns: now)
        let row: [DBValue] = [.text("A1"), .integer(1), .text("apple")]
        #expect(e.state(of: row) == .edited)
        #expect(e.change(in: row, column: 2) == .value(.text("plum")))
        #expect(sql(e) == [
            #"UPDATE "t" SET "name" = 'plum' WHERE "id" = 1"#,
            #"INSERT INTO "t" ("name") VALUES ('fig')"#,
        ])
    }
}

@Suite struct CellInputTests {
    @Test func parsesByDeclaredType() {
        #expect(CellInput.parse("42", typeName: "INTEGER") == .integer(42))
        #expect(CellInput.parse(" 42 ", typeName: "bigint") == .integer(42))
        #expect(CellInput.parse("4.5", typeName: "REAL") == .double(4.5))
        #expect(CellInput.parse("true", typeName: "BOOLEAN") == .bool(true))
        #expect(CellInput.parse("4.50", typeName: "NUMERIC(10,2)") == .text("4.50"))
        // Not a number: left for the database to accept or reject.
        #expect(CellInput.parse("n/a", typeName: "INT") == .text("n/a"))
        #expect(CellInput.parse("", typeName: "TEXT") == .text(""))
    }
}

@Suite struct GridQueryTests {
    @Test func headerClicksCycleSort() {
        var q = GridQuery()
        q.cycleSort("a")
        #expect(q.sort == [SortKey("a", ascending: true)])
        q.cycleSort("a")
        #expect(q.sort == [SortKey("a", ascending: false)])
        q.cycleSort("b")
        #expect(q.sort == [SortKey("b", ascending: true)])
        q.cycleSort("b")
        q.cycleSort("b")
        #expect(q.sort.isEmpty)
    }

    @Test func paging() {
        let p = Paging(pageSize: 300)
        #expect(p.rows(total: 1000) == 0..<300)
        #expect(p.previous == nil)
        let last = p.next(total: 1000)!.next(total: 1000)!.next(total: 1000)!
        #expect(last.rows(total: 1000) == 900..<1000)
        #expect(last.next(total: 1000) == nil)
        let thousand = 1000.formatted(.number)  // grouping follows the locale
        #expect(last.describe(total: 1000) == "901–\(thousand) of \(thousand)")
        #expect(Paging(pageSize: 300, offset: 100).previous == Paging(pageSize: 300, offset: 0))
        #expect(Paging(pageSize: nil).rows(total: 5) == 0..<5)
        #expect(Paging(pageSize: 0) == Paging(pageSize: nil))
        #expect(Paging(pageSize: 10, offset: 50).rows(total: 20).isEmpty)
        #expect(Paging(pageSize: nil).describe(total: 1) == "1 row")
    }
}
