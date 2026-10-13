import DBKit
import DriverSQLite
import Foundation
import SQLScript
import Testing
@testable import AppCore

/// Runs a system tool and returns its standard output; these tests read our files with
/// independent readers (`/usr/bin/unzip`, `/usr/bin/gzip`).
func runTool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
    let p = Process()
    p.executableURL = URL(filePath: path)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "moonrow-transfer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct ArchiveTests {
    @Test func crc32() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func gzipRoundTripThroughSystemGzip() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.gz")
        let w = try GzipWriter(url: url)
        var expected = Data()
        for i in 0..<20_000 {
            let line = "line \(i) é ✓ \(String(repeating: "x", count: i % 50))\n"
            expected.append(Data(line.utf8))
            try w.write(line)
        }
        try w.close()
        let (status, output) = try runTool("/usr/bin/gzip", ["-dc", url.path])
        #expect(status == 0)
        #expect(output == expected)
        #expect(try GzipReader.decompress(url) == expected)
    }

    @Test func readsSystemGzipAndConcatenatedMembers() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appending(path: "p.txt")
        try Data("hello, world\n".utf8).write(to: plain)
        // gzip -n names nothing; plain gzip stores the file name (FNAME), which the reader skips.
        _ = try runTool("/usr/bin/gzip", ["-k", plain.path])
        let one = dir.appending(path: "p.txt.gz")
        #expect(try GzipReader.decompress(one) == Data("hello, world\n".utf8))
        var both = try Data(contentsOf: one)
        both.append(try Data(contentsOf: one))
        let two = dir.appending(path: "two.gz")
        try both.write(to: two)
        #expect(try GzipReader.decompress(two) == Data("hello, world\nhello, world\n".utf8))

        var damaged = try Data(contentsOf: one)
        damaged[damaged.count - 8] ^= 0xFF
        try damaged.write(to: two)
        #expect(throws: DatabaseError.self) { try GzipReader.decompress(two) }
    }

    @Test func zipReadBySystemUnzip() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.zip")
        let zip = try ZipWriter(url: url)
        try zip.add("a.txt", data: Data("alpha".utf8))
        try zip.add("dir/b.txt", data: Data(String(repeating: "beta ", count: 10_000).utf8))
        try zip.add("é.txt", data: Data("accent".utf8))
        try zip.add("empty", data: Data())
        try zip.close()
        #expect(try runTool("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        #expect(try runTool("/usr/bin/unzip", ["-p", url.path, "a.txt"]).output == Data("alpha".utf8))
        #expect(try runTool("/usr/bin/unzip", ["-p", url.path, "dir/b.txt"]).output.count == 50_000)
        // unzip prints non-ASCII names as "?" here, whoever wrote the archive.
        let names = String(decoding: try runTool("/usr/bin/unzip", ["-Z1", url.path]).output, as: UTF8.self).split(separator: "\n")
        #expect(names.count == 4 && names[0] == "a.txt" && names[3] == "empty")
    }
}

struct FileNamePatternTests {
    @Test func rendersPlaceholders() {
        var date = DateComponents()
        (date.year, date.month, date.day, date.hour, date.minute, date.second) = (2026, 3, 7, 9, 5, 2)
        let when = Calendar(identifier: .gregorian).date(from: date)!
        let c = FileNamePattern.Context(table: "users", database: "shop", connection: "Prod: main", tag: "production", date: when)
        #expect(FileNamePattern("{table}").render(c) == "users")
        #expect(FileNamePattern(FileNamePattern.backup).render(c) == "shop-2026-03-07-090502")
        #expect(FileNamePattern("{connection} {MMM} {unknown} {tag").render(c) == "Prod- main Mar {unknown} {tag")
        #expect(FileNamePattern("a/b").render(c) == "a-b")
        #expect(FileNamePattern("{table}").render(.init(), fallback: "x") == "x")
        #expect(FileNamePattern("..{table}").render(c) == "users")
    }

