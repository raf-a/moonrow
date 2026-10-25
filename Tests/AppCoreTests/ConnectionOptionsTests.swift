import DBKit
import DriverSQLite
import Foundation
import SQLScript
import Testing
@testable import AppCore

/// Per-connection options: bootstrap commands, and how the factory applies them.
@Suite struct ConnectionOptionsTests {
    private func sqliteFile() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-options-\(UUID().uuidString).sqlite")
        let db = try SQLiteConnection(path: url.path)
        await db.close()
        return url
    }

    @Test func bootstrapIsSavedAndSplit() throws {
        var c = ConnectionConfig(driver: .mysql)
        c.bootstrapSQL = "SET @a = 1; -- a note\nSET @b = 2;\n\nDELIMITER //\nSELECT 1; SELECT 2 //\nDELIMITER ;\n-- only a comment"
        #expect(c.bootstrapStatements == ["SET @a = 1", "-- a note\nSET @b = 2", "SELECT 1; SELECT 2"])
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(ConnectionConfig.self, from: data).bootstrapSQL == c.bootstrapSQL)
        // Files written before bootstrap commands existed load with none.
        let old = #"{"id":"\#(UUID().uuidString)","driver":"postgres","host":"db"}"#
        #expect(try JSONDecoder().decode(ConnectionConfig.self, from: Data(old.utf8)).bootstrapSQL == "")
        #expect(ConnectionConfig(driver: .postgres).bootstrapStatements.isEmpty)
    }

    @Test func sqliteRunsBootstrapOnOpen() async throws {
        let url = try await sqliteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var c = ConnectionConfig.sqliteFile(url)
        c.bootstrapSQL = "CREATE TEMP TABLE boot (x);\nINSERT INTO boot VALUES (1), (2);"
        let db = try await ConnectionFactory.open(c)
        #expect(try await db.execute("SELECT count(*) FROM boot").rows.first?.first == .integer(2))
        await db.close()
    }

    @Test func failingBootstrapFailsTheConnect() async throws {
        let url = try await sqliteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var c = ConnectionConfig.sqliteFile(url)
        c.bootstrapSQL = "SELECT 1;\nSELEC 2;"
        do {
            _ = try await ConnectionFactory.open(c)
            Issue.record("the connect should fail")
        } catch let e as DatabaseError {
            #expect(e.message.hasPrefix("A bootstrap command failed: "))
            #expect(e.sql == "SELEC 2")
        }
    }

    static let servers = Backend.all.filter { $0.kind != .sqlite }

    private func config(_ backend: Backend) throws -> (ConnectionConfig, String?) {
        let (config, password) = try #require(ConnectionConfig.parse(url: backend.url!.absoluteString))
        var c = config
        c.tlsMode = .disable
        return (c, password)
    }

    /// The bootstrap's session setting holds on the first session and again after the server
    /// drops it and the connection opens a new one.
    @Test(arguments: servers) func serverRunsBootstrapOnEverySession(_ backend: Backend) async throws {
        var (c, password) = try config(backend)
        let set = backend.kind == .postgres ? "SET statement_timeout = '12345ms'" : "SET @moonrow_boot = 42"
        let read = backend.kind == .postgres ? "SHOW statement_timeout" : "SELECT @moonrow_boot"
        let expected: DBValue = backend.kind == .postgres ? .text("12345ms") : .integer(42)
        c.bootstrapSQL = "-- session settings\n\(set);"
        let db = try await ConnectionFactory.open(c, password: password)
        let watcher = try await ConnectionFactory.open(c, password: password)
        defer { Task { await db.close(); await watcher.close() } }
        #expect(try await db.execute(read).rows.first?.first == expected)
        let first = try #require(await ServerSessions.ownID(of: db))
        // A new session's bootstrap is in the query log, as everything sent on the connection is.
        let sent = Sent()
        db.statementLog?.observe { sent.add($0.sql) }

        try await ServerSessions.kill(first, terminate: true, on: watcher)
        // The next statement may still meet the dead socket; the one after gets a new session.
        var value: DBValue?
        for _ in 0..<20 {
            if let v = try? await db.execute(read).rows.first?.first { value = v; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try #require(await ServerSessions.ownID(of: db)) != first)
        #expect(value == expected)
        #expect(sent.all.contains("-- session settings\n" + set))
    }

    @Test(arguments: servers) func failingServerBootstrapFailsTheConnect(_ backend: Backend) async throws {
        var (c, password) = try config(backend)
        c.bootstrapSQL = "SELECT 1; SELECT * FROM moonrow_no_such_table;"
        do {
            let db = try await ConnectionFactory.open(c, password: password)
            await db.close()
            Issue.record("the connect should fail")
        } catch let e as DatabaseError {
            #expect(e.message.hasPrefix("A bootstrap command failed: "))
            #expect(e.sql == "SELECT * FROM moonrow_no_such_table")
        }
    }
}

/// The query timeout and keepalive.
@Suite struct TimeoutAndKeepAliveTests {
    private func run(_ sql: String, on db: any DatabaseConnection, lexer: LexerDialect, timeout: Duration?)
        async -> [ScriptRunner.Event] {
        var events: [ScriptRunner.Event] = []
        let options = ScriptRunner.Options(timeout: timeout)
        for await e in ScriptRunner.run(SQLSplitter.split(sql, dialect: lexer), on: db, options: options) { events.append(e) }
        return events
    }

    private func failure(_ events: [ScriptRunner.Event]) -> ScriptRunner.Failure? {
        for case .failed(_, let f) in events { return f }
        return nil
    }

    @Test func settingsKeepTimeoutAndKeepAlive() throws {
        #expect(AppSettings().queryTimeout == 300)
        #expect(AppSettings().keepAlive == false)
        #expect(AppSettings().queryTimeLimit == .seconds(300))
        var s = AppSettings()
        s.queryTimeout = 0
        #expect(s.queryTimeLimit == nil)
        let read = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"queryTimeout": -5, "keepAlive": true}"#.utf8))
        #expect(read.queryTimeout == 0)
        #expect(read.keepAlive)
    }

    @Test func sqliteStatementStopsAtTheTimeout() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n; SELECT 2;"
        let clock = ContinuousClock()
        let start = clock.now
        let events = await run(endless, on: db, lexer: .sqlite, timeout: .seconds(1))
        #expect(clock.now - start < .seconds(5))
        #expect(failure(events)?.message == "Stopped after 1 second, the query timeout.")
        // The run stops there, as at any error; the connection goes on.
        #expect(!events.contains { if case .started(1) = $0 { true } else { false } })
        #expect(try await db.execute("SELECT 3").rows.first?.first == .integer(3))
    }

    @Test func timeoutMessageNamesTheLimit() {
        #expect(ScriptRunner.Timeout(limit: .seconds(300)).localizedDescription == "Stopped after 300 seconds, the query timeout.")
        #expect(ScriptRunner.Timeout(limit: .seconds(1)).localizedDescription == "Stopped after 1 second, the query timeout.")
    }

    @Test func fastStatementsIgnoreTheTimeout() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let events = await run("SELECT 1; SELECT 2;", on: db, lexer: .sqlite, timeout: .seconds(30))
        #expect(failure(events) == nil)
        #expect(events.filter { if case .finished = $0 { true } else { false } }.count == 2)
    }

    static let servers = Backend.all.filter { $0.kind != .sqlite }

    private func open(_ backend: Backend) async throws -> any DatabaseConnection {
        let (config, password) = try #require(ConnectionConfig.parse(url: backend.url!.absoluteString))
        var c = config
        c.tlsMode = .disable
        return try await ConnectionFactory.open(c, password: password)
    }

    @Test(arguments: servers) func serverStatementStopsAtTheTimeout(_ backend: Backend) async throws {
        let db = try await open(backend)
        defer { Task { await db.close() } }
        let sleep = backend.kind == .postgres ? "SELECT pg_sleep(30);" : "SELECT SLEEP(30);"
        let clock = ContinuousClock()
        let start = clock.now
        let events = await run(sleep, on: db, lexer: backend.kind == .postgres ? .postgres : .mysql, timeout: .seconds(1))
        #expect(clock.now - start < .seconds(10))
        #expect(failure(events)?.message == "Stopped after 1 second, the query timeout.")
        #expect(try await db.execute("SELECT 1").rows.first?.first == .integer(1))
    }

    /// Pings arrive while the session is idle, and stop when keepalive is turned off.
    @Test(arguments: servers) func idleSessionsArePinged(_ backend: Backend) async throws {
        let db = try await open(backend)
        let watcher = try await open(backend)
        defer { Task { await db.close(); await watcher.close() } }
        if backend.kind == .postgres {
            let pid = try #require(await ServerSessions.ownID(of: db))
            _ = try await db.execute("SELECT 'busy'")
            db.setKeepAlive(.milliseconds(300))
            try await Task.sleep(for: .milliseconds(1_200))
            let last = try await watcher.execute(SQLStatement("SELECT query FROM pg_stat_activity WHERE pid = $1", bindings: [.integer(Int64(pid))]))
            #expect(last.rows.first?.first == .text("SELECT 1"))
        } else {
            func questions() async throws -> Int {
                let r = try await db.execute("SHOW SESSION STATUS LIKE 'Questions'")
                guard case .text(let v)? = r.rows.first?.last else { return -1 }
                return Int(v) ?? -1
            }
            let before = try await questions()
            db.setKeepAlive(.milliseconds(300))
            try await Task.sleep(for: .milliseconds(1_200))
            db.setKeepAlive(nil)
            let pinged = try await questions() - before
            #expect(pinged >= 3)   // at least two pings, and the second read
            try await Task.sleep(for: .milliseconds(800))
            #expect(try await questions() - before == pinged + 1)
        }
    }
}

