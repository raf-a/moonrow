import DBKit
import DriverSQLite
import Foundation
import SQLScript
import Testing
@testable import AppCore

struct JSONRecordReaderTests {
    private func reader(_ text: String) throws -> JSONRecordReader {
        try JSONRecordReader(data: Data(text.utf8))
    }

    @Test func arrayOfObjects() throws {
        let r = try reader("""
            \u{FEFF}[
              {"id": 1, "name": "a\\"b\\\\c\\n", "score": 2.50, "ok": true, "tags": ["x", {"y": 1}]},
              {"name": "é \\u00e9 \\ud83d\\ude00", "id": -3e2, "extra": null, "ok": false},
              {}
            ]
            """)
        #expect(r.columnNames == ["id", "name", "score", "ok", "tags", "extra"])
        let rows = try r.take(10)
        #expect(rows.count == 3)
        #expect(rows[0].fields == [CSVField("1"), CSVField("a\"b\\c\n", quoted: true), CSVField("2.50"), CSVField("true"),
                                   CSVField(#"["x",{"y":1}]"#, quoted: true), CSVField("")])
        #expect(rows[1].fields[0] == CSVField("-3e2"))
        #expect(rows[1].fields[1] == CSVField("é é 😀", quoted: true))
        #expect(rows[1].fields[5] == CSVField(""))
        #expect(rows[2].fields.allSatisfy { $0 == CSVField("") })
        #expect(rows.map(\.line) == [2, 3, 4])
        #expect(r.fractionRead == 1)
    }

    @Test func jsonLinesAndLateKeys() throws {
        let r = try JSONRecordReader(data: Data("{\"a\": 1}\n{\"a\": 2, \"b\": \"x\"}\n\n{\"c\": 3}\n".utf8), scan: 2)
        #expect(r.columnNames == ["a", "b"])
        let rows = try r.take(10)
        #expect(rows.map { $0.fields.map(\.text) } == [["1", ""], ["2", "x"], ["", ""]])
        #expect(r.skippedKeys == ["c"])
        #expect(rows.last?.line == 4)
    }

    @Test func malformed() throws {
        #expect(throws: DatabaseError.self) { try self.reader("\"just a string\"") }
        #expect(throws: DatabaseError.self) { try self.reader("[{\"a\": 1},\n 2]") }
        #expect(throws: DatabaseError.self) { try self.reader("[{\"a\": tru}]") }
        let unclosed = try? reader("[{\"a\": 1}")
        #expect(unclosed == nil)
        #expect(try reader("[]").columnNames.isEmpty)
        #expect(try reader("").take(1).isEmpty)
        #expect(throws: DatabaseError.self) { try JSONRecordReader(data: Data([0x5B, 0xE9, 0x5D])) }
    }
}

struct CSVRecordReaderTests {
    @Test func streamsTheSameRecordsAsTheDocument() throws {
        var text = "id,note\n"
        for i in 0..<2000 { text += "\(i),\"line \(i)\nnext, \"\"q\"\"\"\r\n" }
        let data = Data(text.utf8)
        let doc = try CSVReader().read(data)
        let stream = try CSVRecordReader(data: data, options: CSVReader())
        var fields: [[CSVField]] = []
        var fractions: [Double] = []
        while let r = try stream.next() {
            fields.append(r.fields)
            fractions.append(stream.fractionRead)
        }
        #expect(fields == doc.rows)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func widthWithoutHeaderComesFromTheFirstRecords() throws {
        let data = Data("1\n1,2\n1,2,3,4\n".utf8)
        let r = try CSVRecordReader(data: data, options: CSVReader(firstLineIsHeader: false), scan: 2)
        #expect(r.columnNames == ["column 1", "column 2"])
        #expect(try r.take(5).map(\.fields.count) == [2, 2, 2])
    }