    @Test func segments() {
        let token = { (p: String) in FileNamePattern.Segment.token(FileNamePattern.tokens.first { $0.placeholder == p }!) }
        #expect(FileNamePattern(FileNamePattern.backup).segments == [
            token("{database}"), .text("-"), token("{yyyy}"), .text("-"), token("{MM}"), .text("-"), token("{dd}"), .text("-"),
            token("{HH}"), token("{mm}"), token("{ss}"),
        ])
        #expect(FileNamePattern("a {unknown}b{table}{tag").segments == [.text("a {unknown}b"), token("{table}"), .text("{tag")])
        #expect(FileNamePattern("").segments == [])
        for p in [FileNamePattern.backup, "a {unknown}b{table}{tag", "x"] {
            #expect(FileNamePattern(segments: FileNamePattern(p).segments).pattern == p)
        }
    }

    @Test func uniqueNames() {
        var taken = Set<String>()
        #expect(FileNamePattern.unique("a", extension: "csv", taken: &taken) == "a.csv")
        #expect(FileNamePattern.unique("A", extension: "csv", taken: &taken) == "A 2.csv")
        #expect(FileNamePattern.unique("a", extension: "csv", taken: &taken) == "a 3.csv")
    }
}

/// Unzips a workbook with the system's unzip and reads its sheets' cells with XMLDocument.
struct XLSXReader {
    let url: URL

    func part(_ name: String) throws -> XMLDocument {
        // unzip reads names as patterns; [ ] must be escaped.
        let pattern = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let (status, data) = try runTool("/usr/bin/unzip", ["-p", url.path, pattern])
        guard status == 0 else { throw DatabaseError("no part \(name)") }
        return try XMLDocument(data: data)
    }

    func sheetNames() throws -> [String] {
        try part("xl/workbook.xml").nodes(forXPath: "//*[local-name()='sheet']/@name").compactMap(\.stringValue)
    }

    /// Rows of cell values: inline strings as text, numbers and booleans as written; empty
    /// cells missing.
    func cells(sheet: Int) throws -> [[String: String]] {
        let doc = try part("xl/worksheets/sheet\(sheet).xml")
        return try doc.nodes(forXPath: "//*[local-name()='row']").map { row in
            var out: [String: String] = [:]
            for case let c as XMLElement in row.children ?? [] {
                let ref = c.attribute(forName: "r")?.stringValue ?? "?"
                let column = String(ref.prefix { $0.isLetter })
                let type = c.attribute(forName: "t")?.stringValue
                let value = try type == "inlineStr"
                    ? c.nodes(forXPath: ".//*[local-name()='t']").map { $0.stringValue ?? "" }.joined()
                    : c.nodes(forXPath: "./*[local-name()='v']").first?.stringValue ?? ""
                out[column] = (type == "b" ? "bool:" : type == "inlineStr" ? "" : "n:") + value
            }
            return out
        }
    }
}

struct XLSXTests {
    @Test func columnNames() {
        #expect(XLSXSheetWriter.columnName(0) == "A")
        #expect(XLSXSheetWriter.columnName(25) == "Z")
        #expect(XLSXSheetWriter.columnName(26) == "AA")
        #expect(XLSXSheetWriter.columnName(701) == "ZZ")
        #expect(XLSXSheetWriter.columnName(702) == "AAA")
        #expect(XLSXSheetWriter.columnName(16_383) == "XFD")
    }

    @Test func escaping() {
        #expect(XLSXSheetWriter.escape("a<b>&\"c\"") == "a&lt;b&gt;&amp;&quot;c&quot;")
        #expect(XLSXSheetWriter.escape("bell\u{7}") == "bell_x0007_")
        #expect(XLSXSheetWriter.escape("_x0041_ stays") == "_x005F_x0041_ stays")
        #expect(XLSXSheetWriter.escape("_x00G1_") == "_x00G1_")
        #expect(XLSXSheetWriter.decimalNumber("123.4500") == "123.4500")
        #expect(XLSXSheetWriter.decimalNumber("1234567890.1234567") == nil)
        #expect(XLSXSheetWriter.decimalNumber("1e5") == nil)
    }

