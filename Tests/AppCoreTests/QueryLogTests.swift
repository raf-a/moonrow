import DBKit
import Foundation
import Testing
@testable import AppCore

/// Every statement a connection sends reaches its statement log once, when it ends: streamed
/// queries, introspection, transactions, failures and cancellations.
@Suite struct QueryLogTests {
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [StatementLogEntry] = []
        func add(_ e: StatementLogEntry) { lock.withLock { all.append(e) } }
        var entries: [StatementLogEntry] { lock.withLock { all } }
    }

    @Test(arguments: Backend.all) func connectionsReportWhatTheySend(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let log = try #require(f.db.statementLog)
        let seen = Collected()
        log.observe { seen.add($0) }
        defer { log.observe(nil) }

        _ = try await f.db.execute("SELECT name FROM items ORDER BY id")
        _ = try await f.db.execute(SQLStatement("SELECT name FROM items WHERE id = \(f.db.dialect.placeholder(1))", bindings: [.integer(1)]))
        await #expect(throws: (any Error).self) { try await f.db.execute("SELECT nope FROM items") }
        _ = try await f.db.transaction([SQLStatement("UPDATE items SET qty = qty WHERE id = 1")])
        _ = try await f.db.columns(of: TableRef("items"))

        let entries = seen.entries
        let select = try #require(entries.first { $0.sql == "SELECT name FROM items ORDER BY id" })
        #expect(select.rows == 3 && select.error == nil)
        let bound = try #require(entries.first { $0.bindings == [.integer(1)] })
        #expect(bound.rows == 1)
        #expect(entries.contains { $0.sql == "SELECT nope FROM items" && $0.error != nil })
        // The transaction's own statements and its UPDATE, which changed one row.
        #expect(entries.contains { $0.sql.uppercased().hasPrefix("UPDATE ITEMS") && $0.rows == 1 })
        #expect(entries.contains { $0.sql == f.db.dialect.commitTransaction })
        // Introspection goes through the log too.
        #expect(entries.count >= 6)

        log.observe(nil)
        _ = try await f.db.execute("SELECT 1")
        #expect(seen.entries.count == entries.count)
    }

    @Test func linesShowTimeDurationRowsAndValues() {
        let started = Date(timeIntervalSince1970: 0)
        var e = StatementLogEntry(sql: "SELECT *\n  FROM t WHERE a = $1", bindings: [.text("x")], started: started,
                                  duration: .milliseconds(4), rows: 1)
        let line = QueryLog.line(e, dialect: PostgresDialect(), locale: Locale(identifier: "en_US"))
        #expect(line.hasSuffix("4.0 ms    SELECT * FROM t WHERE a = $1  -- $1 = 'x'  -- 1 row"))
        #expect(line.distance(from: line.startIndex, to: line.range(of: "SELECT")!.lowerBound) == QueryLog.prefixWidth)
        e.error = "relation \"t\" does not exist"
        e.bindings = []
        #expect(QueryLog.line(e, dialect: PostgresDialect()).hasSuffix(#"-- Error: relation "t" does not exist"#))
        e.error = "Cancelled"
        e.rows = nil
        #expect(QueryLog.line(e, dialect: PostgresDialect()).hasSuffix("-- Stopped"))
        e.rows = 300
        #expect(QueryLog.line(e, dialect: PostgresDialect()).hasSuffix("-- stopped after 300 rows"))
    }

    @MainActor @Test func keepsTheNewestEntries() {
        let log = QueryLog(limit: 3)
        for i in 0..<5 { log.append(StatementLogEntry(sql: "SELECT \(i)", started: .now, duration: .zero)) }
        #expect(log.entries.map(\.sql) == ["SELECT 2", "SELECT 3", "SELECT 4"])
        #expect(log.dropped == 2)
        log.clear()
        #expect(log.entries.isEmpty)
    }
}
