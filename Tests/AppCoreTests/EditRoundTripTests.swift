import DBKit
import DriverMySQL
import DriverSQLite
import Foundation
import Testing
import WireSupport
@testable import AppCore
@testable import DriverPostgres

/// M2's acceptance check, run by M4 against every backend: for each way the grid can edit a
/// table, the SQL shown in the commit preview is what the database reports running.
///
/// - SQLite: its statement trace, values expanded inline (`sqlite3_expanded_sql`).
/// - MySQL / MariaDB: `mysql.general_log`, where the server writes bound values inline.
/// - Postgres: the server log (jsonlog), which keeps the statement with `$n` and its parameters
///   apart; both sides are compared with the parameters written into the placeholders.
///
/// Server backends run when `scripts/test-servers.sh env` variables are set.
struct Backend: Sendable, CustomTestStringConvertible {
    enum Kind: Sendable { case sqlite, postgres, mysql }
    let kind: Kind
    let name: String
    let url: URL?

    var testDescription: String { name }

    static let all: [Backend] = [Backend(kind: .sqlite, name: "SQLite", url: nil)] + [
        (Kind.postgres, "PostgreSQL", "MOONROW_TEST_PG"),
        (.mysql, "MySQL", "MOONROW_TEST_MYSQL"),
        (.mysql, "MariaDB", "MOONROW_TEST_MARIADB"),
    ].compactMap { kind, name, variable in
        ProcessInfo.processInfo.environment[variable].flatMap(URL.init(string:)).map { Backend(kind: kind, name: name, url: $0) }
    }

    /// `CREATE TABLE` bodies in each dialect, for the same logical tables.
    func ddl(_ table: String) -> String {
        switch (kind, table) {
        case (.sqlite, "items"):
            "items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER DEFAULT 0, price REAL, note TEXT DEFAULT 'none', added TEXT DEFAULT CURRENT_TIMESTAMP)"
        case (.postgres, "items"):
            "items (id serial PRIMARY KEY, name text NOT NULL, qty integer DEFAULT 0, price double precision, note text DEFAULT 'none', added timestamp DEFAULT CURRENT_TIMESTAMP)"
        case (.mysql, "items"):
            "items (id int AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL, qty int DEFAULT 0, price double, note varchar(50) DEFAULT 'none', added datetime DEFAULT CURRENT_TIMESTAMP)"
        case (.sqlite, "nokey"): "nokey (a TEXT, b INTEGER)"
        case (.postgres, "nokey"): "nokey (a text, b integer)"
        case (.mysql, "nokey"): "nokey (a varchar(10), b int)"
        case (.sqlite, "d"): "d (id INTEGER PRIMARY KEY, v TEXT DEFAULT 'x')"
        case (.postgres, "d"): "d (id serial PRIMARY KEY, v text DEFAULT 'x')"
        case (.mysql, "d"): "d (id int AUTO_INCREMENT PRIMARY KEY, v varchar(10) DEFAULT 'x')"
        default: fatalError("no DDL for \(table)")
        }
    }
}

/// A scratch database or schema with `items` and `nokey`, a connection to edit it through, and a
/// way to read back what the server ran on that connection.
final class Fixture: @unchecked Sendable {
    let backend: Backend
    let db: any DatabaseConnection
    private var admin: (any DatabaseConnection)?
    private var scratch: String?
    private var mark: DBValue = .null
    private let traced = TraceLog()

