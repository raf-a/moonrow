import DBKit
import Foundation
import Testing
@testable import AppCore

/// One server of the backup matrix: `MOONROW_MATRIX` lists them as `name=url`, separated by
/// spaces (scripts/test-matrix.sh env).
struct MatrixServer: Sendable, CustomTestStringConvertible {
    let name: String
    let url: String

    var testDescription: String { name }

    static let all: [MatrixServer] = (ProcessInfo.processInfo.environment["MOONROW_MATRIX"] ?? "")
        .split(separator: " ").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? MatrixServer(name: parts[0], url: parts[1]) : nil
        }
}

/// Every bundled kit against its own server version: a database with a bit of everything is
/// backed up in each format the app offers, restored into a new database on the same server with
/// the kit the app picks, and compared, schema and data. Then restores that fail part way, to
/// check they stop or go on as the options say. Skips without `MOONROW_MATRIX`; see
/// scripts/test-matrix.sh.
@Suite struct BackupMatrixTests {
    static let tools = BundledTools.forTests

    @Test(arguments: MatrixServer.all) func backupAndRestore(_ server: MatrixServer) async throws {
        let run = try await MatrixRun(server)
        defer { run.cleanUp() }
        do {
            try await run.check()
        } catch {
            await run.dropDatabases()
            throw error
        }
        await run.dropDatabases()
    }
}

/// One server's run.
final class MatrixRun: @unchecked Sendable {
    let server: MatrixServer
    let config: ConnectionConfig
    let password: String?
    let admin: any DatabaseConnection
    let version: [Int]
    let mariaDB: Bool
    let family: DumpTool.Family
    let folder: URL
    let source: String
    private var created: [String] = []

    init(_ server: MatrixServer) async throws {
        self.server = server
        let (config, password) = try #require(ConnectionConfig.parse(url: server.url), "\(server.url)")
        self.config = config
        self.password = password
        admin = try await ConnectionFactory.open(config, password: password)
        let (version, maria) = ServerInfo.version(admin)
        self.version = try #require(version)
        mariaDB = maria
        family = config.driver == .postgres ? .postgres : .mysql
        folder = try temporaryFolder()
        source = "mx_" + UUID().uuidString.prefix(8).lowercased()
    }

    var isPostgres: Bool { family == .postgres }
    var dialect: any Dialect { admin.dialect }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    func dropDatabases() async {
        for name in created {
            _ = try? await admin.execute(SQLStatement("DROP DATABASE IF EXISTS \(dialect.quoteIdentifier(name))"))
        }
        await admin.close()
    }

    func createDatabase(_ name: String) async throws {
        created.append(name)
        let new = NewDatabase(name: name, encoding: isPostgres ? nil : "utf8mb4")
        _ = try await admin.execute(SQLStatement(DatabaseCatalog.createSQL(new, dialect: dialect)))
    }

    func open(_ database: String) async throws -> any DatabaseConnection {
        var c = config
        c.database = database
        return try await ConnectionFactory.open(c, password: password)
    }

    /// The tool the app runs for `role`: from the server's kit, or from `kit`.
    func tool(_ role: BundledTools.Role, kit: ToolKit? = nil) throws -> ToolInfo {
        let found = kit.map { Self.tools.tool(for: role, in: $0) } ?? Self.tools.choose(role, serverVersion: version, mariaDBServer: mariaDB).0
        return try #require(found, "\(server.name): no bundled tool for \(role)")
    }

    static var tools: BundledTools { BackupMatrixTests.tools }

    // MARK: - The run

