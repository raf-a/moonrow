import DBKit
import DriverSQLite
import Foundation
import SQLScript
import Testing
@testable import AppCore

private func memoryDB() async throws -> SQLiteConnection {
    let db = try SQLiteConnection(path: ":memory:")
    _ = try await db.transaction([
        SQLStatement("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"),
        SQLStatement("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1200) INSERT INTO t SELECT x, 'row ' || x FROM n"),
    ])
    return db
}

/// A compact log of the events, rows counted rather than listed.
private func trace(_ script: String, on db: SQLiteConnection, _ options: ScriptRunner.Options = .init()) async -> [String] {
    var out: [String] = []
    var rows: [Int: Int] = [:]
    for await event in ScriptRunner.run(SQLSplitter.split(script, dialect: .sqlite), on: db, options: options) {
        switch event {
        case .started(let i): out.append("start \(i)")
        case .columns(let i, let c): out.append("columns \(i) \(c.map(\.name).joined(separator: ","))")
        case .rows(let i, let r): rows[i, default: 0] += r.count
        case .finished(let i, let o):
            out.append("finish \(i) rows=\(rows[i] ?? 0)/\(o.rowCount) affected=\(o.rowsAffected.map(String.init) ?? "-")\(o.truncated ? " truncated" : "")")
        case .failed(let i, let failure): out.append("fail \(i) \(failure.message)")
        case .done: out.append("done")
        }
    }
    return out
}