    init(_ backend: Backend) async throws {
        self.backend = backend
        let name = "t_" + UUID().uuidString.prefix(8).lowercased()
        switch backend.kind {
        case .sqlite:
            let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-\(UUID().uuidString).db")
            let sqlite = try SQLiteConnection(path: url.path)
            let log = traced
            await sqlite.setStatementLog { log.write($0) }
            db = sqlite
        case .postgres:
            let u = URLComponents(url: backend.url!, resolvingAgainstBaseURL: false)!
            let c = PostgresConfiguration(
                endpoint: .tcp(host: u.host!, port: u.port!), user: u.user!, password: u.password,
                database: String(u.path.dropFirst()), tls: TLSSettings(mode: .disable))
            admin = try await PostgresConnection.connect(c)
            _ = try await admin!.execute("CREATE SCHEMA \(name)")
            db = try await PostgresConnection.connect(c)
            _ = try await db.execute("SET search_path TO \(name)")
            scratch = name
        case .mysql:
            let u = URLComponents(url: backend.url!, resolvingAgainstBaseURL: false)!
            func config(_ database: String?) -> MySQLConfiguration {
                MySQLConfiguration(
                    endpoint: .tcp(host: u.host!, port: u.port!), user: u.user!, password: u.password ?? "",
                    database: database, tls: TLSSettings(mode: .disable))
            }
            admin = try await MySQLConnection.connect(config(nil))
            _ = try await admin!.execute("CREATE DATABASE \(name)")
            db = try await MySQLConnection.connect(config(name))
            scratch = name
        }
        for table in ["items", "nokey"] {
            _ = try await db.execute("CREATE TABLE " + backend.ddl(table))
        }
        _ = try await db.execute("""
            INSERT INTO items (name, qty, price, note) VALUES
              ('apple', 3, 1.5, 'red'), ('pear', 5, NULL, 'it''s green'), ('fig', 0, 2.25, NULL)
            """)
        _ = try await db.execute("INSERT INTO nokey VALUES ('x', 1), ('y', 2), ('y', 2)")
    }

    func tearDown() async {
        await db.close()
        if let admin, let scratch {
            _ = try? await admin.execute(backend.kind == .postgres ? "DROP SCHEMA \(scratch) CASCADE" : "DROP DATABASE \(scratch)")
            await admin.close()
        }
    }

    func browser(_ table: String) async throws -> (TableBrowser, [[DBValue]]) {
        let browser = try await TableBrowser.open(TableRef(table), on: db)
        let key = table == "nokey" ? "a" : "id"
        let rows = try await browser.fetcher(GridQuery(sort: [SortKey(key)]))(0, 100)
        return (browser, rows)
    }

    func rows(_ sql: String) async throws -> [[DBValue]] {
        try await db.execute(sql).rows
    }

    // MARK: - Statement logs

    /// Starts collecting from here.
    func startLog() async throws {
        switch backend.kind {
        case .sqlite:
            _ = traced.take()
        case .postgres:
            mark = try await admin!.execute("SELECT size FROM pg_stat_file(pg_current_logfile('jsonlog'))").rows[0][0]
        case .mysql:
            mark = try await admin!.execute("SELECT NOW(6)").rows[0][0]
        }
    }

    /// What the edit connection ran since `startLog`, in canonical form, without transaction
    /// control statements. Waits for `count` statements (the Postgres log is written a little later).
    func ran(count: Int) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let statements = try await logged().filter {
                !["BEGIN", "COMMIT", "ROLLBACK", "START TRANSACTION"].contains($0.uppercased())
            }
            if statements.count >= count || ContinuousClock.now > deadline { return statements }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func logged() async throws -> [String] {
        switch backend.kind {
        case .sqlite:
            return traced.peek()
        case .mysql:
            let id = try await (db as! MySQLConnection).connectionID
            return try await admin!.execute(SQLStatement("""
                SELECT CAST(argument AS CHAR) FROM mysql.general_log
                WHERE thread_id = ? AND event_time >= ? AND command_type IN ('Query', 'Execute')
                ORDER BY event_time
                """, bindings: [.integer(Int64(id)), mark])).rows.map { $0[0].displayString }
        case .postgres:
            let pid = try await (db as! PostgresConnection).backendProcessID()
            let text = try await admin!.execute(SQLStatement("""
                SELECT pg_read_file(pg_current_logfile('jsonlog'), $1, (SELECT size FROM pg_stat_file(pg_current_logfile('jsonlog'))) - $1)
                """, bindings: [mark])).rows[0][0].displayString
            return text.split(separator: "\n").compactMap { line -> String? in
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      entry["pid"] as? Int == Int(pid), let message = entry["message"] as? String else { return nil }
                for prefix in ["execute <unnamed>: ", "statement: "] where message.hasPrefix(prefix) {
                    let sql = String(message.dropFirst(prefix.count))
                    return Self.substitute(sql, Self.parameters(entry["detail"] as? String ?? ""))
                }
                return nil
            }
        }
    }

