import DBKit
import Foundation
import Testing
@testable import DriverSQLite

private func makeDB() async throws -> SQLiteConnection {
    let db = try SQLiteConnection(path: ":memory:")
    _ = try await db.transaction([
        SQLStatement("""
            CREATE TABLE users (
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              email TEXT UNIQUE,
              score REAL DEFAULT 0,
              avatar BLOB
            )
            """),
        SQLStatement("CREATE VIEW top AS SELECT * FROM users WHERE score > 50"),
    ])
    return db
}

@Suite struct SQLiteConnectionTests {
    @Test func introspection() async throws {
        let db = try await makeDB()
        let objects = try await db.objects(schema: nil)
        #expect(objects == [DatabaseObject(TableRef("top"), kind: .view),
                            DatabaseObject(TableRef("users"), kind: .table)])
        let cols = try await db.columns(of: TableRef("users"))
        #expect(cols.map(\.name) == ["id", "name", "email", "score", "avatar"])
        #expect(cols.primaryKey == ["id"])
        #expect(cols[1].isNullable == false)
        #expect(cols[3].defaultExpression == "0")
        await #expect(throws: DatabaseError.self) { try await db.columns(of: TableRef("nope")) }
    }

    @Test func gridRoundTrip() async throws {
        let db = try await makeDB()
        let users = TableRef("users")

        // Insert through a change set, including a blob and a NULL.
        try await db.commit(ChangeSet(users, inserts: [
            [.init("name", .text("Ann")), .init("email", .text("ann@x.io")), .init("score", .double(72.5))],
            [.init("name", .text("Bob")), .init("email", .null), .init("avatar", .blob(Data([1, 2, 3])))],
            [.init("name", .text("O'Hara")), .init("email", .text("oh@x.io")), .init("score", .integer(10))],
        ]))
        #expect(try await db.count(users) == 3)

        // Browse with filter, sort and paging.
        let page = try await db.browse(BrowseRequest(
            users, filter: Filter([.init(.anyColumn, .contains, "x.io")]),
            sort: [SortKey("name", ascending: false)], limit: 1, offset: 1))
        #expect(page.columns.map(\.name) == ["id", "name", "email", "score", "avatar"])
        #expect(page.rows.count == 1)
        #expect(page.rows[0][1] == .text("Ann"))

        // Types come back as stored.
        let bob = try await db.execute("SELECT avatar, email, score FROM users WHERE name = ?", .text("Bob"))
        #expect(bob.rows[0] == [.blob(Data([1, 2, 3])), .null, .double(0)])

        // Edit and delete by primary key.
        let counts = try await db.commit(ChangeSet(
            users,
            updates: [RowUpdate(key: [.init("id", .integer(1))], changes: [.init("score", .double(99))])],
            deletes: [[.init("id", .integer(2))]]))
        #expect(counts == [1, 1])
        let rest = try await db.execute("SELECT name, score FROM users ORDER BY id")
        #expect(rest.rows == [[.text("Ann"), .double(99)], [.text("O'Hara"), .double(10)]])
    }

    @Test func failedCommitRollsBack() async throws {
        let db = try await makeDB()
        let users = TableRef("users")
        try await db.commit(ChangeSet(users, inserts: [[.init("name", .text("A")), .init("email", .text("a@x"))]]))

        // Second insert violates UNIQUE(email): the first must not survive.
        await #expect(throws: DatabaseError.self) {
            try await db.commit(ChangeSet(users, inserts: [
                [.init("name", .text("B")), .init("email", .text("b@x"))],
                [.init("name", .text("C")), .init("email", .text("a@x"))],
            ]))
        }
        #expect(try await db.count(users) == 1)
    }

    @Test func verifyRollsBackAndStatementLogShowsValues() async throws {
        let db = try await makeDB()
        let log = Lines()
        await db.setStatementLog { log.append($0) }
        await #expect(throws: DatabaseError.self) {
            _ = try await db.transaction([
                SQLStatement("INSERT INTO users (name, email) VALUES (?, ?)", bindings: [.text("it's"), .text("i@x")]),
                SQLStatement("DELETE FROM users"),
            ]) { i, _ in if i == 1 { throw DatabaseError("stop") } }
        }
        #expect(try await db.count(TableRef("users")) == 0)
        #expect(log.all.prefix(4) == ["BEGIN", "INSERT INTO users (name, email) VALUES ('it''s', 'i@x')", "DELETE FROM users", "ROLLBACK"])
    }

    @Test func streamsInBatches() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2500) SELECT i FROM n"
        var sizes: [Int] = []
        for try await batch in db.stream(SQLStatement(sql), batchSize: 1000) {
            sizes.append(batch.rows.count)
        }
        #expect(sizes == [1000, 1000, 500])
    }

    @Test func stoppingEarlyCancelsAndFreesTheStatement() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n"
        var seen = 0
        for try await batch in db.stream(SQLStatement(endless), batchSize: 100) {
            seen += batch.rows.count
            if seen >= 300 { break }
        }
        #expect(seen == 300)
        // The connection is still usable afterwards.
        #expect(try await db.execute("SELECT 42").rows == [[.integer(42)]])
    }

    @Test func streamingStepsOnlyWhatTheConsumerReads() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let (entries, sink) = AsyncStream.makeStream(of: StatementLogEntry.self)
        db.statementLog?.observe { sink.yield($0) }
        let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n"
        var seen = 0
        for try await batch in db.stream(SQLStatement(endless), batchSize: 100) {
            seen += batch.rows.count
            // A slow consumer; the connection waits for it rather than buffering more rows.
            try await Task.sleep(for: .milliseconds(20))
            if seen >= 300 { break }
        }
        var log = entries.makeAsyncIterator()
        let entry = await log.next()
        #expect(entry?.rows == 300)
        #expect(entry?.error == "Cancelled")
    }

    @Test func cancellingTheTaskInterruptsALongStep() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        // One step that never returns a row: counts an endless series.
        let slow = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"
        let task = Task {
            var rows = 0
            for try await batch in db.stream(SQLStatement(slow), batchSize: 1) { rows += batch.rows.count }
            return rows
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        // A cancelled stream ends quietly (AsyncThrowingStream returns nil rather than throwing).
        let rows = try await task.value
        #expect(rows == 0)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(try await db.execute("SELECT 1").rows == [[.integer(1)]])
    }

    @Test func rejectsMultipleStatementsAndBadBindings() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        await #expect(throws: DatabaseError.self) { try await db.execute("SELECT 1; SELECT 2") }
        await #expect(throws: DatabaseError.self) { try await db.execute("SELECT ?") }
        // Trailing comments are fine.
        #expect(try await db.execute("SELECT 1; -- done").rows == [[.integer(1)]])
    }

    @Test func rowsAffected() async throws {
        let db = try await makeDB()
        _ = try await db.execute("INSERT INTO users (name) VALUES ('a'), ('b')")
        let r = try await db.execute("UPDATE users SET score = 1")
        #expect(r.rowsAffected == 2)
        #expect(r.columns.isEmpty)
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}