    @Test func sheetNames() {
        #expect(XLSXWorkbook.sheetName("a/b:c?[d]", taken: []) == "a_b_c__d_")
        #expect(XLSXWorkbook.sheetName("Users", taken: ["users"]) == "Users (2)")
        let long = String(repeating: "x", count: 40)
        #expect(XLSXWorkbook.sheetName(long, taken: [String(repeating: "x", count: 31)]).count == 31)
        #expect(XLSXWorkbook.sheetName("'quoted'", taken: []) == "quoted")
    }

    @Test func workbookReadBack() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows: [[DBValue]] = [
            [.integer(1), .text("plain"), .double(2.5), .bool(true), .null],
            [.integer(9_007_199_254_740_993), .text("  spaced\nline <&> \u{1}"), .double(-1e-5), .bool(false), .blob(Data([0xAB]))],
        ]
        let job = ExportJob(source: .rows(name: "Result 1", columns: ["id", "text", "n", "b", "extra"], rows: rows, dialect: SQLiteDialect()),
                            format: .xlsx(XLSXOptions()))
        let url = dir.appending(path: "r.xlsx")
        #expect(try await job.run(to: url) == 2)
        #expect(try runTool("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        let reader = XLSXReader(url: url)
        #expect(try reader.sheetNames() == ["Result 1"])
        let cells = try reader.cells(sheet: 1)
        #expect(cells.count == 3)
        #expect(cells[0] == ["A": "id", "B": "text", "C": "n", "D": "b", "E": "extra"])
        #expect(cells[1] == ["A": "n:1", "B": "plain", "C": "n:2.5", "D": "bool:1"])
        #expect(cells[2] == ["A": "9007199254740993", "B": "  spaced\nline <&> _x0001_", "C": "n:-1e-05", "D": "bool:0", "E": "\\xab"])
        // The workbook's other parts parse too.
        for part in ["[Content_Types].xml", "_rels/.rels", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "docProps/core.xml", "docProps/app.xml"] {
            _ = try reader.part(part)
        }
    }

    @Test func rowLimit() throws {
        var w = XLSXSheetWriter(XLSXOptions(includeHeader: true))
        _ = w.header(columns: ["a"])
        _ = w.rows(Array(repeating: [.integer(1)], count: XLSXSheetWriter.maxRows - 1))
        #expect(!w.overflow)
        _ = w.rows([[.integer(2)]])
        #expect(w.overflow)
    }
}