    /// The previewed statements in the form the log is compared in.
    func expected(_ browser: TableBrowser, _ edits: TableEdits) -> [String] {
        let fragments = browser.dialect.statements(for: edits.changeSet(dialect: browser.dialect))
        return fragments.map { expected($0, browser.dialect) }
    }

    func expected(_ fragment: SQLFragment, _ dialect: any Dialect) -> String {
        guard backend.kind == .postgres else { return fragment.inlined(for: dialect) }
        let statement = fragment.statement(for: dialect)
        return Self.substitute(statement.sql, statement.bindings.map(PGType.logged))
    }

    /// `$n` → the n-th value, highest first so `$1` doesn't eat `$10`.
    static func substitute(_ sql: String, _ values: [String]) -> String {
        var out = sql
        for (i, v) in values.enumerated().reversed() { out = out.replacingOccurrences(of: "$\(i + 1)", with: v) }
        return out
    }

    /// `Parameters: $1 = '7', $2 = NULL` → `["'7'", "NULL"]`.
    static func parameters(_ detail: String) -> [String] {
        guard let start = detail.range(of: "Parameters: ") else { return [] }
        var out: [String] = []
        var s = Substring(detail[start.upperBound...])
        while let eq = s.range(of: " = ") {
            s = s[eq.upperBound...]
            if s.hasPrefix("NULL") {
                out.append("NULL")
                s = s.dropFirst(4)
            } else if s.first == "'" {
                var i = s.index(after: s.startIndex)
                while i < s.endIndex {
                    if s[i] == "'" {
                        let next = s.index(after: i)
                        if next < s.endIndex, s[next] == "'" { i = s.index(after: next); continue }
                        break
                    }
                    i = s.index(after: i)
                }
                let end = s.index(after: min(i, s.index(before: s.endIndex)))
                out.append(String(s[..<end]))
                s = s[end...]
            }
        }
        return out
    }
}

final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func write(_ s: String) { lock.withLock { lines.append(s) } }
    func take() -> [String] { lock.withLock { defer { lines = [] }; return lines } }
    func peek() -> [String] { lock.withLock { lines } }
}

@Suite(.serialized) struct EditRoundTripTests {
    /// Commits, and returns what the database ran next to what the preview promised.
    private func commit(_ f: Fixture, _ browser: TableBrowser, _ edits: TableEdits) async throws -> (preview: [String], expected: [String], ran: [String]) {
        let preview = browser.preview(edits).map { String($0.dropLast()) }
        let expected = f.expected(browser, edits)
        try await f.startLog()
        try await browser.commit(edits)
        return (preview, expected, try await f.ran(count: expected.count))
    }