    @Test func asciiOnlyDelimiters() {
        #expect(throws: DatabaseError.self) { try CSVRecordReader(data: Data("a§b".utf8), options: CSVReader(delimiter: "§")) }
    }
}

struct ImportValueTests {
    @Test func decimalComma() {
        #expect(CSVImportPlan.decimalCommaNumber("1,5") == "1.5")
        #expect(CSVImportPlan.decimalCommaNumber("-1.234,56") == "-1234.56")
        #expect(CSVImportPlan.decimalCommaNumber("1 234 567") == "1234567")
        #expect(CSVImportPlan.decimalCommaNumber(",5") == "0.5")
        #expect(CSVImportPlan.decimalCommaNumber("1.5") == nil)
        #expect(CSVImportPlan.decimalCommaNumber("12,3,4") == nil)
        #expect(CSVImportPlan.decimalCommaNumber("abc") == nil)

        let columns = [ColumnInfo(name: "n", typeName: "REAL"), ColumnInfo(name: "t", typeName: "TEXT"), ColumnInfo(name: "i", typeName: "bigint")]
        let plan = CSVImportPlan(table: TableRef("t"), columns: columns, mapping: [0, 1, 2], decimalComma: true)
        #expect(plan.value(CSVField("1.234,5"), for: columns[0]) == .double(1234.5))
        #expect(plan.value(CSVField("1,5"), for: columns[1]) == .text("1,5"))
        #expect(plan.value(CSVField("1.000"), for: columns[2]) == .integer(1000))
        let plain = CSVImportPlan(table: TableRef("t"), columns: columns, mapping: [0, 1, 2])
        #expect(plain.value(CSVField("1,5"), for: columns[0]) == .text("1,5"))
        let flag = ColumnInfo(name: "b", typeName: "tinyint(1)")
        #expect(plain.value(CSVField("True"), for: flag) == .bool(true))
    }

    @Test func guessedTypes() {
        let records: [ImportRecord] = [
            ["1", "1.50", "x", "true", "2024-02-29", "2024-01-02 03:04:05", "007", "1e3", "", "2024-01-02T03:04:05.5+02:00"],
            ["-20", "3", "", "FALSE", "2023-12-31", "2024-01-02T03:04", "8", "2", "", "2024-01-02 03:04:05Z"],
        ].enumerated().map { i, texts in ImportRecord(fields: texts.map { CSVField($0) }, line: i + 2) }
        let names = ["id", "price", "note", "flag", "day", "at", "code", "f", "empty", "zoned"]
        let pg = ImportTableDesign.guess(table: TableRef("t"), names: names, hasNames: true, records: records, dialect: PostgresDialect())
        #expect(pg.columns.map(\.typeName) == ["bigint", "numeric", "text", "boolean", "date", "timestamp", "text", "double precision", "text", "timestamptz"])
        let my = ImportTableDesign.guess(table: TableRef("t"), names: names, hasNames: true, records: records, dialect: MySQLDialect())
        #expect(my.columns.map(\.typeName) == ["BIGINT", "DECIMAL(3,2)", "VARCHAR(255)", "TINYINT(1)", "DATE", "DATETIME", "VARCHAR(255)", "DOUBLE", "VARCHAR(255)", "VARCHAR(255)"])
        let lite = ImportTableDesign.guess(table: TableRef("t"), names: names, hasNames: true, records: records, dialect: SQLiteDialect())
        #expect(lite.columns.map(\.typeName) == ["INTEGER", "REAL", "TEXT", "BOOLEAN", "DATE", "DATETIME", "TEXT", "REAL", "TEXT", "TEXT"])

        let invalid = [ImportRecord(fields: [CSVField("2023-02-30")], line: 1)]
        #expect(ImportTableDesign.guess(table: TableRef("t"), names: ["d"], hasNames: true, records: invalid, dialect: PostgresDialect()).columns[0].typeName == "text")
        let quotedEmpty = [ImportRecord(fields: [CSVField("1")], line: 1), ImportRecord(fields: [CSVField("", quoted: true)], line: 2)]
        #expect(ImportTableDesign.guess(table: TableRef("t"), names: ["n"], hasNames: true, records: quotedEmpty, dialect: PostgresDialect()).columns[0].typeName == "text")
        let comma = [ImportRecord(fields: [CSVField("1.234,5")], line: 1)]
        #expect(ImportTableDesign.guess(table: TableRef("t"), names: ["n"], hasNames: true, records: comma, dialect: PostgresDialect(), decimalComma: true).columns[0].typeName == "numeric")
    }

