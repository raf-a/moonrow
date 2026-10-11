import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

struct CSVReaderTests {
    private func read(_ text: String, _ reader: CSVReader = CSVReader()) throws -> CSVDocument {
        try reader.read(Data(text.utf8))
    }

    @Test func quotedFieldsAndLineEndings() throws {
        let doc = try read("\u{FEFF}id,note\r\n1,\"a,b\"\r\n2,\"say \"\"hi\"\"\"\n3,\"two\r\nlines\"\r4,\"\"\n5,\n")
        #expect(doc.header == ["id", "note"])
        #expect(doc.rows.map { $0.map(\.text) } == [["1", "a,b"], ["2", "say \"hi\""], ["3", "two\r\nlines"], ["4", ""], ["5", ""]])
        #expect(doc.rows[3][1].quoted)
        #expect(!doc.rows[4][1].quoted)
        #expect(doc.lines == [2, 3, 4, 6, 7])
    }

    @Test func raggedRowsAndBlankLines() throws {
        let doc = try read("a,b,c\n1\n\n1,2,3,4\n")
        #expect(doc.rows.map { $0.map(\.text) } == [["1", "", ""], ["1", "2", "3"]])
        let noHeader = try read("1\n1,2,3\n", CSVReader(firstLineIsHeader: false))
        #expect(noHeader.header == nil)
        #expect(noHeader.columnNames == ["column 1", "column 2", "column 3"])
        #expect(noHeader.rows.map(\.count) == [3, 3])
    }

    @Test func delimiterQuoteAndDetection() throws {
        #expect(CSVReader.detectDelimiter("a;b;\"c,d,e\"\n1,2,3,4") == ";")
        #expect(CSVReader.detectDelimiter("a\tb\tc") == "\t")
        #expect(CSVReader.detectDelimiter("single") == ",")
        let doc = try read("a|b\n'x|y'|'it''s'\n", CSVReader(delimiter: nil, quote: "'"))
        #expect(doc.delimiter == "|")
        #expect(doc.rows[0].map(\.text) == ["x|y", "it's"])
        #expect(throws: DatabaseError.self) { try read("a\n\"open\n") }
    }

    @Test func encodings() throws {
        let latin = Data("name\ncaf".utf8) + Data([0xE9])  // é in Windows-1252
        let doc = try CSVReader().read(latin)
        #expect(doc.encoding == .windowsCP1252)
        #expect(doc.rows[0][0].text == "café")
        let roman = try CSVReader(encoding: .macOSRoman).read(Data("x\n".utf8) + Data([0x8E]))
        #expect(roman.rows[0][0].text == "é")
        #expect(throws: DatabaseError.self) { try CSVReader(encoding: .utf8).read(latin) }
    }
}

struct CSVImportPlanTests {
    let columns = [
        ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
        ColumnInfo(name: "Name", typeName: "TEXT"),
        ColumnInfo(name: "score", typeName: "REAL"),
        ColumnInfo(name: "total", typeName: "INTEGER", generated: "GENERATED ALWAYS AS (id * 2) STORED"),
        ColumnInfo(name: "data", typeName: "BLOB"),
    ]

    @Test func mappingAndValues() throws {
        let byName = CSVImportPlan.mapping(for: columns, source: ["NAME", "id", "other"], sourceCount: 3, match: .byName)
        #expect(byName == [1, 0, nil, nil, nil])
        let byOrder = CSVImportPlan.mapping(for: columns, source: nil, sourceCount: 4, match: .byOrder)
        #expect(byOrder == [0, 1, 2, nil, nil])

        let plan = CSVImportPlan(table: TableRef("t"), columns: columns, mapping: byName, nullWord: true)
        #expect(plan.value(CSVField(""), for: columns[1]) == .null)
        #expect(plan.value(CSVField("", quoted: true), for: columns[1]) == .text(""))
        #expect(plan.value(CSVField("NULL"), for: columns[1]) == .null)
        #expect(plan.value(CSVField("NULL", quoted: true), for: columns[1]) == .text("NULL"))
        #expect(plan.value(CSVField(" 7 "), for: columns[0]) == .integer(7))
        #expect(plan.value(CSVField("2.5"), for: columns[2]) == .double(2.5))
        #expect(plan.value(CSVField("\\x00ff"), for: columns[4]) == .blob(Data([0, 255])))
        #expect(plan.value(CSVField("\\xzz"), for: columns[4]) == .text("\\xzz"))
    }