    @Test(arguments: Backend.all) func cellEdits(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("items")
        func type(_ column: Int) -> String { b.columns[column].typeName }
        var e = b.newEdits()
        e.set(.value(CellInput.parse("plum's", typeName: type(1))), column: 1, in: rows[0])
        e.set(.value(CellInput.parse("7", typeName: type(2))), column: 2, in: rows[0])
        e.set(.value(CellInput.parse("0.75", typeName: type(3))), column: 3, in: rows[0])
        e.set(.value(.null), column: 4, in: rows[1])         // Set Value ▸ NULL
        e.set(.value(.text("")), column: 1, in: rows[2])     // Set Value ▸ EMPTY
        e.set(.defaultValue, column: 4, in: rows[2])         // Set Value ▸ DEFAULT
        e.set(.defaultValue, column: 5, in: rows[1])         // DEFAULT CURRENT_TIMESTAMP

        let (preview, expected, ran) = try await commit(f, b, e)
        switch backend.kind {
        case .sqlite:
            #expect(preview == [
                #"UPDATE "items" SET "name" = 'plum''s', "qty" = 7, "price" = 0.75 WHERE "id" = 1"#,
                #"UPDATE "items" SET "note" = NULL, "added" = CURRENT_TIMESTAMP WHERE "id" = 2"#,
                #"UPDATE "items" SET "name" = '', "note" = ('none') WHERE "id" = 3"#,
            ])
        case .postgres:
            #expect(preview == [
                #"UPDATE "items" SET "name" = 'plum''s', "qty" = 7, "price" = 0.75 WHERE "id" = 1"#,
                #"UPDATE "items" SET "note" = NULL, "added" = DEFAULT WHERE "id" = 2"#,
                #"UPDATE "items" SET "name" = '', "note" = DEFAULT WHERE "id" = 3"#,
            ])
        case .mysql:
            #expect(preview == [
                #"UPDATE `items` SET `name` = 'plum\'s', `qty` = 7, `price` = 0.75 WHERE `id` = 1"#,
                #"UPDATE `items` SET `note` = NULL, `added` = DEFAULT WHERE `id` = 2"#,
                #"UPDATE `items` SET `name` = '', `note` = DEFAULT WHERE `id` = 3"#,
            ])
        }
        #expect(ran == expected)
        #expect(try await f.rows("SELECT name, qty, price, note FROM items ORDER BY id") == [
            [.text("plum's"), .integer(7), .double(0.75), .text("red")],
            [.text("pear"), .integer(5), .null, .null],
            [.text(""), .integer(0), .double(2.25), .text("none")],
        ])
    }

    @Test(arguments: Backend.all) func editingThePrimaryKey(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("items")
        var e = b.newEdits()
        e.set(.value(.integer(10)), column: 0, in: rows[1])
        let (_, expected, ran) = try await commit(f, b, e)
        #expect(ran == expected && ran.count == 1)
        #expect(try await f.rows("SELECT id FROM items ORDER BY id") == [[.integer(1)], [.integer(3)], [.integer(10)]])
    }

    @Test(arguments: Backend.all) func insertDuplicateAndDelete(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("items")
        var e = b.newEdits()
        e.addRow([1: .value(.text("kiwi")), 2: .value(.integer(4))])
        e.addRow([1: .value(.text("blank"))])
        // Duplicate: every value but the primary key, which takes its default.
        let pk = Set(b.columns.indices.filter { b.columns[$0].primaryKeyPosition != nil })
        e.addRow(Dictionary(uniqueKeysWithValues: rows[0].indices.filter { !pk.contains($0) }.map { ($0, CellChange.value(rows[0][$0])) }))
        e.delete(rows[2])

        let (preview, expected, ran) = try await commit(f, b, e)
        #expect(preview.count == 4)
        let q = b.dialect.quoteIdentifier
        #expect(preview[0] == "DELETE FROM \(q("items")) WHERE \(q("id")) = 3")
        #expect(preview[1] == "INSERT INTO \(q("items")) (\(q("name")), \(q("qty"))) VALUES ('kiwi', 4)")
        #expect(ran == expected)
        #expect(try await f.rows("SELECT name, qty, note FROM items ORDER BY id") == [
            [.text("apple"), .integer(3), .text("red")],
            [.text("pear"), .integer(5), .text("it's green")],
            [.text("kiwi"), .integer(4), .text("none")],
            [.text("blank"), .integer(0), .text("none")],
            [.text("apple"), .integer(3), .text("red")],
        ])
    }

    @Test(arguments: Backend.all) func insertWithEveryColumnDefault(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        _ = try await f.db.execute("CREATE TABLE " + backend.ddl("d"))
        let (b, _) = try await f.browser("d")
        var e = b.newEdits()
        e.addRow()
        let (preview, expected, ran) = try await commit(f, b, e)
        #expect(preview == [backend.kind == .mysql ? "INSERT INTO `d` () VALUES ()" : #"INSERT INTO "d" DEFAULT VALUES"#])
        #expect(ran == expected)
        #expect(try await f.rows("SELECT v FROM d") == [[.text("x")]])
    }

    @Test(arguments: Backend.all) func tableWithoutPrimaryKey(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("nokey")
        #expect(!b.hasPrimaryKey)
        var e = b.newEdits()
        e.set(.value(.text("z")), column: 0, in: rows[0])
        let (preview, expected, ran) = try await commit(f, b, e)
        let q = b.dialect.quoteIdentifier
        #expect(preview == ["UPDATE \(q("nokey")) SET \(q("a")) = 'z' WHERE \(q("a")) = 'x' AND \(q("b")) = 1"])
        #expect(ran == expected)
    }

    @Test(arguments: Backend.all) func duplicateRowsAreNotTouched(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("nokey")
        var e = b.newEdits()
        e.set(.value(.text("first")), column: 0, in: rows[0])
        e.delete(rows[1])   // matches both ('y', 2) rows
        await #expect(throws: DatabaseError.self) { try await b.commit(e) }
        // Rolled back, including the statement that succeeded.
        #expect(try await f.rows("SELECT a FROM nokey ORDER BY a") == [[.text("x")], [.text("y")], [.text("y")]])
    }

    @Test(arguments: Backend.all) func rowChangedMeanwhileFailsTheCommit(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let (b, rows) = try await f.browser("items")
        var e = b.newEdits()
        e.addRow([1: .value(.text("new"))])
        e.set(.value(.text("gone")), column: 1, in: rows[0])
        _ = try await f.db.execute("DELETE FROM items WHERE id = 1")
        await #expect(throws: DatabaseError.self) { try await b.commit(e) }
        #expect(try await f.rows("SELECT count(*) FROM items") == [[.integer(2)]])
    }

    @Test(arguments: Backend.all) func pagingSortAndFilterSQL(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let b = try await TableBrowser.open(TableRef("items"), on: f.db)
        let query = GridQuery(
            filter: Filter([FilterCondition(.column("name"), .contains, "p")]),
            sort: [SortKey("qty", ascending: false)],
            page: Paging(pageSize: 1, offset: 1))
        let select = b.select(query, offset: 0, limit: 1)
        if backend.kind == .sqlite {
            #expect(select.inlined(for: b.dialect) == #"""
                SELECT * FROM "items" WHERE CAST("name" AS TEXT) LIKE '%p%' ESCAPE '\' ORDER BY "qty" DESC LIMIT 1 OFFSET 1
                """#)
        }
        #expect(try await b.count(filter: query.filter) == 2)
        try await f.startLog()
        let rows = try await b.fetcher(query)(0, 1)
        #expect(rows.map { $0[1] } == [.text("apple")])
        #expect(try await f.ran(count: 1) == [f.expected(select, b.dialect)])
    }

    /// Server pages without a sort are ordered by the primary key.
    @Test(arguments: Backend.all) func unsortedPagesFollowTheKeyOnServers(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let b = try await TableBrowser.open(TableRef("items"), on: f.db)
        let sql = b.select(GridQuery(), offset: 0, limit: 10).inlined(for: b.dialect)
        let q = b.dialect.quoteIdentifier
        let order = backend.kind == .sqlite ? "" : " ORDER BY \(q("id")) ASC"
        #expect(sql == "SELECT * FROM \(q("items"))\(order) LIMIT 10")
        let keyless = try await TableBrowser.open(TableRef("nokey"), on: f.db)
        #expect(!keyless.select(GridQuery(), offset: 0, limit: 10).inlined(for: b.dialect).contains("ORDER BY"))
    }

    /// One workspace commit: row edits on two tables, a truncate and a drop. What the server ran
    /// is what the preview listed, in that order (M6.5).
    @Test(arguments: Backend.all) func workspaceCommit(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        _ = try await f.db.execute("CREATE TABLE " + backend.ddl("d"))
        let (items, rows) = try await f.browser("items")
        let changes = await StagedChanges()
        var e = items.newEdits()
        e.set(.value(.text("plum")), column: 1, in: rows[0])
        e.delete(rows[2])
        await changes.setEdits(e)
        let d = f.db.dialect
        let nokey = DatabaseObject(TableRef("nokey"), kind: .table)
        await changes.stage(StagedAction(.truncate, nokey, plan: try await ObjectActions.truncatePlan([nokey.ref], options: TruncateOptions(), on: f.db)))
        let drop = DatabaseObject(TableRef("d"), kind: .table)
        await changes.stage(StagedAction(.drop, drop, plan: try await ObjectActions.dropPlan([drop], options: DropOptions(), on: f.db)))
        let plan = try await changes.plan(dialect: d)

        let rowStatements = plan.sections.flatMap(\.rows)
        let ddl = plan.sections.compactMap(\.ddl).flatMap { $0.setup + $0.statements + $0.teardown }
        let expected = rowStatements.map { f.expected($0, d) } + ddl
        #expect(plan.statements == rowStatements.map { $0.inlined(for: d) } + ddl)
        #expect(plan.isAtomic == (backend.kind != .mysql))
        try await f.startLog()
        try await f.db.run(plan)
        #expect(try await f.ran(count: expected.count) == expected)
        #expect(try await f.rows("SELECT name FROM items ORDER BY id") == [[.text("plum")], [.text("pear")]])
        #expect(try await f.rows("SELECT COUNT(*) FROM nokey").first?.first?.displayString == "0")
        #expect(try await f.db.objects(schema: nil).map(\.ref.name).sorted() == ["items", "nokey"])
    }

    /// Renames are staged (M7): a table's through its structure editor, a view's as its own
    /// action (SQLite can't rename views). The servers run what the preview shows.
    @Test(arguments: Backend.all) func stagedRenames(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        _ = try await f.db.execute("CREATE VIEW v AS SELECT * FROM items")
        let changes = await StagedChanges()
        var s = StructureEditor(try await f.db.structure(of: TableRef("nokey")))
        s.name = "nokey2"
        await changes.setStructure(s)
        let v = DatabaseObject(TableRef("v"), kind: .view)
        if backend.kind != .sqlite {
            await changes.stage(StagedAction(.rename(to: "v2"), v, plan: try ObjectActions.renamePlan(v, to: "v2", on: f.db)))
        }
        #expect(await changes.stagedName(for: TableRef("nokey")) == "nokey2")
        let plan = try await changes.plan(dialect: f.db.dialect)
        try await f.startLog()
        try await f.db.run(plan)
        #expect(try await f.ran(count: plan.statements.count) == plan.statements)
        let names = try await f.db.objects(schema: nil).map(\.ref.name).sorted()
        #expect(names == ["items", "nokey2", backend.kind == .sqlite ? "v" : "v2"])
    }

    /// The planner estimate runs on Postgres and small tables still get counted.
    @Test(arguments: Backend.all) func rowCountOfSmallTables(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let b = try await TableBrowser.open(TableRef("items"), on: f.db)
        if let sql = b.dialect.estimatedCount(b.table) {
            _ = try await f.db.execute("ANALYZE items")
            #expect(try await f.db.execute(sql).rows == [[.integer(3)]])
        }
        #expect(try await b.rowCount() == RowCount(3))
    }
}