@Suite struct ScriptRunnerTests {
    @Test func runsEachStatementInOrder() async throws {
        let db = try await memoryDB()
        let log = await trace("""
            select id, name from t where id <= 3;
            update t set name = 'x' where id < 10;
            select count(*) as n from t
            """, on: db)
        #expect(log == [
            "start 0", "columns 0 id,name", "finish 0 rows=3/3 affected=-",
            "start 1", "finish 1 rows=0/0 affected=9",
            "start 2", "columns 2 n", "finish 2 rows=1/1 affected=-",
            "done",
        ])
    }

    @Test func emptyResultStillHasColumns() async throws {
        let db = try await memoryDB()
        #expect(await trace("select id from t where id < 0", on: db) == ["start 0", "columns 0 id", "finish 0 rows=0/0 affected=-", "done"])
    }

    @Test func rowLimitStopsTheStatement() async throws {
        let db = try await memoryDB()
        let log = await trace("select * from t; select 1 as one", on: db, .init(rowLimit: 1000, batchSize: 300))
        #expect(log == [
            "start 0", "columns 0 id,name", "finish 0 rows=1000/1000 affected=- truncated",
            "start 1", "columns 1 one", "finish 1 rows=1/1 affected=-", "done",
        ])
        // Exactly at the limit isn't truncated.
        let exact = await trace("select * from t limit 1000", on: db, .init(rowLimit: 1000))
        #expect(exact[2] == "finish 0 rows=1000/1000 affected=-")
    }

    @Test func stopsAtTheFirstErrorUnlessAskedNotTo() async throws {
        let db = try await memoryDB()
        let script = "select 1 as a; select * from missing; select 2 as b"
        #expect(await trace(script, on: db) == [
            "start 0", "columns 0 a", "finish 0 rows=1/1 affected=-",
            "start 1", "fail 1 no such table: missing", "done",
        ])
        let all = await trace(script, on: db, .init(stopOnError: false))
        #expect(all.suffix(5) == ["fail 1 no such table: missing", "start 2", "columns 2 b", "finish 2 rows=1/1 affected=-", "done"])
    }

    @Test func cancellingStopsARunningStatement() async throws {
        let db = try await memoryDB()
        let endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c; select 1"
        let events = ScriptRunner.run(SQLSplitter.split(endless, dialect: .sqlite), on: db)
        let consumer = Task {
            var seen: [String] = []
            for await event in events {
                switch event {
                case .started(let i): seen.append("start \(i)")
                case .done: seen.append("done")
                case .finished, .failed: seen.append("ended")
                default: break
                }
            }
            return seen
        }
        try await Task.sleep(for: .milliseconds(150))
        let clock = ContinuousClock()
        let start = clock.now
        consumer.cancel()
        let seen = await consumer.value
        #expect(seen == ["start 0"])
        #expect(clock.now - start < .seconds(2))
        // The connection is usable afterwards.
        let n = try await db.execute("select count(*) from t")
        #expect(n.rows == [[.integer(1200)]])
    }

    /// Postgres says where in the statement the error is; the failure carries it as a UTF-16
    /// offset into the statement's text. MySQL, MariaDB and SQLite don't say.
    @Test(arguments: Backend.all) func failuresCarryTheErrorPosition(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        // Two characters outside the BMP before the error: code points and UTF-16 units differ.
        let script = "select 1 as a;\nselect '😀😀' as s, nope from items"
        let statements = SQLSplitter.split(script, dialect: f.db.dialect.lexer)
        var failure: ScriptRunner.Failure?
        for await event in ScriptRunner.run(statements, on: f.db) {
            if case .failed(let i, let fail) = event {
                #expect(i == 1)
                failure = fail
            }
        }
        let fail = try #require(failure)
        #expect(!fail.message.isEmpty && !fail.headline.contains("\n"))
        if backend.kind == .postgres {
            let text = statements[1].text as NSString
            #expect(fail.position == text.range(of: "nope").location, "\(fail.position.map(String.init) ?? "nil")")
        } else {
            #expect(fail.position == nil)
        }
    }

    @Test func failuresMarkTheTokenAtTheirPosition() {
        let text = "select 1;\nselect a,  nope from t"
        let statement = SQLSplitter.split(text, dialect: .sqlite)[1]
        let ns = text as NSString
        func marked(_ position: Int?) -> String {
            let r = ScriptRunner.Failure(message: "x", position: position, duration: .zero).range(in: statement, dialect: .sqlite)
            return ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        }
        #expect(marked(12) == "nope")
        #expect(marked(13) == "nope")
        // Between tokens: the next one.
        #expect(marked(10) == "nope")
        // Unknown or past the end: the whole statement.
        #expect(marked(nil) == "select a,  nope from t")
        #expect(marked(99) == "select a,  nope from t")
    }

    @Test func sortingIsStableWithNullsFirst() {
        let rows: [[DBValue]] = [[.text("b")], [.null], [.integer(10)], [.text("2.5")], [.text("a")], [.null], [.double(-1)], [.text("b")]]
        let up = ResultSort.order(rows, column: 0, ascending: true)
        #expect(up == [1, 5, 6, 3, 2, 4, 0, 7])
        let down = ResultSort.order(rows, column: 0, ascending: false)
        // Reversed, but equal values keep the server's order.
        #expect(down == [0, 7, 4, 2, 3, 6, 1, 5])
        #expect(ResultSort.compare(.text("item 2"), .text("item 10")) == .orderedAscending)
    }

    @Test func summaryCountsTheStatementsThatRan() {
        let en = Locale(identifier: "en_US")
        #expect(ScriptRunner.Summary(total: 5, ran: 5, duration: .milliseconds(12)).text(locale: en) == "5 statements · 12 ms")
        #expect(ScriptRunner.Summary(total: 5, ran: 3, failed: 2, duration: .milliseconds(12)).text(locale: en)
            == "3 of 5 statements ran · statement 3 failed · 12 ms")
        #expect(ScriptRunner.Summary(total: 5, ran: 5, failed: 4, duration: .milliseconds(12)).text(locale: en)
            == "5 statements · statement 5 failed · 12 ms")
        #expect(ScriptRunner.Summary(total: 4, ran: 2, stopped: true, duration: .seconds(2)).text(locale: en)
            == "2 of 4 statements ran · stopped · 2.00 s")
        #expect(ScriptRunner.Summary(total: 1, ran: 1, duration: .microseconds(300)).text(locale: en) == "1 statement · 0.3 ms")
    }

    @Test func durationsNeverReadZero() {
        let en = Locale(identifier: "en_US"), fr = Locale(identifier: "fr_FR")
        #expect(DurationText.string(.microseconds(10), locale: en) == "< 0.1 ms")
        #expect(DurationText.string(.microseconds(400), locale: en) == "0.4 ms")
        #expect(DurationText.string(.microseconds(400), locale: fr) == "0,4 ms")
        #expect(DurationText.string(.milliseconds(4), locale: en) == "4.0 ms")
        #expect(DurationText.string(.microseconds(9_990), locale: en) == "10 ms")
        #expect(DurationText.string(.milliseconds(250), locale: en) == "250 ms")
        #expect(DurationText.string(.milliseconds(1_234), locale: en) == "1.23 s")
        #expect(DurationText.string(.milliseconds(1_234), locale: fr) == "1,23 s")
        #expect(DurationText.string(.seconds(65), locale: en) == "1:05")
        #expect(DurationText.string(.seconds(3_725), locale: en) == "1:02:05")
    }

    @Test func selectionPicksStatements() {
        let text = "select 1;\nselect 2;\nselect 3"
        let current = ScriptSelection.current(in: text, selection: 12..<12, dialect: .sqlite)
        #expect(current.map(\.text) == ["select 2"])
        // A selection runs just the selected text, split into statements.
        let selected = ScriptSelection.current(in: text, selection: 3..<17, dialect: .sqlite)
        #expect(selected.map(\.text) == ["ect 1", "select"])
        #expect(selected[1].range == 10..<16)
        #expect(ScriptSelection.all(in: text, selection: 0..<0, dialect: .sqlite).count == 3)
    }
}
