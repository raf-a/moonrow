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
        case .failed(let i, let message, _): out.append("fail \(i) \(message)")
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