    @Test func namesAndMapping() throws {
        #expect(ImportTableDesign.columnNames(["id", " ", "ID", "id_2", "name "]) == ["id", "column_2", "ID_2", "id_2_2", "name"])
        var d = ImportTableDesign.guess(table: TableRef("new"), names: ["a", "b", "c"], hasNames: true, records: [], dialect: SQLiteDialect())
        d.columns[1].include = false
        #expect(d.mapping == [0, 2])
        #expect(d.tableColumns.map(\.name) == ["a", "c"])
        #expect(try d.plan(SQLiteDialect()).statements == ["CREATE TABLE \"new\" (\n  \"a\" TEXT,\n  \"c\" TEXT\n)"])
        d.columns[2].name = "A"
        #expect(throws: DatabaseError.self) { try d.validate() }
    }
}

extension ImportRecord: Equatable {
    public static func == (a: ImportRecord, b: ImportRecord) -> Bool { a.fields == b.fields && a.line == b.line }
}

struct SQLDumpReaderTests {
    private func write(_ text: String, gzip: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-dump-\(UUID().uuidString).sql\(gzip ? ".gz" : "")")
        if gzip {
            let w = try GzipWriter(url: url)
            try w.write(text)
            try w.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    private func items(_ url: URL, _ dialect: LexerDialect, psql: Bool = false) throws -> [SQLDumpReader.Item] {
        let r = try SQLDumpReader(url: url, dialect: dialect, psql: psql)
        var out: [SQLDumpReader.Item] = []
        while let item = try r.next() {
            out.append(item)
            if case .copy = item {
                var data = Data()
                while let piece = try r.copyData() { data.append(piece) }
                out.append(.statement("DATA:" + String(decoding: data, as: UTF8.self), line: 0))
            }
        }
        return out
    }

    @Test func largeFileSplitsLikeTheEditorDoes() throws {
        // Several pieces' worth, with a multi-byte character on every line so pieces cut inside one.
        var text = ""
        for i in 0..<40_000 { text += "INSERT INTO t VALUES (\(i), 'é—✓ \(i); not the end');\n" }
        text += "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\n"
        let url = try write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let got = try items(url, .postgres, psql: true)
        let expected = SQLSplitter.split(text, dialect: .postgres).enumerated().map { i, s in SQLDumpReader.Item.statement(s.text, line: i + 1) }
        #expect(got.count == expected.count)
        #expect(got == expected)
    }

    @Test func psqlCommandsAndCopyData() throws {
        let text = """
            --
            -- dump
            --

            \\restrict abc123

            SET statement_timeout = 0;
            COPY public.t (id, note) FROM stdin;
            1\tone; still data
            2\t\\N
            \\.
            -- after
            SELECT 1;
            COPY t FROM STDIN;\r
            3\tx\r
            \\.\r
            \\unrestrict abc123

            """
        for gzip in [false, true] {
            let url = try write(text, gzip: gzip)
            defer { try? FileManager.default.removeItem(at: url) }
            let got = try items(url, .postgres, psql: true)
            #expect(got == [
                .skipped("\\restrict abc123", line: 5),
                .statement("SET statement_timeout = 0", line: 7),
                .copy("COPY public.t (id, note) FROM stdin", line: 8),
                .statement("DATA:1\tone; still data\n2\t\\N\n", line: 0),
                .statement("-- after\nSELECT 1", line: 13),
                .copy("COPY t FROM STDIN", line: 14),
                .statement("DATA:3\tx\r\n", line: 0),
                .skipped("\\unrestrict abc123", line: 17),
            ])
        }
    }

