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

private func sql(_ edits: StagedEdits, columns: [ColumnInfo] = columns) -> [String] {
    dialect.statements(for: edits.changeSet(for: TableRef("t"), columns: columns, dialect: dialect))
        .map { $0.inlined(for: dialect) }
}

@Suite struct StagedEditsTests {
    @Test func settingTheLoadedValueUnstages() {
        var e = StagedEdits(baseRowCount: 2)
        e.set(.value(.text("plum")), row: 0, column: 1, original: rows[0])
        #expect(e.state(of: 0) == .edited)
        #expect(e.change(row: 0, column: 1) == .value(.text("plum")))
        e.set(.value(.text("apple")), row: 0, column: 1, original: rows[0])
        #expect(e.state(of: 0) == .unchanged)
        #expect(e.isEmpty)
    }

    @Test func updatesLocateRowsByOriginalKey() {
        var e = StagedEdits(baseRowCount: 2)
        e.set(.value(.integer(20)), row: 1, column: 0, original: rows[1])
        e.set(.value(.null), row: 1, column: 1, original: rows[1])
        #expect(sql(e) == [#"UPDATE "t" SET "id" = 20, "name" = NULL WHERE "id" = 2"#])
    }

    @Test func defaultIsOmittedFromInsertAndWrittenInUpdate() {
        var e = StagedEdits(baseRowCount: 2)
        e.set(.defaultValue, row: 0, column: 2, original: rows[0])
        let new = e.addRow([1: .value(.text("fig")), 2: .defaultValue])
        #expect(new == 2)
        #expect(e.state(of: 2) == .inserted)
        e.addRow()
        #expect(sql(e) == [
            #"UPDATE "t" SET "qty" = (0) WHERE "id" = 1"#,
            #"INSERT INTO "t" ("name") VALUES ('fig')"#,
            #"INSERT INTO "t" DEFAULT VALUES"#,
        ])
    }

    @Test func deleteDropsInsertsAndMarksLoadedRows() {
        var e = StagedEdits(baseRowCount: 2)
        e.addRow([1: .value(.text("a"))])
        e.addRow([1: .value(.text("b"))])
        e.set(.value(.text("x")), row: 1, column: 1, original: rows[1])
        e.delete(rows: [1, 2], original: { rows[$0] })
        #expect(e.rowCount == 3)
        #expect(e.change(row: 2, column: 1) == .value(.text("b")))
        #expect(e.state(of: 1) == .deleted)
        #expect(e.updatedRowCount == 0)
        // The delete uses the loaded key, and the edit to the deleted row is not sent.
        #expect(sql(e) == [#"DELETE FROM "t" WHERE "id" = 2"#, #"INSERT INTO "t" ("name") VALUES ('b')"#])
    }

    @Test func withoutPrimaryKeyEveryColumnLocatesTheRow() {
        let noKey = columns.map { var c = $0; c.primaryKeyPosition = nil; return c }
        var e = StagedEdits(baseRowCount: 2)
        e.set(.value(.integer(9)), row: 0, column: 2, original: [.integer(1), .null, .integer(3)])
        #expect(sql(e, columns: noKey) == [#"UPDATE "t" SET "qty" = 9 WHERE "id" = 1 AND "name" IS NULL AND "qty" = 3"#])
    }

    @Test func discardClearsEverything() {
        var e = StagedEdits(baseRowCount: 2)
        e.addRow()
        e.delete(rows: [0], original: { rows[$0] })
        e.discard()
        #expect(e.isEmpty)
        #expect(e.rowCount == 2)
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