/// TLS server name, direct negotiation, and the MySQL / MariaDB type check.
@Suite struct ServerOptionsTests {
    @Test func tlsOptionsReachTheDrivers() {
        var c = ConnectionConfig(driver: .mysql, host: "10.0.0.5")
        c.tlsServerName = " db.internal.example "
        #expect(ConnectionFactory.mysqlConfiguration(c, password: nil).tls.serverName == "db.internal.example")
        c.tlsServerName = ""
        #expect(ConnectionFactory.mysqlConfiguration(c, password: nil).tls.serverName == nil)
        var p = ConnectionConfig(driver: .postgres, host: "db")
        #expect(!ConnectionFactory.postgresConfiguration(p, password: nil).directTLS)
        p.tlsDirect = true
        #expect(ConnectionFactory.postgresConfiguration(p, password: nil).directTLS)
    }

    @Test func savedOptionsLoad() throws {
        var c = ConnectionConfig(driver: .postgres)
        c.tlsDirect = true
        c.tlsServerName = "sni"
        c.keepsDriverForOtherServer = true
        let back = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(c))
        #expect(back.tlsDirect && back.tlsServerName == "sni" && back.keepsDriverForOtherServer)
    }

    @Test func suggestsTheOtherTypeOfTheFamily() {
        var c = ConnectionConfig(driver: .mysql)
        #expect(c.suggestedDriver(forServer: .mariadb) == .mariadb)
        #expect(c.suggestedDriver(forServer: .mysql) == nil)
        #expect(c.suggestedDriver(forServer: nil) == nil)
        c.keepsDriverForOtherServer = true
        #expect(c.suggestedDriver(forServer: .mariadb) == nil)
        #expect(ConnectionConfig(driver: .mariadb).suggestedDriver(forServer: .mysql) == .mysql)
        #expect(ConnectionConfig(driver: .postgres).suggestedDriver(forServer: .mysql) == nil)
    }

    @Test func testReportsTheServersKind() async throws {
        for (variable, kind) in [("MOONROW_TEST_MYSQL", DriverKind.mysql), ("MOONROW_TEST_MARIADB", .mariadb)] {
            guard let url = ProcessInfo.processInfo.environment[variable] else { continue }
            var (c, password) = try #require(ConnectionConfig.parse(url: url))
            c.tlsMode = .disable
            #expect(try await ConnectionFactory.test(c, password: password) == kind)
        }
    }

    /// Postgres 17+ takes TLS without the SSLRequest first.
    @Test func postgresDirectTLS() async throws {
        guard let url = ProcessInfo.processInfo.environment["MOONROW_TEST_PG"] else { return }
        var (c, password) = try #require(ConnectionConfig.parse(url: url))
        c.tlsMode = .require
        c.tlsDirect = true
        let db = try await ConnectionFactory.open(c, password: password)
        #expect(try await db.execute("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").rows.first?.first == .bool(true))
        await db.close()
    }
}

