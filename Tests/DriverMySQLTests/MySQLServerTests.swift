import DBKit
import Foundation
import Testing
import WireSupport
@testable import DriverMySQL

/// A server from `scripts/test-servers.sh env`, e.g. `mysql://root:tabula@127.0.0.1:53306/tabula`.
struct TestServer: Sendable, CustomTestStringConvertible {
    let name: String
    let url: URL

    static let all: [TestServer] = [("MySQL", "TABULA_TEST_MYSQL"), ("MariaDB", "TABULA_TEST_MARIADB")]
        .compactMap { name, variable in
            ProcessInfo.processInfo.environment[variable].flatMap(URL.init(string:)).map { TestServer(name: name, url: $0) }
        }

    var testDescription: String { name }
    var isMariaDB: Bool { name == "MariaDB" }

    func configuration(
        user: String? = nil, password: String? = nil, database: String? = nil, tls: TLSMode = .disable
    ) -> MySQLConfiguration {
        MySQLConfiguration(
            endpoint: .tcp(host: url.host ?? "127.0.0.1", port: url.port ?? 3306),
            user: user ?? url.user ?? "root", password: password ?? url.password ?? "",
            database: database, tls: TLSSettings(mode: tls), connectTimeout: 5)
    }

    func connect(user: String? = nil, password: String? = nil, database: String? = nil, tls: TLSMode = .disable)
        async throws -> MySQLConnection {
        try await MySQLConnection.connect(configuration(user: user, password: password, database: database, tls: tls))
    }

    /// A fresh database for one test, and a connection that uses it.
    func scratch() async throws -> (MySQLConnection, String) {
        let name = "t_" + UUID().uuidString.prefix(8).lowercased()
        let admin = try await connect()
        _ = try await admin.execute("CREATE DATABASE \(name)")
        await admin.close()
        return (try await connect(database: name), name)
    }

    func drop(_ database: String, _ connection: MySQLConnection) async {
        _ = try? await connection.execute("DROP DATABASE \(database)")
        await connection.close()
    }
}

@Suite(.enabled(if: !TestServer.all.isEmpty, "set TABULA_TEST_MYSQL / TABULA_TEST_MARIADB (scripts/test-servers.sh)"))
struct MySQLServerTests {
    private func currentUser(_ c: MySQLConnection) async throws -> String? {
        try await c.execute("SELECT CURRENT_USER()").rows.first?.first.map(\.displayString)
    }

    @Test(arguments: TestServer.all) func authenticationPlugins(server: TestServer) async throws {
        let admin = try await server.connect()
        let tag = UUID().uuidString.prefix(6).lowercased()
        let native = "native_\(tag)", sha2 = "sha2_\(tag)", empty = "empty_\(tag)"
        let nativeClause = server.isMariaDB ? "IDENTIFIED BY 'pw-native'" : "IDENTIFIED WITH mysql_native_password BY 'pw-native'"
        _ = try await admin.execute("CREATE USER '\(native)'@'%' \(nativeClause)")
        _ = try await admin.execute("CREATE USER '\(empty)'@'%' IDENTIFIED BY ''")
        defer { Task { _ = try? await admin.execute("DROP USER '\(native)'@'%', '\(empty)'@'%'"); await admin.close() } }

        let n = try await server.connect(user: native, password: "pw-native")
        #expect(try await currentUser(n) == "\(native)@%")
        await n.close()
        let e = try await server.connect(user: empty, password: "")
        #expect(try await currentUser(e) == "\(empty)@%")
        await e.close()

        let denied = await #expect(throws: DatabaseError.self) { try await server.connect(user: native, password: "wrong") }
        #expect(denied?.code == 1045)
        #expect(denied?.message.contains("Access denied") == true)

        guard !server.isMariaDB else { return }
        _ = try await admin.execute("CREATE USER '\(sha2)'@'%' IDENTIFIED WITH caching_sha2_password BY 'pw-sha2'")
        defer { Task { _ = try? await admin.execute("DROP USER '\(sha2)'@'%'") } }
        // Not cached yet: full authentication, the password RSA-encrypted over plain TCP.
        let rsa = try await server.connect(user: sha2, password: "pw-sha2", tls: .disable)
        #expect(try await currentUser(rsa) == "\(sha2)@%")
        await rsa.close()
        // Cached now: the scramble alone.
        let fast = try await server.connect(user: sha2, password: "pw-sha2", tls: .disable)
        #expect(try await currentUser(fast) == "\(sha2)@%")
        await fast.close()
        // FLUSH PRIVILEGES empties the cache: full authentication again, this time over TLS.
        _ = try await admin.execute("FLUSH PRIVILEGES")
        let tls = try await server.connect(user: sha2, password: "pw-sha2", tls: .require)
        #expect(try await tls.isTLS)
        #expect(try await currentUser(tls) == "\(sha2)@%")
        await tls.close()
        await #expect(throws: DatabaseError.self) { try await server.connect(user: sha2, password: "nope") }
    }

