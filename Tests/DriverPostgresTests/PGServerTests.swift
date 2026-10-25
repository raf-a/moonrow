import DBKit
import Foundation
import Testing
import WireSupport
@testable import DriverPostgres

/// Against a real server: `scripts/test-servers.sh up`, then `MOONROW_TEST_PG` from its `env`.
enum TestServer {
    static let url = ProcessInfo.processInfo.environment["MOONROW_TEST_PG"]
    static var isAvailable: Bool { url != nil }

    static func configuration(
        user: String? = nil, password: String? = nil, tls: TLSMode = .disable, readOnly: Bool = false
    ) -> PostgresConfiguration {
        let u = URLComponents(string: url!)!
        return PostgresConfiguration(
            endpoint: .tcp(host: u.host!, port: u.port ?? 5432),
            user: user ?? u.user!, password: password ?? u.password,
            database: String(u.path.dropFirst()), tls: TLSSettings(mode: tls), readOnly: readOnly)
    }

    static func connect(tls: TLSMode = .disable) async throws -> PostgresConnection {
        try await PostgresConnection.connect(configuration(tls: tls))
    }
}

/// A schema of its own per test, dropped afterwards.
struct Scratch {
    let db: PostgresConnection
    let schema = "t_" + UUID().uuidString.prefix(8).lowercased()

    init() async throws {
        db = try await TestServer.connect()
        _ = try await db.execute("CREATE SCHEMA \(schema)")
        _ = try await db.execute("SET search_path TO \(schema)")
    }

    func drop() async {
        _ = try? await db.execute("DROP SCHEMA \(schema) CASCADE")
        await db.close()
    }
}

