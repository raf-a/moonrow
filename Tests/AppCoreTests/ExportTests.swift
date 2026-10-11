import DBKit
import DriverSQLite
import Foundation
import SQLScript
import Testing
@testable import AppCore

struct CSVWriterTests {
    @Test func quotesOnlyWhatNeedsIt() {
        var w = CSVWriter()
        let text = w.document(columns: ["id", "note"], rows: [
            [.integer(1), .text("plain")],
            [.integer(2), .text("a,b")],
            [.integer(3), .text("say \"hi\"")],
            [.integer(4), .text("two\nlines")],
            [.integer(5), .text(" padded")],
            [.integer(6), .text("")],
            [.integer(7), .null],
        ])
        #expect(text == #"""
            id,note
            1,plain
            2,"a,b"
            3,"say ""hi"""
            4,"two
            lines"
            5," padded"
            6,""
            7,

            """#)
    }

    @Test func options() throws {
        var o = CSVOptions(delimiter: ";", quoting: .always, lineBreak: .crlf, includeHeader: false,
                           nullAsEmpty: false, flattenLineBreaks: true, decimalSeparator: ",")
        try o.validate()
        var w = CSVWriter(o)
        let text = w.document(columns: ["a"], rows: [[.double(1.5), .text("x\r\ny"), .null, .bool(true), .blob(Data([0, 255]))]])
        #expect(text == "\"1,5\";\"x y\";NULL;\"true\";\"\\x00ff\"\r\n")

        o.delimiter = ","
        #expect(throws: DatabaseError.self) { try o.validate() }
        o.delimiter = "ab"
        #expect(throws: DatabaseError.self) { try o.validate() }
        try CSVOptions(delimiter: "\t", lineBreak: .cr).validate()
    }
}

struct JSONWriterTests {
    @Test func typesAndDuplicateKeys() throws {
        var w = JSONWriter(JSONOptions(pretty: false))
        let text = w.document(columns: ["id", "x", "x", "x_2"], rows: [
            [.integer(1), .double(2.5), .bool(false), .null],
            [.integer(2), .double(.infinity), .text("q\"\\\n\u{1}é"), .blob(Data([1, 2, 3]))],
        ])
        #expect(text == #"""
            [
              {"id": 1, "x": 2.5, "x_2": false, "x_2_2": null},
              {"id": 2, "x": null, "x_2": "q\"\\\n\u0001é", "x_2_2": "AQID"}
            ]

            """#)
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
        #expect(parsed.count == 2)
        #expect(parsed[1]["x_2"] as? String == "q\"\\\n\u{1}é")
    }

    @Test func prettyAndEmpty() throws {
        var w = JSONWriter()
        #expect(w.document(columns: ["a"], rows: []) == "[]\n")
        var p = JSONWriter()
        let text = p.document(columns: ["a", "b"], rows: [[.integer(1), .text("x")]])
        #expect(text == "[\n  {\n    \"a\": 1,\n    \"b\": \"x\"\n  }\n]\n")
    }

    @Test func streamsInBatches() throws {
        // Batches written one at a time give the same document as all rows at once.
        var whole = JSONWriter()
        let rows: [[DBValue]] = (0..<5).map { [.integer(Int64($0))] }
        let expected = whole.document(columns: ["n"], rows: rows)
        var w = JSONWriter()
        var text = w.header(columns: ["n"])
        for r in rows { text += w.rows([r]) }
        text += w.footer()
        #expect(text == expected)
    }
}

struct CopyFormatTests {
    @Test func markdownAndInsert() {
        let rows: [[DBValue]] = [[.integer(1), .text("a|b")], [.integer(2), .null]]
        #expect(CopyFormat.markdown.text(columns: ["id", "v"], rows: rows, dialect: SQLiteDialect(), table: nil) == #"""
            | id | v |
            | --- | --- |
            | 1 | a\|b |
            | 2 | NULL |

            """#)
        #expect(CopyFormat.sqlInsert.text(columns: ["id", "v"], rows: rows, dialect: MySQLDialect(), table: TableRef("t")) == """
            INSERT INTO `t` (`id`, `v`) VALUES
              (1, 'a|b'),
              (2, NULL);

            """)
        #expect(CopyFormat.csv.text(columns: ["id"], rows: [[.integer(1)]], dialect: SQLiteDialect(), table: nil) == "id\n1\n")
    }
}

struct ExportJobTests {
    private func sampleDB() async throws -> (SQLiteConnection, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tabula-export-\(UUID().uuidString).db")
        let db = try SQLiteConnection(path: url.path)
        _ = try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, data BLOB, note TEXT)")
        _ = try await db.execute("INSERT INTO t VALUES (1, 'it''s', 1.25, X'00FF10', NULL), (2, 'two\nlines', NULL, NULL, ''), (3, 'c', -3.5e10, X'', 'x')")
        return (db, url)
    }

    @Test func sqlRoundTrip() async throws {
        let (db, url) = try await sampleDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let job = ExportJob(source: .table(TableRef("t"), filter: nil, sort: [], connection: db),
                            format: .sql(SQLExportOptions(dropTable: true, rowsPerInsert: 2)), batchSize: 2)
        let sink = StringSink()
        let n = try await job.write(to: sink)
        #expect(n == 3)
        #expect(sink.text.hasPrefix("-- Exported by Tabula\n"))
        #expect(sink.text.contains("DROP TABLE IF EXISTS \"t\";"))
        #expect(sink.text.components(separatedBy: "INSERT INTO").count == 3)

        let copy = try SQLiteConnection(path: ":memory:")
        for s in SQLSplitter.split(sink.text, dialect: .sqlite) { _ = try await copy.execute(SQLStatement(s.text)) }
        let original = try await db.execute("SELECT * FROM t ORDER BY id").rows
        let restored = try await copy.execute("SELECT * FROM t ORDER BY id").rows
        #expect(restored == original)
        let types = try await copy.execute("SELECT typeof(score), typeof(data), typeof(note) FROM t WHERE id = 1").rows
        #expect(types == [[.text("real"), .text("blob"), .text("null")]])
        await db.close()
        await copy.close()
    }

    @Test func fileIsReplacedOnlyOnSuccess() async throws {
        let (db, url) = try await sampleDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "tabula-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "t.csv")
        try "old".write(to: out, atomically: true, encoding: .utf8)

        // A filter on a missing column fails mid-export: the old file stays, nothing else is left.
        let bad = ExportJob(source: .table(TableRef("t"), filter: Filter([FilterCondition(.anyColumn, .raw, "no_such_column = 1")]), sort: [], connection: db),
                            format: .csv(CSVOptions()))
        await #expect(throws: (any Error).self) { try await bad.run(to: out) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["t.csv"])

        let job = ExportJob(source: .table(TableRef("t"), filter: nil, sort: [SortKey("id", ascending: false)], connection: db),
                            format: .csv(CSVOptions()))
        let counts = Counts()
        try await job.run(to: out) { counts.add($0) }
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.hasPrefix("id,name,score,data,note\n3,c,-35000000000.0,\\x,x\n"))
        #expect(counts.values.last == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["t.csv"])
        await db.close()
    }

    @Test func rowsSource() async throws {
        let job = ExportJob(source: .rows(name: "result", columns: ["a"], rows: [[.integer(1)], [.integer(2)]], dialect: PostgresDialect()),
                            format: .sql(SQLExportOptions()))
        let sink = StringSink()
        try await job.write(to: sink)
        #expect(sink.text.hasSuffix("INSERT INTO \"result\" (\"a\") VALUES\n  (1),\n  (2);\n"))
        #expect(!sink.text.contains("CREATE"))
    }
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    var values: [Int] { lock.withLock { list } }
    func add(_ n: Int) { lock.withLock { list.append(n) } }
}