struct TablesExportTests {
    private func shop() async throws -> (SQLiteConnection, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-tables-\(UUID().uuidString).db")
        let db = try SQLiteConnection(path: url.path)
        for sql in [
            // Listed before the table it references, so the script must reorder them.
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), total NUMERIC)",
            "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE VIEW big AS SELECT * FROM orders WHERE total > 10",
            "INSERT INTO customers VALUES (1, 'Ann'), (2, 'Bob')",
            "INSERT INTO orders VALUES (1, 1, 5), (2, 2, 25.5), (3, 1, NULL)",
        ] { _ = try await db.execute(SQLStatement(sql)) }
        return (db, url)
    }

    private var items: [TablesExportJob.Item] {
        [
            .init(DatabaseObject(TableRef("orders"), kind: .table), drop: true),
            .init(DatabaseObject(TableRef("customers"), kind: .table), drop: true),
            .init(DatabaseObject(TableRef("big"), kind: .view), drop: true),
        ]
    }

    @Test func oneSQLScriptRunsInOrder() async throws {
        let (db, url) = try await shop()
        defer { try? FileManager.default.removeItem(at: url) }
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = TablesExportJob(items: items, format: .sql(SQLExportOptions(gzip: true)), connection: db,
                                  pattern: FileNamePattern("{database}"), context: .init(database: "shop"))
        var taken = Set<String>()
        let name = job.fileName(for: nil, taken: &taken)
        #expect(name == "shop.sql.gz")
        let out = dir.appending(path: name)
        let progress = Counts()
        try await job.run(to: out) { i, _ in progress.add(i) }
        let script = String(decoding: try GzipReader.decompress(out), as: UTF8.self)
        #expect(script.hasPrefix("-- Exported by Moonrow\n-- Source: shop (3 tables)"))
        #expect(script.components(separatedBy: "-- Exported by Moonrow").count == 2)
        // Drops first, the referencing table and the view before the table they use.
        let drop = script.range(of: "DROP TABLE IF EXISTS \"orders\"")!
        #expect(script.range(of: "DROP VIEW IF EXISTS \"big\"")!.lowerBound < drop.lowerBound)
        #expect(drop.lowerBound < script.range(of: "DROP TABLE IF EXISTS \"customers\"")!.lowerBound)
        #expect(script.range(of: "CREATE TABLE customers")!.lowerBound < script.range(of: "CREATE TABLE orders")!.lowerBound)
        #expect(script.contains("PRAGMA foreign_keys = OFF;"))
        #expect(Set(progress.values) == [0, 1, 2])

        // Run into a database that already has the tables: the drops clear them.
        let target = try SQLiteConnection(path: ":memory:")
        _ = try await target.execute("PRAGMA foreign_keys = ON")
        _ = try await target.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY)")
        for s in SQLSplitter.split(script, dialect: .sqlite) { _ = try await target.execute(SQLStatement(s.text)) }
        #expect(try await target.execute("SELECT id, customer_id, total FROM orders ORDER BY id").rows
            == (try await db.execute("SELECT id, customer_id, total FROM orders ORDER BY id").rows))
        #expect(try await target.execute("SELECT count(*) FROM big").rows == [[.integer(1)]])
        #expect(try await target.execute("SELECT name FROM customers ORDER BY id").rows == [[.text("Ann")], [.text("Bob")]])
        await target.close()
        await db.close()
    }

    @Test func structureOnlyAndDataOnly() async throws {
        let (db, url) = try await shop()
        defer { try? FileManager.default.removeItem(at: url) }
        let only = [
            TablesExportJob.Item(DatabaseObject(TableRef("customers"), kind: .table), structure: true, drop: false, data: false),
            TablesExportJob.Item(DatabaseObject(TableRef("orders"), kind: .table), structure: false, drop: false, data: true),
        ]
        let job = TablesExportJob(items: only, format: .sql(SQLExportOptions()), connection: db, pattern: FileNamePattern("x"), context: .init())
        let sink = StringSink()
        try await job.writeScript(SQLExportOptions(), to: sink) { _, _ in }
        #expect(sink.text.contains("CREATE TABLE customers"))
        #expect(!sink.text.contains("INSERT INTO \"customers\""))
        #expect(!sink.text.contains("CREATE TABLE orders"))
        #expect(sink.text.contains("INSERT INTO \"orders\""))
        #expect(!sink.text.contains("DROP"))
        await db.close()
    }

    @Test func folderOfCSVAndOneWorkbook() async throws {
        let (db, url) = try await shop()
        defer { try? FileManager.default.removeItem(at: url) }
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "old".write(to: dir.appending(path: "customers.csv"), atomically: true, encoding: .utf8)
        let csv = TablesExportJob(items: Array(items.prefix(2)), format: .csv(CSVOptions()), connection: db,
                                  pattern: FileNamePattern("{table}"), context: .init())
        let files = try await csv.run(to: dir)
        #expect(files.map(\.lastPathComponent) == ["orders.csv", "customers.csv"])
        #expect(try String(contentsOf: dir.appending(path: "customers.csv"), encoding: .utf8) == "id,name\n1,Ann\n2,Bob\n")

        let book = dir.appending(path: "shop.xlsx")
        let xlsx = TablesExportJob(items: items, format: .xlsx(XLSXOptions()), connection: db, pattern: FileNamePattern("shop"), context: .init())
        try await xlsx.run(to: book)
        let reader = XLSXReader(url: book)
        #expect(try reader.sheetNames() == ["orders", "customers", "big"])
        #expect(try reader.cells(sheet: 2) == [["A": "id", "B": "name"], ["A": "n:1", "B": "Ann"], ["A": "n:2", "B": "Bob"]])
        #expect(try reader.cells(sheet: 3).count == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["orders.csv", "customers.csv", "shop.xlsx"])
        await db.close()
    }
}
