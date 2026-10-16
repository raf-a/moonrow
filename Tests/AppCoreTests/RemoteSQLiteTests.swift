import DBKit
import DriverRemoteSQLite
import DriverSQLite
import Foundation
import Testing
import WireSupport
@testable import AppCore

/// The remote SQLite driver's protocol, against this Mac's own sqlite3 started the way the SSH
/// server would start it (the same launcher command, run by /bin/sh on a socket pair).
@Suite struct RemoteSQLiteTests {
    /// Runs `command` locally with its stdin and stdout on a socket pair, as ssh would.
    final class LocalRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []

        func endpoint(_ command: String) -> Endpoint {
            .stream(StreamOpener(description: "local sqlite3", hostName: nil) { [self] in
                var pair: [Int32] = [-1, -1]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw DatabaseError("socketpair") }
                let process = Process()
                process.executableURL = URL(filePath: "/bin/sh")
                process.arguments = ["-c", command]
                // Closed here once the child has it, so its exit ends the stream (as ssh's does).
                let theirs = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
                process.standardInput = theirs
                process.standardOutput = theirs
                try process.run()
                Darwin.close(pair[1])
                lock.withLock { processes.append(process) }
                return OpenedStream(descriptor: pair[0])
            })
        }

        var running: [Process] { lock.withLock { processes.filter(\.isRunning) } }
    }

    private func file(_ setup: String) async throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "moonrow-remote-\(UUID().uuidString).sqlite").path
        let db = try SQLiteConnection(path: path)
        for statement in setup.split(separator: ";").map(String.init) where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await db.execute(SQLStatement(statement))
        }
        await db.close()
        return path
    }

    private func connect(_ path: String, sqlite3: String = "/usr/bin/sqlite3", readOnly: Bool = false,
                         bootstrap: [String] = [], runner: LocalRunner = LocalRunner()) async throws -> RemoteSQLiteConnection {
        let command = RemoteSQLiteConfiguration.command(sqlite3: sqlite3, path: path, readOnly: readOnly)
        return try await RemoteSQLiteConnection.connect(RemoteSQLiteConfiguration(
            endpoint: runner.endpoint(command), path: path, bootstrap: bootstrap,
            interrupt: { pid in kill(pid_t(pid), SIGINT) }))
    }

    static let setup = """
        CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL, data BLOB, note TEXT DEFAULT 'none');
        CREATE INDEX items_name ON items (name);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, item INTEGER REFERENCES items (id) ON DELETE CASCADE, tag TEXT);
        INSERT INTO items (name, price, data, note) VALUES ('plain', 1.5, X'00FF10', NULL);
        INSERT INTO items (name, price, note) VALUES ('it''s
        two lines', 0.1, 'tab	inside')
        """

    @Test func valuesKeepTheirTypes() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path)
        let r = try await db.execute("SELECT id, name, price, data, note FROM items ORDER BY id")
        #expect(r.columns.map(\.name) == ["id", "name", "price", "data", "note"])
        #expect(r.rows.count == 2)
        #expect(r.rows[0] == [.integer(1), .text("plain"), .double(1.5), .blob(Data([0, 0xFF, 0x10])), .null])
        #expect(r.rows[1] == [.integer(2), .text("it's\ntwo lines"), .double(0.1), .null, .text("tab\tinside")])
        // No rows: the columns are still known.
        let empty = try await db.execute("SELECT name AS label, price * 2 FROM items WHERE id < 0")
        #expect(empty.rows.isEmpty && empty.columns.map(\.name) == ["label", "price * 2"])
        // Bound values are written into the statement.
        let bound = try await db.execute(SQLStatement("SELECT name FROM items WHERE id = ? AND name <> ?", bindings: [.integer(1), .text("o'k")]))
        #expect(bound.rows == [[.text("plain")]])
        #expect(db.sqliteVersion.hasPrefix("3."))
        await db.close()
    }

    @Test func writesReportTheirRows() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path)
        #expect(try await db.execute("UPDATE items SET price = price + 1").rowsAffected == 2)
        #expect(try await db.execute("INSERT INTO items (name) VALUES ('a'), ('b'), ('c')").rowsAffected == 3)
        let returning = try await db.execute("DELETE FROM items WHERE name IN ('a', 'b') RETURNING id, name")
        #expect(returning.columns.map(\.name) == ["id", "name"] && returning.rows.count == 2 && returning.rowsAffected == 2)
        #expect(try await db.execute("CREATE TABLE more (x)").rowsAffected == 0)
        // PRAGMA rows come through the CLI's own output.
        let info = try await db.execute("PRAGMA table_info(items)")
        #expect(info.columns.first?.name == "cid" && info.rows.count == 5 && info.rows[1][1] == .text("name"))
        // The file on this Mac sees the writes: they were made on the live file.
        let local = try SQLiteConnection(path: path)
        #expect(try await local.execute("SELECT count(*) FROM items").rows.first?.first == .integer(3))
        await local.close()
        await db.close()
    }

    @Test func errorsComeBackAsDatabaseErrors() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path)
        do {
            _ = try await db.execute("SELEC 1")
            Issue.record("no error")
        } catch let e as DatabaseError {
            #expect(e.message.contains("syntax error") && e.sql == "SELEC 1")
        }
        do {
            _ = try await db.execute("INSERT INTO items (id, name) VALUES (1, 'dup')")
            Issue.record("no error")
        } catch let e as DatabaseError {
            #expect(e.message.contains("UNIQUE constraint failed"))
        }
        await #expect(throws: DatabaseError.self) { try await db.execute("SELECT * FROM nowhere") }
        // The session goes on.
        #expect(try await db.execute("SELECT count(*) FROM items").rows.first?.first == .integer(2))
        await db.close()
    }

    @Test func introspectionAndTransactions() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path)
        #expect(try await db.objects(schema: nil).map(\.ref.name) == ["items", "tags"])
        let columns = try await db.columns(of: TableRef("items"))
        #expect(columns.map(\.name) == ["id", "name", "price", "data", "note"] && columns[0].primaryKeyPosition == 1)
        #expect(columns[4].defaultExpression == "'none'")
        #expect(try await db.indexes(of: TableRef("items")).map(\.name) == ["items_name"])
        #expect(try await db.foreignKeys(of: TableRef("tags")).first?.referencedTable.name == "items")
        #expect(try await db.definition(of: DatabaseObject(TableRef("items"), kind: .table)).contains("CREATE INDEX items_name"))

        let counts = try await db.transaction([
            SQLStatement("INSERT INTO tags (item, tag) VALUES (?, ?)", bindings: [.integer(1), .text("x")]),
            SQLStatement("UPDATE items SET note = 'tagged' WHERE id = 1"),
        ])
        #expect(counts == [1, 1])
        await #expect(throws: (any Error).self) {
            try await db.transaction([SQLStatement("DELETE FROM tags"), SQLStatement("UPDATE items SET id = 2 WHERE id = 1")])
        }
        // Rolled back: the tag is still there.
        #expect(try await db.execute("SELECT count(*) FROM tags").rows.first?.first == .integer(1))
        await db.close()
    }

    @Test func wideRowsAndBigResults() async throws {
        let columns = (1...150).map { "c\($0) INTEGER DEFAULT \($0)" }.joined(separator: ", ")
        let path = try await file("CREATE TABLE wide (\(columns)); INSERT INTO wide DEFAULT VALUES")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path)
        let wide = try await db.execute("SELECT * FROM wide")
        #expect(wide.columns.count == 150 && wide.rows.first?.last == .integer(150))
        var batches = 0, rows = 0
        for try await batch in db.stream(SQLStatement("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2500) SELECT i FROM n"), batchSize: 1000) {
            batches += 1
            rows += batch.rows.count
        }
        #expect(rows == 2500 && batches == 3)
        await db.close()
    }

    /// Stopping a statement interrupts sqlite3, which leaves; the next statement starts another.
    @Test func cancelStopsTheStatement() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner = LocalRunner()
        let db = try await connect(path, runner: runner)
        let endless = SQLStatement("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n")
        let clock = ContinuousClock(), start = clock.now
        let task = Task { try await db.execute(endless) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        #expect(clock.now - start < .seconds(5))
        #expect(try await db.execute("SELECT count(*) FROM items").rows.first?.first == .integer(2))
        await db.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(runner.running.isEmpty)
    }

    @Test func bootstrapAndReadOnly() async throws {
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try await connect(path, readOnly: true, bootstrap: ["CREATE TEMP TABLE boot (x)", "INSERT INTO boot VALUES (7)"])
        #expect(try await db.execute("SELECT x FROM boot").rows == [[.integer(7)]])
        await #expect(throws: DatabaseError.self) { try await db.execute("DELETE FROM items") }
        await db.close()
    }

    @Test func missingFileOrSQLite() async throws {
        await #expect(throws: RemoteSQLiteError.self) { try await connect("/nowhere/at/all.sqlite") }
        let path = try await file(Self.setup)
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            _ = try await connect(path, sqlite3: "moonrow-no-such-sqlite3")
            Issue.record("connected")
        } catch let e as RemoteSQLiteError {
            if case .noSQLite = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func launcherQuotesItsArguments() {
        let command = RemoteSQLiteConfiguration.command(sqlite3: "sqlite3", path: "~/it's here.db", readOnly: true)
        #expect(command.hasPrefix("exec sh -c '"))
        #expect(command.hasSuffix(#" 'sqlite3' '~/it'\''s here.db'"#))
        #expect(command.contains("-batch -readonly"))
    }
}