@Suite(.enabled(if: TestServer.isAvailable), .serialized)
struct PGServerTests {
    @Test func scramAndMD5Logins() async throws {
        let admin = try await TestServer.connect()
        defer { Task { await admin.close() } }
        let suffix = UUID().uuidString.prefix(6).lowercased()
        _ = try await admin.execute("SET password_encryption = 'scram-sha-256'")
        _ = try await admin.execute("CREATE ROLE scram_\(suffix) LOGIN PASSWORD 'p''w1'")
        _ = try await admin.execute("SET password_encryption = 'md5'")
        _ = try await admin.execute("CREATE ROLE md5_\(suffix) LOGIN PASSWORD 'pw2'")
        defer {
            Task {
                _ = try? await admin.execute("DROP ROLE scram_\(suffix)")
                _ = try? await admin.execute("DROP ROLE md5_\(suffix)")
            }
        }
        for (user, password) in [("scram_\(suffix)", "p'w1"), ("md5_\(suffix)", "pw2")] {
            let c = try await PostgresConnection.connect(TestServer.configuration(user: user, password: password))
            #expect(try await c.execute("SELECT current_user").rows == [[.text(user)]])
            await c.close()
        }
        await #expect {
            try await PostgresConnection.connect(TestServer.configuration(user: "scram_\(suffix)", password: "nope"))
        } throws: { ($0 as? DatabaseError)?.state == "28P01" }
    }

    @Test func tlsModes() async throws {
        func usesTLS(_ mode: TLSMode) async throws -> Bool {
            let c = try await TestServer.connect(tls: mode)
            defer { Task { await c.close() } }
            let r = try await c.execute("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
            return r.rows == [[.bool(true)]]
        }
        #expect(try await usesTLS(.disable) == false)
        #expect(try await usesTLS(.prefer))
        #expect(try await usesTLS(.require))
        // The test server's certificate is self-signed.
        await #expect {
            try await TestServer.connect(tls: .verifyCA)
        } throws: { "\($0)".contains("TLS") }
    }

    @Test func valuesComeBackTyped() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        let r = try await db.execute("""
            SELECT 1::int2 AS a, 2::int4, 3::int8, 1.5::float8, 'NaN'::float4, true, 'x'::text,
                   '\\x01ff'::bytea, NULL::text, 12.50::numeric, '2024-01-02'::date, '{1,2}'::int[], 'é'::varchar(3)
            """)
        #expect(r.columns.map(\.typeName) == ["int2", "int4", "int8", "float8", "float4", "bool", "text", "bytea",
                                              "text", "numeric", "date", "_int4", "varchar"])
        #expect(r.columns[0].name == "a")
        let row = try #require(r.rows.first)
        #expect(Array(row[0...3]) == [.integer(1), .integer(2), .integer(3), .double(1.5)])
        if case .double(let d) = row[4] { #expect(d.isNaN) } else { Issue.record("NaN came back as \(row[4])") }
        #expect(Array(row[5...]) == [.bool(true), .text("x"), .blob(Data([1, 255])), .null, .text("12.50"),
                                     .text("2024-01-02"), .text("{1,2}"), .text("é")])
    }

    @Test func bindingsTakeTheTypeOfTheirPlace() async throws {
        let s = try await Scratch()
        defer { Task { await s.drop() } }
        _ = try await s.db.execute("CREATE TABLE v (i int, f float8, b bool, x bytea, t text, n numeric, d date)")
        let values: [DBValue] = [.integer(7), .double(0.25), .bool(true), .blob(Data([0, 1, 254])),
                                 .text("it's \\ ok"), .text("1.10"), .text("2024-02-29")]
        _ = try await s.db.execute(SQLStatement("INSERT INTO v VALUES ($1, $2, $3, $4, $5, $6, $7)", bindings: values))
        _ = try await s.db.execute(SQLStatement("INSERT INTO v VALUES ($1, $2, $3, $4, $5, $6, $7)",
                                                bindings: Array(repeating: .null, count: 7)))
        let r = try await s.db.execute("SELECT * FROM v")
        #expect(r.rows == [values, Array(repeating: .null, count: 7)])
        // A text value compared with an integer column is parsed as an integer.
        #expect(try await s.db.execute("SELECT count(*) FROM v WHERE i = $1", .text("7")).rows == [[.integer(1)]])
    }

    @Test func emptyResultsKeepTheirColumnsAndCountsAreReported() async throws {
        let s = try await Scratch()
        defer { Task { await s.drop() } }
        let created = try await s.db.execute("CREATE TABLE e (id int PRIMARY KEY, name text)")
        #expect(created.rowsAffected == 0 && created.columns.isEmpty)
        let empty = try await s.db.execute("SELECT * FROM e")
        #expect(empty.columns.map(\.name) == ["id", "name"] && empty.rows.isEmpty && empty.rowsAffected == nil)
        #expect(try await s.db.execute("INSERT INTO e VALUES (1, 'a'), (2, 'b')").rowsAffected == 2)
        #expect(try await s.db.execute("UPDATE e SET name = name").rowsAffected == 2)
        let returning = try await s.db.execute("DELETE FROM e WHERE id = 1 RETURNING name")
        #expect(returning.rows == [[.text("a")]] && returning.rowsAffected == nil)
        #expect(try await s.db.execute("").rowsAffected == 0)
    }

    @Test func errorsLeaveTheSessionUsable() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        await #expect { try await db.execute("SELEC 1") } throws: { ($0 as? DatabaseError)?.state == "42601" }
        await #expect { try await db.execute("SELECT 1/0") } throws: { ($0 as? DatabaseError)?.state == "22012" }
        #expect(try await db.execute("SELECT 2").rows == [[.integer(2)]])
        // The server says where the error is, and adds a hint.
        await #expect { try await db.execute("SELECT 'é', nope_column") } throws: { error in
            let e = error as? DatabaseError
            return e?.position == 12 && e?.state == "42703" && e?.sql == "SELECT 'é', nope_column"
        }
        await #expect { try await db.execute("SELECT length(1, 2, 3)") } throws: { error in
            let e = error as? DatabaseError
            return e?.position == 7 && e?.hint != nil && e?.message.contains("\nHINT: ") == true
        }
    }

    @Test func streamsLargeResultsInBatches() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        var batches = 0
        var rows = 0
        for try await batch in db.stream(SQLStatement("SELECT g, md5(g::text) FROM generate_series(1, 200000) g"), batchSize: 5000) {
            batches += 1
            rows += batch.rows.count
        }
        #expect(rows == 200_000)
        #expect(batches >= 40)
    }

    @Test func stoppingEarlyCancelsTheStatement() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        let start = ContinuousClock.now
        for try await batch in db.stream(SQLStatement("SELECT generate_series(1, 100000000)"), batchSize: 1000) {
            #expect(!batch.rows.isEmpty)
            break
        }
        #expect(try await db.execute("SELECT 'next'").rows == [[.text("next")]])
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingASleepingStatement() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        let start = ContinuousClock.now
        let task = Task { try await db.execute("SELECT pg_sleep(10)") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(try await db.execute("SELECT 1").rows == [[.integer(1)]])
    }

    @Test func transactionRollsBackWhenVerifyThrows() async throws {
        let s = try await Scratch()
        defer { Task { await s.drop() } }
        _ = try await s.db.execute("CREATE TABLE k (id int PRIMARY KEY)")
        _ = try await s.db.execute("INSERT INTO k VALUES (1), (2)")
        let counts = try await s.db.transaction([SQLStatement("DELETE FROM k WHERE id = $1", bindings: [.integer(1)])])
        #expect(counts == [1])
        await #expect(throws: DatabaseError.self) {
            try await s.db.transaction([
                SQLStatement("INSERT INTO k VALUES (3)"),
                SQLStatement("DELETE FROM k WHERE id = 99"),
            ]) { _, n in if n != 1 { throw DatabaseError("no row") } }
        }
        await #expect(throws: DatabaseError.self) {
            try await s.db.transaction([SQLStatement("INSERT INTO k VALUES (4)"), SQLStatement("INSERT INTO k VALUES (2)")])
        }
        #expect(try await s.db.execute("SELECT id FROM k ORDER BY id").rows == [[.integer(2)]])
    }

    @Test func introspection() async throws {
        let s = try await Scratch()
        defer { Task { await s.drop() } }
        let ns = s.schema
        for sql in [
            "CREATE TABLE parent (a int, b text, PRIMARY KEY (b, a))",
            """
            CREATE TABLE child (id serial PRIMARY KEY, pa int NOT NULL, pb text, note text DEFAULT 'x',
              FOREIGN KEY (pb, pa) REFERENCES parent (b, a) ON DELETE CASCADE)
            """,
            "CREATE UNIQUE INDEX child_note ON child (lower(note), pa) WHERE note IS NOT NULL",
            "CREATE FUNCTION touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
            // EXECUTE PROCEDURE and the aggregate are for servers before 11 too, which have no prokind.
            "CREATE TRIGGER child_touch BEFORE INSERT OR UPDATE ON child FOR EACH ROW EXECUTE PROCEDURE touch()",
            "CREATE AGGREGATE total(int) (SFUNC = int4pl, STYPE = int)",
            "CREATE VIEW child_view AS SELECT id FROM child",
            "CREATE MATERIALIZED VIEW child_mv AS SELECT id FROM child",
        ] { _ = try await s.db.execute(sql) }

        #expect(try await s.db.schemas().contains(ns))
        #expect(try await s.db.currentSchema() == ns)
        let objects = try await s.db.objects(schema: nil)
        #expect(objects.map(\.ref.name) == ["child", "child_mv", "child_view", "parent", "touch"])
        #expect(objects.map(\.kind) == [.table, .materializedView, .view, .table, .function])
        #expect(objects.allSatisfy { $0.ref.schema == ns })

        let columns = try await s.db.columns(of: TableRef(schema: ns, "parent"))
        #expect(columns.map(\.name) == ["a", "b"])
        #expect(columns.map(\.primaryKeyPosition) == [2, 1])
        let child = try await s.db.columns(of: TableRef(schema: ns, "child"))
        #expect(child.map(\.typeName) == ["integer", "integer", "text", "text"])
        #expect(child.map(\.isNullable) == [false, false, true, true])
        #expect(child[0].defaultExpression?.hasPrefix("nextval(") == true)
        #expect(child[3].defaultExpression == "'x'::text")

        let indexes = try await s.db.indexes(of: TableRef(schema: ns, "child"))
        #expect(indexes.map(\.name) == ["child_note", "child_pkey"])
        #expect(indexes[0].columns == ["lower(note)", "pa"] && indexes[0].isUnique && !indexes[0].isPrimary)
        #expect(indexes[0].predicate == "note IS NOT NULL" && indexes[0].method == "btree")
        #expect(indexes[1].isPrimary && indexes[1].columns == ["id"])

        let fks = try await s.db.foreignKeys(of: TableRef(schema: ns, "child"))
        #expect(fks.count == 1)
        #expect(fks.first?.columns == ["pb", "pa"] && fks.first?.referencedColumns == ["b", "a"])
        #expect(fks.first?.referencedTable == TableRef(schema: ns, "parent"))
        #expect(fks.first?.onDelete == "CASCADE" && fks.first?.onUpdate == "NO ACTION")

        let triggers = try await s.db.triggers(of: TableRef(schema: ns, "child"))
        #expect(triggers.map(\.name) == ["child_touch"])
        #expect(triggers.first?.timing == "BEFORE" && triggers.first?.events == ["INSERT", "UPDATE"])
        #expect(triggers.first?.definition.contains(s.db.versionNumber >= 110_000 ? "EXECUTE FUNCTION" : "EXECUTE PROCEDURE") == true)

        await #expect(throws: DatabaseError.self) { try await s.db.columns(of: TableRef(schema: ns, "missing")) }
    }

    @Test func reconnectsAfterTheServerDropsTheSession() async throws {
        let db = try await TestServer.connect()
        let admin = try await TestServer.connect()
        defer { Task { await db.close(); await admin.close() } }
        let pid = try await db.backendProcessID()
        _ = try await admin.execute("SELECT pg_terminate_backend($1)", .integer(Int64(pid)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await db.execute("SELECT 1").rows == [[.integer(1)]])
        #expect(try await db.backendProcessID() != pid)
    }

    @Test func readOnlySessionsRefuseWrites() async throws {
        let s = try await Scratch()
        defer { Task { await s.drop() } }
        _ = try await s.db.execute("CREATE TABLE w (i int)")
        let ro = try await PostgresConnection.connect(TestServer.configuration(readOnly: true))
        defer { Task { await ro.close() } }
        await #expect {
            try await ro.execute("INSERT INTO \(s.schema).w VALUES (1)")
        } throws: { ($0 as? DatabaseError)?.state == "25006" }
    }

    @Test func copyOutComesBackAsRows() async throws {
        let db = try await TestServer.connect()
        defer { Task { await db.close() } }
        let r = try await db.execute("COPY (SELECT g, 'x' FROM generate_series(1, 3) g) TO STDOUT")
        #expect(r.rows == [[.text("1\tx")], [.text("2\tx")], [.text("3\tx")]])
        await #expect(throws: DatabaseError.self) { try await db.execute("COPY pg_catalog.pg_am FROM STDIN") }
        #expect(try await db.execute("SELECT 1").rows == [[.integer(1)]])
    }
}