final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var sql: [String] = []
    func add(_ s: String) { lock.withLock { sql.append(s) } }
    var all: [String] { lock.withLock { sql } }
}

/// Open Database (⌘K) and New Database…: listing, switching, creating with encoding and
/// collation, renaming and dropping.
@Suite(.serialized) struct DatabaseCatalogTests {
    static let servers = Backend.all.filter { $0.kind != .sqlite }

    private func open(_ backend: Backend) async throws -> any DatabaseConnection {
        let (config, password) = try #require(ConnectionConfig.parse(url: backend.url!.absoluteString))
        var c = config
        c.tlsMode = .disable
        return try await ConnectionFactory.open(c, password: password)
    }

    @Test func createStatements() {
        let pg = PostgresDialect(), my = MySQLDialect()
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "shop"), dialect: pg) == #"CREATE DATABASE "shop""#)
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "shop", encoding: "LATIN1"), dialect: pg)
            == #"CREATE DATABASE "shop" ENCODING 'LATIN1' TEMPLATE template0"#)
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "s", encoding: "UTF8", collation: DatabaseCollation(name: "en_US", locale: "en_US.utf8")), dialect: pg)
            == #"CREATE DATABASE "s" ENCODING 'UTF8' LC_COLLATE 'en_US.utf8' LC_CTYPE 'en_US.utf8' TEMPLATE template0"#)
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "s", collation: DatabaseCollation(name: "de-x-icu", provider: .icu, locale: "de")), dialect: pg)
            == #"CREATE DATABASE "s" LOCALE_PROVIDER icu ICU_LOCALE 'de' TEMPLATE template0"#)
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "s", collation: DatabaseCollation(name: "pg_c_utf8", provider: .builtin, locale: "C.UTF-8")), dialect: pg)
            == #"CREATE DATABASE "s" LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' TEMPLATE template0"#)
        #expect(DatabaseCatalog.createSQL(NewDatabase(name: "shop", encoding: "latin1", collation: DatabaseCollation(name: "latin1_swedish_ci")), dialect: my)
            == "CREATE DATABASE `shop` CHARACTER SET `latin1` COLLATE `latin1_swedish_ci`")
        #expect(DatabaseCatalog.renameSQL("a", to: "b", dialect: pg) == #"ALTER DATABASE "a" RENAME TO "b""#)
        #expect(DatabaseCatalog.renameSQL("a", to: "b", dialect: my) == nil)
        #expect(DatabaseCatalog.dropSQL("a", dialect: my) == "DROP DATABASE `a`")
    }

    @Test(arguments: servers) func listsEncodingsAndCollations(_ backend: Backend) async throws {
        let db = try await open(backend)
        defer { Task { await db.close() } }
        let encodings = try await DatabaseCatalog.encodings(db)
        let utf8 = backend.kind == .postgres ? "UTF8" : "utf8mb4"
        #expect(encodings.contains(utf8))
        // Client-only encodings can't be a database's.
        #expect(!encodings.contains("SJIS"))
        let all = try await DatabaseCatalog.collations(db, encoding: nil)
        let latin = try await DatabaseCatalog.collations(db, encoding: backend.kind == .postgres ? "LATIN1" : "latin1")
        #expect(latin.count < all.count)
        if backend.kind == .postgres {
            #expect(latin.contains { $0.name == "C" })
            #expect(!latin.contains { $0.name == "en_US.utf8" })
            #expect(all.contains { $0.provider == .icu })
        } else {
            #expect(latin.contains { $0.name == "latin1_swedish_ci" })
            #expect(latin.allSatisfy { $0.name.hasPrefix("latin1_") })
        }
    }

    /// Created with an encoding and collation, listed, switched to and back, renamed (Postgres)
    /// and dropped.
    @Test(arguments: servers) func createsSwitchesRenamesAndDrops(_ backend: Backend) async throws {
        let db = try await open(backend)
        defer { Task { await db.close() } }
        let name = "moonrow_m12_\(Int.random(in: 1000...9999))"
        let home = try #require(try await DatabaseCatalog.current(db) ?? (backend.kind == .postgres ? nil : "mysql"))
        let new = backend.kind == .postgres
            ? NewDatabase(name: name, encoding: "UTF8", collation: DatabaseCollation(name: "C", locale: "C"))
            : NewDatabase(name: name, encoding: "latin1", collation: DatabaseCollation(name: "latin1_swedish_ci"))
        _ = try await db.execute(SQLStatement(DatabaseCatalog.createSQL(new, dialect: db.dialect)))
        var dropName = name
        defer {
            let drop = DatabaseCatalog.dropSQL(dropName, dialect: db.dialect)
            Task {
                let cleanup = try? await open(backend)
                _ = try? await cleanup?.execute(SQLStatement(drop))
                await cleanup?.close()
            }
        }
        #expect(try await DatabaseCatalog.switchable(db).contains(name))
        if backend.kind == .postgres {
            #expect(try await !DatabaseCatalog.switchable(db).contains("template0"))
        }

        try await DatabaseCatalog.switchTo(name, on: db)
        #expect(try await DatabaseCatalog.current(db) == name)
        if backend.kind == .postgres {
            let row = try await db.execute("SELECT pg_encoding_to_char(encoding), datcollate FROM pg_database WHERE datname = current_database()").rows.first
            #expect(row?.first == .text("UTF8") && row?.last == .text("C"))
        } else {
            let row = try await db.execute("SELECT @@character_set_database, @@collation_database").rows.first
            #expect(row?.first == .text("latin1") && row?.last == .text("latin1_swedish_ci"))
        }
        // A session the server drops comes back in the new database.
        if backend.kind == .postgres {
            let watcher = try await open(backend)
            let pid = try #require(await ServerSessions.ownID(of: db))
            try await ServerSessions.kill(pid, terminate: true, on: watcher)
            await watcher.close()
            var now: String?
            for _ in 0..<20 {
                if let n = try? await DatabaseCatalog.current(db) { now = n; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(now == name)
            // A database that isn't there leaves the connection where it was.
            await #expect(throws: (any Error).self) { try await DatabaseCatalog.switchTo("moonrow_no_such_db", on: db) }
            #expect(try await DatabaseCatalog.current(db) == name)
        }

        try await DatabaseCatalog.switchTo(home, on: db)
        #expect(try await DatabaseCatalog.current(db) == home)
        if let rename = DatabaseCatalog.renameSQL(name, to: name + "_r", dialect: db.dialect) {
            _ = try await db.execute(SQLStatement(rename))
            dropName = name + "_r"
            #expect(try await DatabaseCatalog.switchable(db).contains(dropName))
        }
        _ = try await db.execute(SQLStatement(DatabaseCatalog.dropSQL(dropName, dialect: db.dialect)))
        #expect(try await !DatabaseCatalog.switchable(db).contains(dropName))
    }
}

/// Encrypted SQLite (SQLCipher) through the factory, as a saved connection opens it.
@Suite struct SQLCipherTests {
    private func path() -> String {
        FileManager.default.temporaryDirectory.appending(path: "moonrow-cipher-\(UUID().uuidString).sqlite").path
    }

    private func config(_ path: String) -> ConnectionConfig {
        ConnectionConfig(driver: .sqlite, filePath: path, passwordMode: .keychain)
    }

    /// A database encrypted with `statements` run first (PRAGMA key, compatibility), then a table.
    private func make(_ path: String, _ setup: [String]) async throws {
        let db = try SQLiteConnection(path: path)
        for sql in setup { _ = try await db.execute(SQLStatement(sql)) }
        _ = try await db.execute("CREATE TABLE secrets (id INTEGER PRIMARY KEY, note TEXT)")
        _ = try await db.execute("INSERT INTO secrets (note) VALUES ('hidden')")
        await db.close()
    }

    @Test func libraryIsSQLCipher() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(try await db.execute("SELECT sqlite_version()").rows.first?.first == .text("3.53.4"))
        guard case .text(let cipher)? = try await db.execute("PRAGMA cipher_version").rows.first?.first else {
            Issue.record("no cipher_version")
            return
        }
        #expect(cipher.hasPrefix("4.19.0"))
        #expect(try await db.execute("SELECT sqlite_compileoption_used('ENABLE_FTS5')").rows.first?.first == .integer(1))
        await db.close()
    }

    @Test func opensWithItsPassphraseOnly() async throws {
        let p = path()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let passphrase = #"pa"ss'wörd"#
        try await make(p, ["PRAGMA key = 'pa\"ss''wörd'"])
        // The bytes on disk aren't SQLite's plain header.
        let header = try FileHandle(forReadingFrom: URL(filePath: p)).read(upToCount: 16) ?? Data()
        #expect(header != Data("SQLite format 3\0".utf8))

        let db = try await ConnectionFactory.open(config(p), password: passphrase)
        #expect(try await db.execute("SELECT note FROM secrets").rows.first?.first == .text("hidden"))
        #expect(await (db as? SQLiteConnection)?.cipherCompatibility == nil)
        await db.close()

        do {
            _ = try await ConnectionFactory.open(config(p), password: nil)
            Issue.record("opened without the passphrase")
        } catch let e as DatabaseError {
            #expect(e.message.hasPrefix("This file is encrypted"))
        }
        do {
            _ = try await ConnectionFactory.open(config(p), password: "wrong")
            Issue.record("opened with a wrong passphrase")
        } catch let e as DatabaseError {
            #expect(e.message.hasPrefix("The passphrase doesn't open this database"))
        }
        // "No password" never sends one.
        var none = config(p)
        none.passwordMode = .none
        await #expect(throws: DatabaseError.self) { try await ConnectionFactory.open(none, password: passphrase) }
    }

    @Test func rawKeyInHex() async throws {
        let p = path()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let key = "x'2DD29CA851E7B56E4697B0E1F08507293D761A05CE4D1B628663F411A8086D99'"
        try await make(p, ["PRAGMA key = \"\(key)\""])
        let db = try await ConnectionFactory.open(config(p), password: key)
        #expect(try await db.execute("SELECT count(*) FROM secrets").rows.first?.first == .integer(1))
        await db.close()
    }

    /// A SQLCipher 3 file opens in compatibility mode and stays a version 3 file.
    @Test func olderFormatOpensWithoutMigrating() async throws {
        let p = path()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try await make(p, ["PRAGMA key = 'old'", "PRAGMA cipher_compatibility = 3"])
        let before = try Data(contentsOf: URL(filePath: p))
        let db = try await ConnectionFactory.open(config(p), password: "old")
        #expect(await (db as? SQLiteConnection)?.cipherCompatibility == 3)
        #expect(try await db.execute("SELECT note FROM secrets").rows.first?.first == .text("hidden"))
        await db.close()
        #expect(try Data(contentsOf: URL(filePath: p)) == before)
    }

    @Test func plainDatabasesIgnoreNoPassphrase() async throws {
        let p = path()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try await make(p, [])
        let db = try await ConnectionFactory.open(config(p), password: nil)
        #expect(try await db.execute("SELECT count(*) FROM secrets").rows.first?.first == .integer(1))
        await db.close()
    }
}