    @Test(arguments: TestServer.all) func tlsModes(server: TestServer) async throws {
        for mode in [TLSMode.prefer, .require] {
            let c = try await server.connect(tls: mode)
            #expect(try await c.isTLS, "\(mode)")
            #expect(try await c.execute("SELECT 1").rows == [[.integer(1)]])
            await c.close()
        }
        let plain = try await server.connect(tls: .disable)
        #expect(try await !plain.isTLS)
        await plain.close()
        // The containers use self-signed certificates.
        for mode in [TLSMode.verifyCA, .verifyFull] {
            let error = await #expect(throws: DatabaseError.self) { try await server.connect(tls: mode) }
            #expect(error?.message.contains("TLS") == true, "\(error?.message ?? "")")
        }
    }

    @Test(arguments: TestServer.all) func textAndBinaryRowsDecodeAlike(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        _ = try await c.execute("""
            CREATE TABLE v (id INT PRIMARY KEY, ti TINYINT, si SMALLINT UNSIGNED, mi MEDIUMINT, bi BIGINT,
              bu BIGINT UNSIGNED, f FLOAT, d DOUBLE, de DECIMAL(10,2), vc VARCHAR(20), ch CHAR(3), tx TEXT,
              bl BLOB, vb VARBINARY(8), bt BIT(10), dt DATE, dtm DATETIME(3), ts TIMESTAMP(6) NULL, tm TIME,
              yr YEAR, js JSON, en ENUM('a','b'), st SET('x','y'), nul INT NULL)
            """)
        _ = try await c.execute(#"""
            INSERT INTO v VALUES (1, -128, 65535, -8388608, -9223372036854775808, 18446744073709551615, 0.1, 1.5e300,
              12.34, 'it''s', 'abc', 'two\\lines', X'00FF10', X'0102', b'1000000001', '2024-02-29',
              '2024-02-29 13:05:09.123', '2024-01-01 00:00:00.000001', '-838:59:59', 2024, '{"a": [1, 2]}', 'b',
              'x,y', NULL)
            """#)
        let text = try await c.execute("SELECT * FROM v")
        let binary = try await c.execute("SELECT * FROM v WHERE id = ?", .integer(1))
        #expect(text.columns == binary.columns)
        #expect(text.rows == binary.rows)
        let row = try #require(binary.rows.first)
        let named = Dictionary(uniqueKeysWithValues: zip(binary.columns.map(\.name), row))
        #expect(named["ti"] == .integer(-128))
        #expect(named["si"] == .integer(65535))
        #expect(named["mi"] == .integer(-8_388_608))
        #expect(named["bi"] == .integer(.min))
        #expect(named["bu"] == .text("18446744073709551615"))
        #expect(named["f"] == .double(0.1))
        #expect(named["d"] == .double(1.5e300))
        #expect(named["de"] == .text("12.34"))
        #expect(named["vc"] == .text("it's"))
        #expect(named["ch"] == .text("abc"))
        #expect(named["tx"] == .text("two\\lines"))
        #expect(named["bl"] == .blob(Data([0, 0xFF, 0x10])))
        #expect(named["vb"] == .blob(Data([1, 2])))
        #expect(named["bt"] == .integer(513))
        #expect(named["dt"] == .text("2024-02-29"))
        #expect(named["dtm"] == .text("2024-02-29 13:05:09.123"))
        #expect(named["ts"] == .text("2024-01-01 00:00:00.000001"))
        #expect(named["tm"] == .text("-838:59:59"))
        #expect(named["yr"] == .integer(2024))
        #expect(named["en"] == .text("b"))
        #expect(named["st"] == .text("x,y"))
        #expect(named["nul"] == .null)
        #expect(binary.columns.first { $0.name == "bu" }?.typeName == "BIGINT UNSIGNED")

        // Values sent as parameters come back as sent.
        let sent: [DBValue] = [.integer(2), .integer(-5), .double(0.25), .text("ünï'\\"), .blob(Data([0, 39, 92, 255])), .null, .bool(true)]
        _ = try await c.execute(SQLStatement("INSERT INTO v (id, bi, d, vc, bl, nul, ti) VALUES (?, ?, ?, ?, ?, ?, ?)", bindings: sent))
        let back = try await c.execute("SELECT id, bi, d, vc, bl, nul, ti FROM v WHERE id = 2").rows
        #expect(back == [[.integer(2), .integer(-5), .double(0.25), .text("ünï'\\"), .blob(Data([0, 39, 92, 255])), .null, .integer(1)]])
    }

    @Test(arguments: TestServer.all) func emptyResultsStillHaveColumns(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        _ = try await c.execute("CREATE TABLE e (id INT, name VARCHAR(5))")
        for result in [try await c.execute("SELECT id, name FROM e"), try await c.execute("SELECT id, name FROM e WHERE id = ?", .integer(1))] {
            #expect(result.columns.map(\.name) == ["id", "name"])
            #expect(result.rows.isEmpty)
            #expect(result.rowsAffected == nil)
        }
    }

    @Test(arguments: TestServer.all) func rowsAffected(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        #expect(try await c.execute("CREATE TABLE r (id INT PRIMARY KEY, x INT)").rowsAffected == 0)
        #expect(try await c.execute("INSERT INTO r VALUES (1, 1), (2, 2), (3, 3)").rowsAffected == 3)
        // FOUND_ROWS: a row matched but left unchanged still counts.
        #expect(try await c.execute("UPDATE r SET x = 1 WHERE id = 1").rowsAffected == 1)
        #expect(try await c.execute("UPDATE r SET x = ? WHERE id = ?", .integer(2), .integer(2)).rowsAffected == 1)
        #expect(try await c.execute("DELETE FROM r WHERE id > ?", .integer(1)).rowsAffected == 2)
        #expect(try await c.execute("SELECT * FROM r").rowsAffected == nil)
        await #expect(throws: DatabaseError.self) { try await c.execute("SELECT ?", .integer(1), .integer(2)) }
        let error = await #expect(throws: DatabaseError.self) { try await c.execute("SELEKT 1") }
        #expect(error?.code == 1064)
        #expect(error?.state == "42000")
        #expect(error?.sql == "SELEKT 1")
        #expect(try await c.execute("SELECT 7").rows == [[.integer(7)]])
    }

    private func longSeries(_ server: TestServer, _ c: MySQLConnection, rows: Int) async throws -> SQLStatement {
        _ = try await c.execute(server.isMariaDB ? "SET SESSION max_recursive_iterations = 10000000"
                                                 : "SET SESSION cte_max_recursion_depth = 10000000")
        return SQLStatement("""
            WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < \(rows))
            SELECT n, CONCAT('row ', n) AS label FROM s
            """)
    }

    @Test(arguments: TestServer.all) func streamsLargeResultsInBatches(server: TestServer) async throws {
        let c = try await server.connect()
        defer { Task { await c.close() } }
        var batches = 0, total = 0
        var last: DBValue?
        for try await batch in c.stream(try await longSeries(server, c, rows: 200_000), batchSize: 5000) {
            batches += 1
            total += batch.rows.count
            #expect(batch.rows.count <= 5000)
            last = batch.rows.last?.first ?? last
        }
        #expect(total == 200_000)
        #expect(batches >= 40)
        #expect(last == .integer(200_000))
    }

    @Test(arguments: TestServer.all) func cancellingStopsTheServerQuickly(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        // A cross join streams as it goes (a recursive CTE is materialized before the first row).
        _ = try await c.execute("CREATE TABLE t (n INT, label VARCHAR(20))")
        _ = try await c.execute(SQLStatement("INSERT INTO t " + (try await longSeries(server, c, rows: 3000)).sql))
        var seen = 0
        for try await batch in c.stream(SQLStatement("SELECT a.n, b.n FROM t a CROSS JOIN t b"), batchSize: 1000) {
            seen += batch.rows.count
            break
        }
        #expect(seen == 1000)
        let clock = ContinuousClock()
        var start = clock.now
        #expect(try await c.execute("SELECT 42").rows == [[.integer(42)]])
        #expect(clock.now - start < .seconds(3))

        let sleeping = Task { try await c.execute("SELECT SLEEP(10)") }
        try await Task.sleep(for: .milliseconds(200))
        start = clock.now
        sleeping.cancel()
        _ = try? await sleeping.value
        #expect(try await c.execute("SELECT 'next'").rows == [[.text("next")]])
        #expect(clock.now - start < .seconds(3))
    }

    @Test(arguments: TestServer.all) func transactionsRollBackWhenVerifyFails(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        _ = try await c.execute("CREATE TABLE tr (id INT PRIMARY KEY, x INT) ENGINE=InnoDB")
        _ = try await c.execute("INSERT INTO tr VALUES (1, 1), (2, 2)")
        await #expect(throws: DatabaseError.self) {
            try await c.transaction([
                SQLStatement("UPDATE tr SET x = 10 WHERE id = 1"),
                SQLStatement("UPDATE tr SET x = ? WHERE id = ?", bindings: [.integer(20), .integer(99)]),
            ]) { _, n in if n != 1 { throw DatabaseError("matched \(n) rows") } }
        }
        #expect(try await c.execute("SELECT x FROM tr ORDER BY id").rows == [[.integer(1)], [.integer(2)]])
        let counts = try await c.transaction([
            SQLStatement("UPDATE tr SET x = 10 WHERE id = 1"),
            SQLStatement("DELETE FROM tr WHERE id = ?", bindings: [.integer(2)]),
        ])
        #expect(counts == [1, 1])
        #expect(try await c.execute("SELECT id, x FROM tr").rows == [[.integer(1), .integer(10)]])
    }

    @Test(arguments: TestServer.all) func introspection(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        for sql in [
            "CREATE TABLE parent (a INT, b VARCHAR(10), name VARCHAR(20) NOT NULL DEFAULT 'none', PRIMARY KEY (b, a))",
            """
            CREATE TABLE child (id INT AUTO_INCREMENT PRIMARY KEY, pa INT, pb VARCHAR(10), qty INT DEFAULT 0,
              KEY idx_qty (qty, id), UNIQUE KEY uq (pb),
              CONSTRAINT fk_parent FOREIGN KEY (pb, pa) REFERENCES parent (b, a) ON DELETE CASCADE)
            """,
            "CREATE VIEW v_child AS SELECT id FROM child",
            "CREATE TRIGGER trg_child BEFORE INSERT ON child FOR EACH ROW SET NEW.qty = NEW.qty + 1",
            "CREATE PROCEDURE proc_x() SELECT 1 AS one",
        ] { _ = try await c.execute(SQLStatement(sql)) }

        #expect(try await c.schemas().contains(db))
        #expect(try await !c.schemas().contains("mysql"))
        #expect(try await c.currentSchema() == db)

        let objects = try await c.objects(schema: nil)
        #expect(objects.map(\.ref.name) == ["child", "parent", "proc_x", "v_child"])
        #expect(objects.map(\.kind) == [.table, .table, .procedure, .view])
        #expect(try await c.objects(schema: db).map(\.ref) == objects.map { TableRef(schema: db, $0.ref.name) })

        let parent = try await c.columns(of: TableRef("parent"))
        #expect(parent.map(\.name) == ["a", "b", "name"])
        #expect(parent.map(\.primaryKeyPosition) == [2, 1, nil])
        #expect(parent.primaryKey == ["b", "a"])
        #expect(parent[2].typeName == "varchar(20)")
        #expect(!parent[2].isNullable && parent[0].isNullable == false && parent[1].isNullable == false)
        #expect(parent[2].defaultExpression?.contains("none") == true)
        #expect(try await c.columns(of: TableRef(schema: db, "child")).map(\.name) == ["id", "pa", "pb", "qty"])
        await #expect(throws: DatabaseError.self) { try await c.columns(of: TableRef("nope")) }

        let indexes = try await c.indexes(of: TableRef("child"))
        #expect(indexes.first == IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true, method: "BTREE"))
        #expect(indexes.contains(IndexInfo(name: "idx_qty", columns: ["qty", "id"], method: "BTREE")))
        #expect(indexes.contains(IndexInfo(name: "uq", columns: ["pb"], isUnique: true, method: "BTREE")))

        let fks = try await c.foreignKeys(of: TableRef("child"))
        #expect(fks.count == 1)
        #expect(fks.first?.name == "fk_parent")
        #expect(fks.first?.columns == ["pb", "pa"])
        #expect(fks.first?.referencedTable == TableRef(schema: db, "parent"))
        #expect(fks.first?.referencedColumns == ["b", "a"])
        #expect(fks.first?.onDelete == "CASCADE")

        let triggers = try await c.triggers(of: TableRef("child"))
        #expect(triggers.map(\.name) == ["trg_child"])
        #expect(triggers.first?.timing == "BEFORE")
        #expect(triggers.first?.events == ["INSERT"])
        #expect(triggers.first?.definition.contains("NEW.qty") == true)

        // A CALL's extra result (the final OK) is drained; the session stays usable.
        #expect(try await c.execute("CALL proc_x()").rows == [[.integer(1)]])
        #expect(try await c.execute("SELECT 2").rows == [[.integer(2)]])
    }

    @Test(arguments: TestServer.all) func reconnectsAfterTheServerDropsTheSession(server: TestServer) async throws {
        let c = try await server.connect()
        defer { Task { await c.close() } }
        let id = try await c.connectionID
        let other = try await server.connect()
        _ = try await other.execute("KILL \(id)")
        await other.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await c.execute("SELECT 1").rows == [[.integer(1)]])
        #expect(try await c.connectionID != id)
    }

    @Test(arguments: TestServer.all) func readOnlySessionsRefuseWrites(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        _ = try await c.execute("CREATE TABLE ro (x INT)")
        var configuration = server.configuration(database: db)
        configuration.readOnly = true
        let ro = try await MySQLConnection.connect(configuration)
        defer { Task { await ro.close() } }
        #expect(try await ro.execute("SELECT COUNT(*) FROM ro").rows == [[.integer(0)]])
        let error = await #expect(throws: DatabaseError.self) { try await ro.execute("INSERT INTO ro VALUES (1)") }
        #expect(error?.code == 1792)
    }

    /// Records how the server writes bound parameters into its general log, for the M2 check that
    /// the commit preview matches what the server ran.
    @Test(arguments: TestServer.all) func generalLogShowsParametersInline(server: TestServer) async throws {
        let (c, db) = try await server.scratch()
        defer { Task { await server.drop(db, c) } }
        _ = try await c.execute("CREATE TABLE g (a VARCHAR(50), d DOUBLE, b TINYINT, bl BLOB, n INT, i BIGINT)")
        let values: [DBValue] = [.text("it's a \\ back"), .double(0.75), .bool(true), .blob(Data([0x00, 0x41, 0x27, 0xFF])), .null, .integer(-3)]
        _ = try await c.execute(SQLStatement("INSERT INTO g VALUES (?, ?, ?, ?, ?, ?)", bindings: values))
        let logged = try await c.execute("""
            SELECT argument FROM mysql.general_log
            WHERE command_type = 'Execute' AND argument LIKE 'INSERT INTO g VALUES%'
            ORDER BY event_time DESC LIMIT 1
            """).rows.first?.first
        let text: String
        switch logged {
        case .blob(let d)?: text = d.map { (0x20..<0x7F).contains($0) ? String(UnicodeScalar($0)) : String(format: "\\x%02X", $0) }.joined()
        case .text(let s)?: text = s
        default: text = "<nothing logged>"
        }
        let preview = "INSERT INTO g VALUES (" + values.map(MySQLDialect().literal).joined(separator: ", ") + ")"
        print("[\(server.name)] logged : \(text)")
        if case .blob(let d)? = logged { print("[\(server.name)] hex: \(d.map { String(format: "%02X", $0) }.joined(separator: " "))") }
        print("[\(server.name)] preview: \(preview)")
        #expect(text.hasPrefix("INSERT INTO g VALUES ("))
    }
}