    func check() async throws {
        let kit = try #require(Self.tools.defaultKit(for: family, serverVersion: version, mariaDBServer: mariaDB))
        let line = { (v: [Int]) in BundledTools.line(v, family: self.family, mariaDB: self.mariaDB) }
        print("[matrix] \(server.name): server \(version.map(String.init).joined(separator: ".")), kit \(kit.id) (\(kit.title))")
        // Each server gets the tools of its own release line (MariaDB: the one MariaDB kit).
        if !mariaDB {
            #expect(line(kit.version) == line(version), "\(server.name) gets \(kit.title)")
        }
        #expect(Self.tools.warning(kit, role: family == .postgres ? .backupPostgres : .backupMySQL, serverVersion: version,
                                   mariaDBServer: mariaDB) == nil)

        try await createDatabase(source)
        let db = try await open(source)
        do {
            try await (isPostgres ? postgresFixture(db) : mysqlFixture(db))
        } catch {
            await db.close()
            throw error
        }
        let expected = try await snapshot(db, database: source)
        await db.close()
        #expect(expected.data.count >= 4)

        for variant in variants() {
            await attempt(variant.name) { try await self.roundTrip(variant, expected: expected) }
        }
        await attempt("restore errors") { try await self.restoreErrors() }
    }

    /// Runs one part, recording a failure without stopping the others.
    func attempt(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            print("[matrix] \(server.name): \(name) ✓")
        } catch {
            print("[matrix] \(server.name): \(name) ✗ \(error)")
            Issue.record("\(server.name) – \(name): \(error)")
        }
    }

    struct Variant {
        var name: String
        /// Backups restored in turn into the same new database (structure, then data).
        var steps: [(BackupOptions, RestoreOptions)]
        /// What the restored database is expected to lack: schema lists and tables left out
        /// of the comparison.
        var skip: Set<String> = []
        /// Another kit than the server's, as picked from the version menu.
        var kit: ToolKit?
    }

    func variants() -> [Variant] {
        var schema = BackupOptions()
        schema.content = .schemaOnly
        var data = BackupOptions()
        data.content = .dataOnly
        if isPostgres {
            func format(_ f: BackupOptions.PostgresFormat, gzip: Bool = false) -> BackupOptions {
                var o = BackupOptions()
                o.postgresFormat = f
                o.gzip = gzip
                return o
            }
            var single = RestoreOptions()
            single.singleTransaction = true
            var cleanOwner = format(.custom)
            cleanOwner.noOwner = true
            cleanOwner.noPrivileges = true
            cleanOwner.clean = true
            schema.postgresFormat = .custom
            data.postgresFormat = .custom
            return [
                Variant(name: "custom", steps: [(format(.custom), RestoreOptions())]),
                Variant(name: "plain", steps: [(format(.plain), RestoreOptions())]),
                Variant(name: "plain gzip, one transaction", steps: [(format(.plain, gzip: true), single)]),
                Variant(name: "tar", steps: [(format(.tar), RestoreOptions())]),
                Variant(name: "directory, one transaction", steps: [(format(.directory), single)]),
                // Without privileges, the grants aren't restored.
                Variant(name: "custom, clean, no owner or privileges", steps: [(cleanOwner, RestoreOptions())], skip: ["privileges"]),
                // pg_dump refreshes materialized views in neither a structure-only nor a
                // data-only backup, so they come back empty.
                Variant(name: "structure then data", steps: [(schema, RestoreOptions()), (data, RestoreOptions())],
                        skip: ["matviews", "sales.big_summary"]),
            ]
        }
        var events = BackupOptions()
        events.events = true
        var gzip = BackupOptions()
        gzip.gzip = true
        gzip.events = true
        schema.events = true
        data.events = true
        var noTransaction = BackupOptions()
        noTransaction.singleTransaction = false
        noTransaction.events = true
        // MySQL's newer kits, which the version menu offers without a warning, on an older
        // server.
        let newer = mariaDB ? [] : Self.tools.kits(for: .mysql).filter {
            !$0.isMariaDB && BundledTools.line(version, family: .mysql, mariaDB: false)
                .lexicographicallyPrecedes(BundledTools.line($0.version, family: .mysql, mariaDB: false))
        }
        return newer.map { Variant(name: "sql with \($0.title)", steps: [(events, RestoreOptions())], kit: $0) } + [
            Variant(name: "sql", steps: [(events, RestoreOptions())]),
            Variant(name: "sql gzip", steps: [(gzip, RestoreOptions())]),
            Variant(name: "sql, no single transaction", steps: [(noTransaction, RestoreOptions())]),
            Variant(name: "structure then data", steps: [(schema, RestoreOptions()), (data, RestoreOptions())]),
        ]
    }

    func roundTrip(_ variant: Variant, expected: Snapshot) async throws {
        let target = source + "_" + UUID().uuidString.prefix(4).lowercased()
        try await createDatabase(target)
        for (i, (backup, restore)) in variant.steps.enumerated() {
            let job = BackupJob(config: config, password: password, database: source, options: backup,
                                tool: try tool(family == .postgres ? .backupPostgres : .backupMySQL, kit: variant.kit),
                                serverIsMariaDB: mariaDB)
            let file = folder.appending(path: job.fileName(FileNamePattern("{database}-\(target)-\(i)")))
            let backupLog = Lines()
            do {
                try await job.run(to: file, log: { backupLog.add($0) })
            } catch {
                throw MatrixFailure("backup: \(error)")
            }
            let kind = try BackupFileKind.detect(file)
            let role = try #require(RestoreJob.role(for: kind, driver: config.driver))
            let restoreLog = Lines()
            do {
                try await RestoreJob(config: config, password: password, database: target, file: file, kind: kind,
                                     options: restore, tool: try tool(role, kit: variant.kit)).run { restoreLog.add($0) }
            } catch {
                throw MatrixFailure("restore: \(error)")
            }
            // A restore that goes through may still have printed errors (psql without
            // ON_ERROR_STOP never fails); none are expected.
            let errors = restoreLog.all.filter(Self.isError)
            if !errors.isEmpty { throw MatrixFailure("restore printed errors: \(errors.prefix(5).joined(separator: " | "))") }
        }
        let db = try await open(target)
        var got = try await snapshot(db, database: target, skip: variant.skip)
        await db.close()
        var expected = expected
        for key in variant.skip {
            expected.schema[key] = nil
            expected.data[key] = nil
            got.schema[key] = nil
            got.data[key] = nil
        }
        try compare(expected, got)
    }

    /// An error a tool printed: `ERROR 1146 (42S02) at line 2: …` (mysql), `psql:file:2: ERROR:  …`,
    /// `pg_restore: error: …`.
    static func isError(_ line: String) -> Bool {
        line.hasPrefix("ERROR ") || line.contains(" ERROR:  ") || line.contains("pg_restore: error")
    }

    func compare(_ expected: Snapshot, _ got: Snapshot) throws {
        var problems: [String] = []
        for (key, rows) in expected.schema where got.schema[key] != rows {
            let g = got.schema[key] ?? []
            problems.append("schema \(key): missing \(rows.filter { !g.contains($0) }), unexpected \(g.filter { !rows.contains($0) })")
        }
        for (key, rows) in expected.data where got.data[key] != rows {
            let g = got.data[key] ?? []
            let first = zip(rows, g).first { $0 != $1 }.map { "\($0.0) ≠ \($0.1)" } ?? "\(rows.count) rows ≠ \(g.count)"
            problems.append("data \(key): \(first)")
        }
        if !problems.isEmpty { throw MatrixFailure(problems.joined(separator: "\n")) }
    }

    // MARK: - Restores that fail part way

    func restoreErrors() async throws {
        let script = folder.appending(path: "errors.sql")
        try Data("""
        CREATE TABLE before_error (id int);
        INSERT INTO no_such_table VALUES (1);
        CREATE TABLE after_error (id int);

        """.utf8).write(to: script)
        let role: BundledTools.Role = isPostgres ? .restorePostgresScript : .restoreMySQL

        // Stop at the first error: the run fails, and nothing after the error ran.
        var stop = RestoreOptions()
        stop.stopOnError = true
        var outcome = try await restore(script, kind: .sql, role: role, stop)
        guard let stopError = outcome.error else { throw MatrixFailure("stop on error: the restore didn't fail") }
        try expect(stopError.contains("no_such_table"), "stop on error: the error names the table: \(stopError)")
        try expect(outcome.tables.contains("before_error") && !outcome.tables.contains("after_error"),
                   "stop on error: tables \(outcome.tables)")

        // Go on: the rest runs, and the error is reported, by the run failing or in the log.
        var goOn = RestoreOptions()
        goOn.stopOnError = false
        outcome = try await restore(script, kind: .sql, role: role, goOn)
        try expect(outcome.tables.contains("before_error") && outcome.tables.contains("after_error"), "go on: tables \(outcome.tables)")
        try expect(outcome.log.contains { Self.isError($0) && $0.contains("no_such_table") },
                   "go on: the error is reported (\(outcome.error ?? "the run succeeded"))")
        print("[matrix] \(server.name): \(role) going on after an error " + (outcome.error.map { "fails at the end: \($0)" } ?? "succeeds"))

        guard isPostgres else { return }
        // One transaction: all or nothing.
        var single = RestoreOptions()
        single.singleTransaction = true
        outcome = try await restore(script, kind: .sql, role: role, single)
        try expect(outcome.error != nil && outcome.tables.isEmpty, "one transaction: \(outcome.tables), \(outcome.error ?? "no error")")

        // pg_restore: an archive whose `audit` table is already there.
        var custom = BackupOptions()
        custom.postgresFormat = .custom
        let job = BackupJob(config: config, password: password, database: source, options: custom, tool: try tool(.backupPostgres),
                            serverIsMariaDB: false)
        let archive = folder.appending(path: "conflict.dump")
        try await job.run(to: archive, log: { _ in })
        let existing = "CREATE TABLE audit (x int)"
        outcome = try await restore(archive, kind: .postgresArchive, role: .restorePostgresArchive, stop, prepare: existing)
        try expect(outcome.error?.contains("audit") == true, "pg_restore, stop on error: \(outcome.error ?? "the restore didn't fail")")
        try expect(!outcome.tables.contains("child"), "pg_restore, stop on error: tables \(outcome.tables)")
        outcome = try await restore(archive, kind: .postgresArchive, role: .restorePostgresArchive, goOn, prepare: existing)
        try expect(outcome.tables.contains("child") && outcome.tables.contains("parent"), "pg_restore, go on: tables \(outcome.tables)")
        try expect(outcome.log.contains { $0.contains("audit") && $0.contains("already exists") },
                   "pg_restore, go on: the error is reported (\(outcome.error ?? "the run succeeded"))")
        print("[matrix] \(server.name): pg_restore going on after an error " + (outcome.error.map { "fails at the end: \($0)" } ?? "succeeds"))
    }

    struct Outcome {
        var error: String?
        var log: [String]
        var tables: Set<String>
    }

    func restore(_ file: URL, kind: BackupFileKind, role: BundledTools.Role, _ options: RestoreOptions,
                 prepare: String? = nil) async throws -> Outcome {
        let target = source + "_e" + UUID().uuidString.prefix(4).lowercased()
        try await createDatabase(target)
        if let prepare {
            let db = try await open(target)
            _ = try await db.execute(SQLStatement(prepare))
            await db.close()
        }
        let log = Lines()
        var error: String?
        do {
            try await RestoreJob(config: config, password: password, database: target, file: file, kind: kind, options: options,
                                 tool: try tool(role)).run { log.add($0) }
        } catch let e as DatabaseError {
            error = e.message
        }
        let db = try await open(target)
        let sql = isPostgres
            ? "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
            : "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
        let tables = Set(try await db.execute(SQLStatement(sql)).rows.compactMap { $0.first?.string })
        await db.close()
        return Outcome(error: error, log: log.all, tables: tables)
    }

    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw MatrixFailure(message) }
    }

    // MARK: - Fixtures

    func run(_ db: any DatabaseConnection, _ statements: [String]) async throws {
        for sql in statements {
            do {
                _ = try await db.execute(SQLStatement(sql))
            } catch {
                throw MatrixFailure("fixture: \(error)\n\(sql)")
            }
        }
    }

    func postgresFixture(_ db: any DatabaseConnection) async throws {
        let major = version[0]
        try await run(db, [
            #"DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'moonrow_matrix_reader') THEN CREATE ROLE moonrow_matrix_reader; END IF; END $$"#,
            "CREATE SCHEMA sales",
            "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')",
            "CREATE DOMAIN positive_int AS integer CHECK (VALUE > 0)",
            "CREATE SEQUENCE ticket_seq START 1000 INCREMENT 5",
            """
            CREATE TABLE parent (
                id serial PRIMARY KEY,
                code varchar(10) NOT NULL UNIQUE,
                name text,
                price numeric(12,4) DEFAULT 0,
                ratio double precision,
                small real,
                flag boolean NOT NULL DEFAULT true,
                kind mood DEFAULT 'ok',
                tags text[],
                born date,
                at timestamp(6),
                seen timestamptz,
                t time,
                span interval,
                doc jsonb,
                plain_doc json,
                raw bytea,
                uid uuid,
                addr inet,
                qty positive_int,
                ticket integer DEFAULT nextval('ticket_seq')
            )
            """,
            "COMMENT ON TABLE parent IS 'parents ✓'",
            "COMMENT ON COLUMN parent.name IS 'nom é'",
            "CREATE INDEX parent_name_lower ON parent (lower(name))",
            "CREATE INDEX parent_price_partial ON parent (price) WHERE price > 0",
            """
            CREATE TABLE child (
                id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                parent_id integer REFERENCES parent (id) ON DELETE CASCADE,
                note text,
                amount numeric(10,2) CONSTRAINT amount_not_negative CHECK (amount >= 0)
            )
            """,
            "CREATE TABLE audit (id bigserial PRIMARY KEY, what text)",
            "CREATE TABLE sales.big (id integer PRIMARY KEY, label text, n bigint)",
            "CREATE INDEX big_n ON sales.big (n)",
            #"CREATE FUNCTION upper_code() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.code := upper(NEW.code); RETURN NEW; END $$"#,
            #"CREATE FUNCTION log_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO audit (what) VALUES ('updated ' || NEW.id); RETURN NEW; END $$"#,
            "CREATE TRIGGER parent_upper BEFORE INSERT OR UPDATE ON parent FOR EACH ROW EXECUTE PROCEDURE upper_code()",
            "CREATE TRIGGER parent_audit AFTER UPDATE ON parent FOR EACH ROW EXECUTE PROCEDURE log_update()",
            "CREATE FUNCTION add_tax(x numeric) RETURNS numeric LANGUAGE sql IMMUTABLE AS 'SELECT x * 1.2'",
            """
            CREATE VIEW parent_totals AS SELECT p.id, p.name, count(c.id) AS children, sum(c.amount) AS total
            FROM parent p LEFT JOIN child c ON c.parent_id = p.id GROUP BY p.id, p.name
            """,
            "GRANT SELECT ON parent, parent_totals TO moonrow_matrix_reader",
            """
            INSERT INTO parent (code, name, price, ratio, small, flag, kind, tags, born, at, seen, t, span, doc, plain_doc, raw, uid, addr, qty)
            VALUES
            ('a1', 'Ünïcødé 日本語 😀', 12.3456, 1.0/3, 0.1, true, 'happy', '{"x","y z",NULL}', '2024-02-29', '2024-01-02 03:04:05.678901',
             '2024-06-01 12:00:00+02', '23:59:59', '1 year 2 mons 3 days 04:05:06', '{"a": [1, "ü", null]}', '{"b":  2}',
             '\\x00ff275c0a', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '192.168.0.1/24', 7),
            ('b2', 'it''s a "quote" \\ back\tslash
            newline', 0, -1e300, -0.5, false, 'sad', '{}', '0001-01-01', '1999-12-31 23:59:59', NULL, '00:00:00', '-1 day', '[]', 'null',
             '\\x', NULL, '::1', NULL),
            ('c3', NULL, NULL, NULL, NULL, true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
            ('gone', 'deleted', 1, 1, 1, true, 'ok', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
            """,
            "INSERT INTO child (parent_id, note, amount) VALUES (1, 'first ✓', 10.50), (1, NULL, 0), (2, 'tab\there', 99999999.99)",
            "INSERT INTO sales.big SELECT i, 'row ' || i || CASE WHEN i % 100 = 0 THEN ' ✓' ELSE '' END, (i * 7919) % 1000 FROM generate_series(1, 20000) i",
            "CREATE MATERIALIZED VIEW sales.big_summary AS SELECT n % 10 AS bucket, count(*) AS rows FROM sales.big GROUP BY 1",
            "UPDATE parent SET price = price + 1 WHERE code = 'A1'",
            "DELETE FROM parent WHERE code = 'GONE'",
        ])
        if major >= 11 {
            try await run(db, ["CREATE PROCEDURE clear_audit() LANGUAGE sql AS 'DELETE FROM audit'"])
        }
        if major >= 12 {
            try await run(db, ["ALTER TABLE parent ADD COLUMN name_length integer GENERATED ALWAYS AS (length(name)) STORED"])
        }
    }

    func mysqlFixture(_ db: any DatabaseConnection) async throws {
        let v = version
        try await run(db, [
            "CREATE TABLE digits (d tinyint PRIMARY KEY)",
            "INSERT INTO digits VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)",
            """
            CREATE TABLE parent (
                id int AUTO_INCREMENT PRIMARY KEY,
                code varchar(10) NOT NULL,
                name varchar(80) COLLATE utf8mb4_unicode_ci COMMENT 'nom é',
                price decimal(12,4) DEFAULT '0.0000',
                ratio double,
                small float,
                flag tinyint(1) NOT NULL DEFAULT 1,
                bits bit(8),
                kind enum('a','b','c') DEFAULT 'a',
                tags set('x','y','z'),
                born date,
                at datetime(6),
                seen timestamp NULL DEFAULT NULL,
                t time,
                y year,
                doc json,
                raw varbinary(16),
                body mediumtext,
                blobby blob,
                spot point,
                name_length int AS (char_length(name)) VIRTUAL,
                UNIQUE KEY uq_code (code),
                KEY ix_name_price (name(20), price),
                FULLTEXT KEY ft_body (body)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='parents ✓'
            """,
            """
            CREATE TABLE child (
                id int PRIMARY KEY,
                parent_id int,
                note text,
                amount decimal(10,2),
                CONSTRAINT fk_child_parent FOREIGN KEY (parent_id) REFERENCES parent (id) ON DELETE CASCADE ON UPDATE SET NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            "CREATE TABLE audit (id int AUTO_INCREMENT PRIMARY KEY, what varchar(40)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            "CREATE TABLE big (id int PRIMARY KEY, label varchar(40), n bigint, KEY ix_n (n)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            "CREATE TRIGGER parent_upper BEFORE INSERT ON parent FOR EACH ROW SET NEW.code = UPPER(NEW.code)",
            "CREATE TRIGGER parent_audit AFTER UPDATE ON parent FOR EACH ROW INSERT INTO audit (what) VALUES (CONCAT('updated ', NEW.id))",
            "CREATE FUNCTION add_tax(x decimal(12,4)) RETURNS decimal(12,4) DETERMINISTIC RETURN x * 1.2",
            "CREATE PROCEDURE count_children(IN pid int, OUT n int) READS SQL DATA BEGIN SELECT COUNT(*) INTO n FROM child WHERE parent_id = pid; END",
            """
            CREATE VIEW parent_totals AS SELECT p.id, p.name, COUNT(c.id) AS children, SUM(c.amount) AS total
            FROM parent p LEFT JOIN child c ON c.parent_id = p.id GROUP BY p.id, p.name
            """,
            "CREATE EVENT nightly ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00' DISABLE DO DELETE FROM audit WHERE id < 0",
            """
            INSERT INTO parent (code, name, price, ratio, small, flag, bits, kind, tags, born, at, seen, t, y, doc, raw, body, blobby, spot)
            VALUES
            ('a1', 'Ünïcødé 日本語 😀', 12.3456, 1.0/3, 0.1, 1, b'10100101', 'c', 'x,z', '2024-02-29', '2024-01-02 03:04:05.678901',
             '2024-06-01 12:00:00', '-838:59:59', 2024, '{"a": [1, "ü", null]}', X'00FF275C0A', 'lorem ipsum dolor ✓', X'DEADBEEF00',
             ST_GeomFromText('POINT(1 2)')),
            ('b2', 'it''s a "quote" \\\\ back\\tslash\\nnewline', 0, -1e300, -0.5, 0, b'0', 'a', '', '1000-01-01', '1999-12-31 23:59:59',
             NULL, '00:00:00', 1901, '[]', X'', '', X'', NULL),
            ('c3', NULL, NULL, NULL, NULL, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
            ('gone', 'deleted', 1, 1, 1, 1, NULL, 'b', 'y', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
            """,
            "INSERT INTO child VALUES (1, 1, 'first ✓', 10.50), (2, 1, NULL, 0), (3, 2, 'tab\\there', 99999999.99)",
            """
            INSERT INTO big SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 1,
                CONCAT('row ', a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 1, IF(a.d = 0 AND b.d = 0, ' ✓', '')),
                ((a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 1) * 7919) % 1000
            FROM digits a, digits b, digits c, digits e
            """,
            "UPDATE parent SET price = price + 1 WHERE code = 'A1'",
            "DELETE FROM parent WHERE code = 'GONE'",
        ])
        // CHECK constraints: MySQL 8.0.16 and MariaDB. Functional indexes: MySQL 8.0.13.
        if mariaDB || !v.lexicographicallyPrecedes([8, 0, 16]) {
            try await run(db, ["ALTER TABLE child ADD CONSTRAINT amount_not_negative CHECK (amount >= 0)"])
        }
        if !mariaDB, !v.lexicographicallyPrecedes([8, 0, 13]) {
            try await run(db, ["CREATE INDEX ix_lower_code ON parent ((lower(code)))"])
        }
    }

    // MARK: - Snapshots

    struct Snapshot {
        /// Catalog queries' rows, as text, by what they list.
        var schema: [String: [String]] = [:]
        /// Each table's and view's rows in key order.
        var data: [String: [[DBValue]]] = [:]
    }

    func rows(_ db: any DatabaseConnection, _ sql: String) async throws -> [[DBValue]] {
        try await db.execute(SQLStatement(sql)).rows
    }

    func lines(_ db: any DatabaseConnection, _ sql: String, database: String) async throws -> [String] {
        try await rows(db, sql).map { row in
            var line = row.map { $0.displayString }.joined(separator: " | ").replacingOccurrences(of: database, with: "<db>")
            // MySQL 5.7's mysqldump leaves NO_AUTO_CREATE_USER out of triggers' and routines'
            // sql_mode, so the backup loads into 8.0 (which dropped it); the mode only concerns
            // GRANT, which they don't run.
            if !isPostgres, !mariaDB { line = line.replacingOccurrences(of: "NO_AUTO_CREATE_USER,", with: "") }
            return line
        }
    }

    func snapshot(_ db: any DatabaseConnection, database: String, skip: Set<String> = []) async throws -> Snapshot {
        var s = Snapshot()
        if isPostgres {
            let schemas = "('public', 'sales')"
            let catalog: [String: String] = [
                "columns": """
                    SELECT table_schema, table_name, column_name, data_type, udt_name, is_nullable, column_default, is_identity,
                        is_generated, generation_expression
                    FROM information_schema.columns WHERE table_schema IN \(schemas) ORDER BY 1, 2, ordinal_position
                    """,
                "constraints": """
                    SELECT n.nspname, conrelid::regclass::text, contypid::regtype::text, conname, pg_get_constraintdef(c.oid)
                    FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname IN \(schemas) ORDER BY 1, 2, 3, 4
                    """,
                "indexes": "SELECT schemaname, indexname, indexdef FROM pg_indexes WHERE schemaname IN \(schemas) ORDER BY 1, 2",
                "views": "SELECT schemaname, viewname, definition FROM pg_views WHERE schemaname IN \(schemas) ORDER BY 1, 2",
                "matviews": "SELECT schemaname, matviewname, definition, ispopulated FROM pg_matviews WHERE schemaname IN \(schemas) ORDER BY 1, 2",
                "functions": """
                    SELECT p.proname, pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname IN \(schemas) ORDER BY 1
                    """,
                "triggers": "SELECT tgrelid::regclass::text, tgname, pg_get_triggerdef(oid) FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2",
                "sequences": """
                    SELECT schemaname, sequencename, data_type::text, start_value, increment_by, last_value
                    FROM pg_sequences WHERE schemaname IN \(schemas) ORDER BY 1, 2
                    """,
                "types": """
                    SELECT t.typname, t.typtype, string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder), format_type(t.typbasetype, t.typtypmod)
                    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace LEFT JOIN pg_enum e ON e.enumtypid = t.oid
                    WHERE n.nspname IN \(schemas) AND t.typtype IN ('e', 'd') GROUP BY 1, 2, 4 ORDER BY 1
                    """,
                "column comments": """
                    SELECT c.relname, a.attname, col_description(c.oid, a.attnum)
                    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
                    WHERE n.nspname IN \(schemas) AND col_description(c.oid, a.attnum) IS NOT NULL ORDER BY 1, 2
                    """,
                "privileges": """
                    SELECT n.nspname, c.relname, c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname IN \(schemas) AND c.relkind IN ('r', 'v', 'm') ORDER BY 1, 2
                    """,
            ]
            for (key, sql) in catalog { s.schema[key] = try await lines(db, sql, database: database) }
            s.schema["table comments"] = try await lines(db, """
                SELECT c.relname, obj_description(c.oid, 'pg_class') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname IN \(schemas) AND obj_description(c.oid, 'pg_class') IS NOT NULL ORDER BY 1
                """, database: database)
            for table in ["parent", "child", "audit", "sales.big", "sales.big_summary", "parent_totals"] where !skip.contains(table) {
                s.data[table] = try await rows(db, "SELECT * FROM \(table) ORDER BY 1")
            }
        } else {
            let tables = try await rows(db, """
                SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' ORDER BY 1
                """).compactMap { $0.first?.string }
            for table in tables {
                s.schema["table \(table)"] = try await lines(db, "SHOW CREATE TABLE \(dialect.quoteIdentifier(table))", database: database)
                s.data[table] = try await rows(db, "SELECT * FROM \(dialect.quoteIdentifier(table)) ORDER BY 1")
            }
            s.schema["tables"] = tables
            let catalog: [String: String] = [
                "views": """
                    SELECT TABLE_NAME, VIEW_DEFINITION, CHECK_OPTION, SECURITY_TYPE FROM information_schema.VIEWS
                    WHERE TABLE_SCHEMA = DATABASE() ORDER BY 1
                    """,
                "routines": """
                    SELECT ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER, ROUTINE_DEFINITION, IS_DETERMINISTIC, SQL_DATA_ACCESS, SECURITY_TYPE,
                        SQL_MODE, ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() ORDER BY 1
                    """,
                "parameters": """
                    SELECT SPECIFIC_NAME, ORDINAL_POSITION, PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER FROM information_schema.PARAMETERS
                    WHERE SPECIFIC_SCHEMA = DATABASE() ORDER BY 1, 2
                    """,
                "triggers": """
                    SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_ORDER, ACTION_STATEMENT, ACTION_TIMING, SQL_MODE
                    FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() ORDER BY 1
                    """,
                "events": """
                    SELECT EVENT_NAME, EVENT_DEFINITION, INTERVAL_VALUE, INTERVAL_FIELD, STARTS, STATUS, ON_COMPLETION
                    FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE() ORDER BY 1
                    """,
            ]
            for (key, sql) in catalog { s.schema[key] = try await lines(db, sql, database: database) }
            s.data["parent_totals"] = try await rows(db, "SELECT * FROM parent_totals ORDER BY 1")
        }
        return s
    }
}

struct MatrixFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