    @Test func mysqlDelimitersAndExecutableComments() throws {
        let text = """
            /*!40101 SET NAMES utf8mb4 */;
            /* just a comment */;
            DELIMITER ;;
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END ;;
            DELIMITER ;
            SELECT 3;
            """
        let url = try write(text)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try items(url, .mysql) == [
            .statement("/*!40101 SET NAMES utf8mb4 */", line: 1),
            .statement("CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", line: 4),
            .statement("SELECT 3", line: 6),
        ])
        // A DELIMITER in effect when a piece ends carries over: a long file of them.
        var long = "DELIMITER $$\n"
        for i in 0..<30_000 { long += "SELECT \(i); SELECT 'x'$$\n" }
        let big = try write(long)
        defer { try? FileManager.default.removeItem(at: big) }
        let all = try items(big, .mysql)
        #expect(all.count == 30_000)
        #expect(all.last == .statement("SELECT 29999; SELECT 'x'", line: 30_001))
    }
}

/// Imports on each backend: a new table from a CSV, JSON into an existing table, Stop, and SQL
/// files (our export, a Postgres dump with COPY, a MySQL dump with executable comments).
@Suite(.serialized) struct ImportRoundTripTests {
    private func file(_ text: String, _ ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-import-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func run<T>(_ backend: Backend, _ body: (Fixture) async throws -> T) async throws -> T {
        let f = try await Fixture(backend)
        do {
            let value = try await body(f)
            await f.tearDown()
            return value
        } catch {
            await f.tearDown()
            throw error
        }
    }

    private func newTable(_ f: Fixture, _ name: String) -> TableRef { TableRef(name) }

    @Test(arguments: Backend.all)
    func newTableFromCSV(_ backend: Backend) async throws {
        try await run(backend) { f in
            let url = try file("id;price;label;when;flag\n1;1,50;a;2024-01-02;true\n2;1.234,5;\"b;c\";2024-02-03;false\n3;;;;\n", "csv")
            defer { try? FileManager.default.removeItem(at: url) }
            let records = try CSVRecordReader(url: url, options: CSVReader())
            let first = try records.take(100)
            var design = ImportTableDesign.guess(table: TableRef("imported"), names: records.columnNames, hasNames: true,
                                                 records: first, dialect: f.db.dialect, decimalComma: true)
            design.columns[4].include = false
            let plan = CSVImportPlan(table: design.table, columns: design.tableColumns, mapping: design.mapping, decimalComma: true)
            let n = try await plan.run(try CSVRecordReader(url: url, options: CSVReader()), on: f.db, creating: try design.plan(f.db.dialect))
            #expect(n == 3)
            let columns = try await f.db.columns(of: TableRef("imported"))
            #expect(columns.map(\.name) == ["id", "price", "label", "when"])
            let got = try await f.db.execute("SELECT id, price, label, \(f.db.dialect.quoteIdentifier("when")) FROM imported ORDER BY id").rows
            #expect(got.count == 3)
            #expect(got[0][0] == .integer(1))
            #expect(got[1][1].displayString.hasPrefix("1234.5"))
            #expect(got[1][2] == .text("b;c"))
            #expect(got[2] == [.integer(3), .null, .null, .null])
        }
    }

    @Test(arguments: Backend.all)
    func failedOrStoppedNewTableLeavesNothing(_ backend: Backend) async throws {
        try await run(backend) { f in
            // The guess says integer from the first record; the second isn't one.
            let url = try file("n\n1\nnot a number\n", "csv")
            defer { try? FileManager.default.removeItem(at: url) }
            var design = ImportTableDesign.guess(table: TableRef("broken"), names: ["n"], hasNames: true,
                                                 records: [ImportRecord(fields: [CSVField("1")], line: 2)], dialect: f.db.dialect)
            design.columns[0].typeName = backend.kind == .postgres ? "integer" : "INTEGER"
            let plan = CSVImportPlan(table: design.table, columns: design.tableColumns, mapping: design.mapping, maxRowsPerStatement: 1)
            if backend.kind != .sqlite {
                // SQLite stores the text in an INTEGER column; the others refuse it.
                await #expect(throws: DatabaseError.self) {
                    try await plan.run(try CSVRecordReader(url: url, options: CSVReader()), on: f.db, creating: try design.plan(f.db.dialect))
                }
                #expect(try await f.db.objects(schema: nil).allSatisfy { $0.ref.name != "broken" })
            }

            // Stopped after the first statement: nothing stays, the table included.
            var big = "n\n"
            for i in 0..<50_000 { big += "\(i)\n" }
            let bigURL = try file(big, "csv")
            defer { try? FileManager.default.removeItem(at: bigURL) }
            let sent = Counts()
            let db = f.db
            let creating = try design.plan(f.db.dialect)
            let task = Task {
                try await plan.run(try CSVRecordReader(url: bigURL, options: CSVReader()), on: db, creating: creating) { rows, _ in
                    sent.add(rows)
                    if rows == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(sent.values.last ?? 0 < 50_000)
            #expect(try await f.db.objects(schema: nil).allSatisfy { $0.ref.name != "broken" })
            #expect(try await f.db.execute("SELECT count(*) FROM items").rows == [[.integer(3)]])
        }
    }

    @Test(arguments: Backend.all)
    func jsonIntoExistingTable(_ backend: Backend) async throws {
        try await run(backend) { f in
            let url = try file(#"[{"name": "kiwi", "qty": 4, "price": 0.5, "note": null}, {"qty": 1, "name": "lime \"x\""}]"#, "json")
            defer { try? FileManager.default.removeItem(at: url) }
            let records = try JSONRecordReader(url: url)
            let columns = try await f.db.columns(of: TableRef("items"))
            let mapping = CSVImportPlan.mapping(for: columns, source: records.columnNames, sourceCount: records.columnNames.count, match: .byName)
            let plan = CSVImportPlan(table: TableRef("items"), columns: columns, mapping: mapping)
            #expect(try await plan.run(records, on: f.db) == 2)
            let got = try await f.db.execute("SELECT name, qty, price, note FROM items WHERE id > 3 ORDER BY id").rows
            #expect(got == [[.text("kiwi"), .integer(4), .double(0.5), .null], [.text("lime \"x\""), .integer(1), .null, .null]])
        }
    }

    @Test(arguments: Backend.all)
    func ourSQLExportRunsAsAFile(_ backend: Backend) async throws {
        try await run(backend) { f in
            let items = [TablesExportJob.Item(DatabaseObject(TableRef("items"), kind: .table), drop: true)]
            let job = TablesExportJob(items: items, format: .sql(SQLExportOptions(gzip: true)), connection: f.db,
                                      pattern: FileNamePattern("x"), context: .init())
            let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-export-\(UUID().uuidString).sql.gz")
            defer { try? FileManager.default.removeItem(at: url) }
            try await job.run(to: url)
            let before = try await f.db.execute("SELECT id, name, qty, price, note FROM items ORDER BY id").rows
            _ = try await f.db.execute("DELETE FROM items")
            let progress = Counts()
            let summary = try await SQLFileImport(url: url).run(on: f.db) { progress.add($0.statements) }
            // DROP, CREATE and INSERT; Postgres also recreates the serial's sequence, owns it and
            // moves it past the ids inserted.
            let expected = backend.kind == .postgres ? 6 : 3
            #expect(summary.statements == expected)
            #expect(summary.failed.isEmpty)
            #expect(progress.values.last == expected)
            #expect(try await f.db.execute("SELECT id, name, qty, price, note FROM items ORDER BY id").rows == before)
            _ = try await f.db.execute("INSERT INTO items (name) VALUES ('next')")
            #expect(try await f.db.execute("SELECT id FROM items WHERE name = 'next'").rows == [[.integer(4)]])
        }
    }

    @Test(arguments: Backend.all)
    func errorsStopOrAreCounted(_ backend: Backend) async throws {
        try await run(backend) { f in
            let url = try file("INSERT INTO items (name) VALUES ('a');\n\nINSERT INTO nope VALUES (1);\nINSERT INTO items (name) VALUES ('b');\n", "sql")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try await SQLFileImport(url: url).run(on: f.db)
                Issue.record("should have failed")
            } catch let error as DatabaseError {
                #expect(error.message.hasPrefix("Line 3:"), "\(error.message)")
                #expect(error.message.hasSuffix("(1 statement ran before it.)"))
            }
            let summary = try await SQLFileImport(url: url, continueOnError: true).run(on: f.db)
            #expect(summary.statements == 3)
            #expect(summary.failed.count == 1)
            #expect(try await f.db.execute("SELECT count(*) FROM items").rows == [[.integer(6)]])
        }
    }

    @Test func postgresDumpWithCopy() async throws {
        guard let backend = Backend.all.first(where: { $0.kind == .postgres }) else { return }
        try await run(backend) { f in
            let url = try file("""
                \\restrict k
                SET client_encoding = 'UTF8';
                CREATE TABLE copied (id integer, note text, at date);
                COPY copied (id, note, at) FROM stdin;
                1\tone\\ttab\t2024-01-02
                2\t\\N\t\\N
                \\.
                SELECT count(*) FROM copied;
                \\unrestrict k

                """, "sql")
            defer { try? FileManager.default.removeItem(at: url) }
            let summary = try await SQLFileImport(url: url).run(on: f.db)
            #expect(summary.statements == 4)
            #expect(summary.skipped == ["line 1: \\restrict k", "line 9: \\unrestrict k"])
            #expect(try await f.db.execute("SELECT id, note, at::text FROM copied ORDER BY id").rows == [
                [.integer(1), .text("one\ttab"), .text("2024-01-02")], [.integer(2), .null, .null],
            ])

            // A COPY that fails (bad data) reports the line and leaves the session usable.
            let bad = try file("COPY copied (id) FROM stdin;\nnot a number\n\\.\nSELECT 1;\n", "sql")
            defer { try? FileManager.default.removeItem(at: bad) }
            await #expect(throws: DatabaseError.self) { try await SQLFileImport(url: bad).run(on: f.db) }
            #expect(try await f.db.execute("SELECT count(*) FROM copied").rows == [[.integer(2)]])
        }
    }

    @Test func mysqlDumpWithExecutableComments() async throws {
        for backend in Backend.all where backend.kind == .mysql {
            try await run(backend) { f in
                // Children before parents, as mysqldump orders them: only works with key checks off.
                let url = try file("""
                    /*!40101 SET NAMES utf8mb4 */;
                    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
                    CREATE TABLE child (id int PRIMARY KEY, parent_id int, FOREIGN KEY (parent_id) REFERENCES parent (id));
                    INSERT INTO child VALUES (1, 1);
                    CREATE TABLE parent (id int PRIMARY KEY);
                    INSERT INTO parent VALUES (1);
                    DELIMITER ;;
                    CREATE PROCEDURE two() BEGIN SELECT 1; SELECT 2; END ;;
                    DELIMITER ;
                    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
                    """, "sql")
                defer { try? FileManager.default.removeItem(at: url) }
                let summary = try await SQLFileImport(url: url).run(on: f.db)
                #expect(summary.statements == 8)
                #expect(try await f.db.execute("SELECT count(*) FROM child").rows == [[.integer(1)]])
                #expect(try await f.db.execute("SELECT @@FOREIGN_KEY_CHECKS").rows == [[.integer(1)]])
            }
        }
    }
}