    @Test func statementsAndUpsert() throws {
        let doc = try CSVReader().read(Data("id,Name\n1,a\n2,b\n3,c\n".utf8))
        var plan = CSVImportPlan(table: TableRef("t"), columns: columns, mapping: [0, 1, nil, nil, nil], maxRowsPerStatement: 2)
        let sql = try plan.statements(for: doc, dialect: SQLiteDialect())
        #expect(sql.map(\.rows) == [0..<2, 2..<3])
        #expect(sql[0].fragment.inlined(for: SQLiteDialect()) == "INSERT INTO \"t\" (\"id\", \"Name\") VALUES (1, 'a'), (2, 'b')")
        #expect(sql[0].fragment.statement(for: PostgresDialect()).sql == "INSERT INTO \"t\" (\"id\", \"Name\") VALUES ($1, $2), ($3, $4)")

        plan.onDuplicate = .update
        #expect(try plan.preview(for: doc, dialect: PostgresDialect(), statements: 1) == [
            "INSERT INTO \"t\" (\"id\", \"Name\") VALUES (1, 'a'), (2, 'b') ON CONFLICT (\"id\") DO UPDATE SET \"Name\" = excluded.\"Name\";",
        ])
        #expect(try plan.preview(for: doc, dialect: MySQLDialect(), statements: 1)[0].hasSuffix(
            "ON DUPLICATE KEY UPDATE `Name` = VALUES(`Name`);"))

        plan.mapping = [nil, 1, nil, nil, nil]
        #expect(throws: DatabaseError.self) { try plan.validate() }
        plan.mapping = [nil, nil, nil, nil, nil]
        plan.onDuplicate = .stop
        #expect(throws: DatabaseError.self) { try plan.validate() }

        let wide = CSVImportPlan(table: TableRef("t"), columns: columns, mapping: [0, 1, 2, nil, 4], maxBindings: 10)
        #expect(wide.rowsPerStatement == 2)
    }
}

/// Export → import round trips and failure handling on each backend.
@Suite(.serialized) struct CSVImportRoundTripTests {
    private func rows(_ f: Fixture) async throws -> [[DBValue]] {
        try await f.db.execute("SELECT * FROM items ORDER BY id").rows
    }

    private func exportCSV(_ f: Fixture) async throws -> CSVDocument {
        let sink = StringSink()
        let job = ExportJob(source: .table(TableRef("items"), filter: nil, sort: [SortKey("id")], connection: f.db), format: .csv(CSVOptions()))
        try await job.write(to: sink)
        return try CSVReader().read(Data(sink.text.utf8))
    }

    private func plan(_ f: Fixture, _ doc: CSVDocument, _ onDuplicate: CSVImportPlan.OnDuplicate = .stop) async throws -> CSVImportPlan {
        let columns = try await f.db.columns(of: TableRef("items"))
        let mapping = CSVImportPlan.mapping(for: columns, source: doc.header, sourceCount: doc.columnCount, match: .byName)
        return CSVImportPlan(table: TableRef("items"), columns: columns, mapping: mapping, onDuplicate: onDuplicate)
    }

    @Test(arguments: Backend.all)
    func exportThenImportGivesTheSameRows(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        do {
            _ = try await f.db.execute("INSERT INTO items (name, qty, price, note) VALUES ('comma, \"quote\"', 1, -0.5, '')")
            let before = try await rows(f)
            let doc = try await exportCSV(f)
            _ = try await f.db.execute("DELETE FROM items")
            let counts = Counts()
            let n = try await plan(f, doc).run(doc, on: f.db) { counts.add($0) }
            #expect(n == before.count)
            #expect(counts.values.last == before.count)
            #expect(try await rows(f) == before)
        } catch {
            await f.tearDown()
            throw error
        }
        await f.tearDown()
    }

    @Test(arguments: Backend.all)
    func updateOnDuplicate(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        do {
            let doc = try CSVReader().read(Data("id,name,qty\n1,apple 2,30\n10,kiwi,\n".utf8))
            try await plan(f, doc, .update).run(doc, on: f.db)
            let got = try await f.db.execute("SELECT id, name, qty FROM items ORDER BY id").rows
            #expect(got == [
                [.integer(1), .text("apple 2"), .integer(30)], [.integer(2), .text("pear"), .integer(5)],
                [.integer(3), .text("fig"), .integer(0)], [.integer(10), .text("kiwi"), .null],
            ])
        } catch {
            await f.tearDown()
            throw error
        }
        await f.tearDown()
    }

    @Test(arguments: Backend.all)
    func aFailingRowRollsBackEverything(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        do {
            let before = try await rows(f)
            // Line 3 leaves the NOT NULL name empty (NULL).
            let doc = try CSVReader().read(Data("id,name\n20,ok\n21,\n22,later\n".utf8))
            var p = try await plan(f, doc)
            p.maxRowsPerStatement = 1
            do {
                try await p.run(doc, on: f.db)
                Issue.record("the import should have failed")
            } catch let error as DatabaseError {
                #expect(error.message.contains("line 3"), "\(error.message)")
            }
            #expect(try await rows(f) == before)
        } catch {
            await f.tearDown()
            throw error
        }
        await f.tearDown()
    }
}
