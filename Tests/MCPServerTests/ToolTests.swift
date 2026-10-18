import AppCore
import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import MCPServer

/// The tools' rules, on SQLite files and (when they're up) the test servers.
@Suite struct ToolTests {
    private struct Setup {
        let h: Harness
        let config: ConnectionConfig
        let url: URL
        let token: String
        let session: String

        func tool(_ name: String, _ args: JSONValue = [:], token: String? = nil, session: String? = nil) async throws -> (JSONValue, Bool) {
            try await h.tool(name, args, token: token ?? self.token, session: session ?? self.session)
        }

        func query(_ sql: String, read: Bool = true, token: String? = nil, session: String? = nil) async throws -> (JSONValue, Bool) {
            try await tool(read ? "execute_read_query" : "execute_query",
                           ["connection_id": .string(config.id.uuidString), "query": .string(sql)], token: token, session: session)
        }
    }

    private func setup(rows: Int = 3, permission: MCPPermission = .fullAccess, readOnly: Bool = false, open: Bool = true) async throws -> Setup {
        let url = try await sampleDatabase(rows: rows)
        var config = ConnectionConfig.sqliteFile(url)
        config.readOnly = readOnly
        let host = TestHost([config], open: open ? [config.id] : [])
        let h = try Harness(host: host)
        let token = try h.token(permission)
        return Setup(h: h, config: config, url: url, token: token, session: try await h.initialize(token: token))
    }

    @Test func listsConnectionsTheTokenReaches() async throws {
        let a = ConnectionConfig(name: "A", driver: .postgres, host: "db", user: "me", database: "shop")
        let b = ConnectionConfig(name: "B", driver: .mysql, host: "/tmp/mysql.sock")
        let h = try Harness(host: TestHost([a, b], open: [b.id]))
        let all = try h.token(.readOnly)
        let s = try await h.initialize(token: all)
        let (list, _) = try await h.tool("list_connections", token: all, session: s)
        let items = list["connections"]?.array ?? []
        #expect(items.compactMap { $0["name"]?.string } == ["A", "B"])
        #expect(items[0]["driver"] == "postgres" && items[0]["port"] == 5432 && items[0]["default_database"] == "shop")
        #expect(items[0]["username"] == "me" && items[0]["is_open"] == false && items[0]["safe_mode"] == "silent")
        #expect(items[1]["port"] == .null && items[1]["is_open"] == true)
        let (open, _) = try await h.tool("list_open_connections", token: all, session: s)
        #expect(open["connections"]?.array?.compactMap { $0["name"]?.string } == ["B"])

        let onlyA = try h.token(.readOnly, access: .only([a.id]))
        let s2 = try await h.initialize(token: onlyA)
        #expect(try await h.tool("list_connections", token: onlyA, session: s2).0["connections"]?.array?.count == 1)
        #expect(try await h.tool("list_open_connections", token: onlyA, session: s2).0["connections"]?.array?.isEmpty == true)
        let (denied, isError) = try await h.tool("execute_read_query", ["connection_id": .string(b.id.uuidString), "query": "SELECT 1"],
                                                 token: onlyA, session: s2)
        #expect(isError && denied["error"] == "This token can't use that connection.")
    }

    @Test func readsRowsAsJSON() async throws {
        let t = try await setup()
        let (r, isError) = try await t.query("SELECT id, name, price, data, note, id FROM items ORDER BY id")
        #expect(!isError)
        #expect(r["row_count"] == 3 && r["is_truncated"] == false && r["database_type"] == "sqlite")
        #expect(r["current_database"] == "main")
        #expect(r["columns"]?.array?.compactMap { $0["name"]?.string } == ["id", "name", "price", "data", "note", "id_2"])
        let rows = r["rows"]?.array ?? []
        #expect(rows[0] == ["id": 1, "name": "pen", "price": 1.5, "data": "0x00ff", "note": nil, "id_2": 1])
        #expect(rows[1]["price"] == 3.25 && rows[1]["note"] == "blue")
        #expect(t.h.host.ran(t.config.id).map(\.sql) == ["SELECT id, name, price, data, note, id FROM items ORDER BY id"])
        // The text content is the same JSON.
        let raw = try await t.h.call("tools/call", ["name": "execute_read_query", "arguments": [
            "connection_id": .string(t.config.id.uuidString), "query": "SELECT 1 AS one",
        ]], token: t.token, session: t.session)
        #expect(raw["content"]?.array?.first?["type"] == "text")
        #expect(try JSONValue.decode(Data((raw["content"]?.array?.first?["text"]?.string ?? "").utf8)) == raw["structuredContent"])
    }

    @Test func scriptsReportEachStatement() async throws {
        let t = try await setup()
        let (r, isError) = try await t.query("INSERT INTO items (id, name) VALUES (10, 'a'), (11, 'b'); SELECT count(*) AS n FROM items; UPDATE items SET note = 'x' WHERE id >= 10", read: false)
        #expect(!isError)
        #expect(r["result_count"] == 3 && r["total_rows_affected"] == 4 && r["total_row_count"] == 1)
        let results = r["results"]?.array ?? []
        #expect(results[0]["rows_affected"] == 2 && results[0]["status_message"] == "2 rows affected")
        #expect(results[1]["rows"] == [["n": 5]])
        #expect(results[2]["statement"] == "UPDATE items SET note = 'x' WHERE id >= 10")
        // A failing statement stops the script and says which.
        let (f, failed) = try await t.query("SELECT 1; SELECT * FROM missing; SELECT 3", read: true)
        #expect(failed)
        #expect(f["error"]?.string?.hasPrefix("Statement 2 failed: ") == true)
        #expect(f["result_count"] == 1)
        #expect(t.h.host.ran(t.config.id).suffix(2).map(\.ok) == [true, false])
    }

    @Test func readToolRefusesWrites() async throws {
        let t = try await setup()
        for sql in ["DELETE FROM items", "SELECT 1; DROP TABLE items", "PRAGMA journal_mode = DELETE", "WITH x AS (DELETE FROM items RETURNING id) SELECT * FROM x"] {
            let (r, isError) = try await t.query(sql)
            #expect(isError)
            #expect(r["error"]?.string?.hasPrefix("execute_read_query runs reads only") == true)
        }
        #expect(t.h.host.requests.isEmpty)
        // Reads run with writes off, and the session is back to normal after.
        let (r, isError) = try await t.query("SELECT count(*) AS n FROM items")
        #expect(!isError && r["rows"] == [["n": 3]])
        let (w, wErr) = try await t.query("INSERT INTO items (id) VALUES (20)", read: false)
        #expect(!wErr && w["rows_affected"] == 1)
    }

    @Test func writesNeedPermission() async throws {
        let t = try await setup(permission: .readOnly)
        let (r, isError) = try await t.query("DELETE FROM items", read: false)
        #expect(isError && r["error"]?.string?.contains("Read Only") == true)
        // Reads through execute_query are fine for a Read Only token.
        #expect(try await t.query("SELECT 1 AS one", read: false).1 == false)
        // Opening and closing need Full Access.
        let rw = try t.h.token(.readWrite)
        let s = try await t.h.initialize(token: rw)
        let (o, oErr) = try await t.tool("open_connection", ["connection_id": .string(t.config.id.uuidString)], token: rw, session: s)
        #expect(oErr && o["error"]?.string?.contains("Full Access") == true)
        #expect(try await t.query("DELETE FROM items WHERE id = 3", read: false, token: rw, session: s).1 == false)
        let entries = try await t.h.log.entries(.init(category: .query))
        #expect(entries.contains { $0.status == .denied && $0.action == "tool.execute_query" && $0.query == "DELETE FROM items" })
    }

    @Test func readOnlyConnectionsAndApproval() async throws {
        let t = try await setup(readOnly: true)
        let (r, isError) = try await t.query("DELETE FROM items", read: false)
        #expect(isError && r["error"]?.string?.contains("is read-only") == true)

        let u = try await setup()
        u.h.host.authorization = .denied("The user denied it.")
        let (d, denied) = try await u.query("UPDATE items SET name = 'x'", read: false)
        #expect(denied && d["error"] == "The user denied it.")
        let request = try #require(u.h.host.requests.last)
        #expect(request.unsafe && request.client == "tests" && request.statements == ["UPDATE items SET name = 'x'"])
        // Reads are asked about too (safe mode may want them), marked safe.
        u.h.host.authorization = .allowed
        _ = try await u.query("SELECT 1")
        #expect(u.h.host.requests.last?.unsafe == false)
        let db = try SQLiteConnection(path: u.url.path)
        #expect(try await db.execute("SELECT count(*) FROM items WHERE name = 'x'").rows.first?.first == .integer(0))
        await db.close()
    }

    @Test func connectionsMustBeOpen() async throws {
        let t = try await setup(open: false)
        let (r, isError) = try await t.query("SELECT 1")
        #expect(isError && r["error"]?.string?.contains("isn't open") == true)
        // Without an id, the only open connection is used; with none open, it says so.
        let (n, nErr) = try await t.tool("execute_read_query", ["query": "SELECT 1"])
        #expect(nErr && n["error"]?.string?.hasPrefix("No connection is open") == true)
        let (o, oErr) = try await t.tool("open_connection", ["connection_id": .string(t.config.id.uuidString)])
        #expect(!oErr && o["connection"]?["is_open"] == true)
        let (q, qErr) = try await t.tool("execute_read_query", ["query": "SELECT 2 AS two"])
        #expect(!qErr && q["rows"] == [["two": 2]])
        let (c, cErr) = try await t.tool("disconnect", ["connection_id": .string(t.config.id.uuidString)])
        #expect(!cErr && c["closed_workspaces"] == 1)
        #expect(try await t.query("SELECT 1").1)
        #expect(try await t.tool("open_connection", ["connection_id": .string(UUID().uuidString)]).1)
        #expect(try await t.tool("open_connection", ["connection_id": "not-a-uuid"]).0["error"]?.string?.contains("isn't a UUID") == true)
    }

    @Test func limitsRows() async throws {
        let t = try await setup(rows: 1_500)
        let (r, _) = try await t.query("SELECT id FROM items ORDER BY id")
        #expect(r["row_count"] == .int(Int64(MCPTools.rowLimit)) && r["is_truncated"] == true)
        #expect(r["status_message"] == "1000 rows (truncated)")
    }

    @Test func timeoutAndCancel() async throws {
        let t = try await setup()
        let endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
        let (r, isError) = try await t.tool("execute_read_query", [
            "connection_id": .string(t.config.id.uuidString), "query": .string(endless), "timeout_seconds": 1,
        ])
        #expect(isError && r["error"]?.string?.contains("Stopped after 1 second") == true)
        // notifications/cancelled stops a running request.
        let request: JSONValue = ["jsonrpc": "2.0", "id": "long", "method": "tools/call", "params": [
            "name": "execute_read_query", "arguments": ["connection_id": .string(t.config.id.uuidString), "query": .string(endless)],
        ]]
        async let reply = t.h.post(request, token: t.token, session: t.session, accept: "application/json")
        try await Task.sleep(for: .milliseconds(300))
        let cancel = await t.h.post(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "long"]],
                                    token: t.token, session: t.session)
        #expect(cancel.status == 202)
        let result = await reply.json?["result"]
        #expect(result?["isError"] == true)
        // A stopped call is in the activity log too.
        let logged = try await t.h.log.entries(.init(category: .query))
        #expect(logged.contains { $0.action == "tool.execute_read_query" && $0.details == "Cancelled." })
        // The session works afterwards.
        #expect(try await t.query("SELECT 1 AS one").0["rows"] == [["one": 1]])
    }

    @Test func streamsProgress() async throws {
        let t = try await setup()
        let r = await t.h.post(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": [
            "name": "execute_read_query", "_meta": ["progressToken": "p1"],
            "arguments": ["connection_id": .string(t.config.id.uuidString), "query": "SELECT 1; SELECT 2"],
        ]], token: t.token, session: t.session)
        #expect(r.header("Content-Type") == "text/event-stream")
        let events = await r.events()
        guard case .prime(let first) = events.first else { Issue.record("no priming event"); return }
        #expect(first.hasSuffix("-0"))
        let messages = events.compactMap { e -> JSONValue? in if case .message(_, let v) = e { v } else { nil } }
        let progress = messages.filter { $0["method"] == "notifications/progress" }
        #expect(progress.compactMap { $0["params"]?["message"]?.string } == ["Running statement 1 of 2", "Running statement 2 of 2", "Done"])
        #expect(progress.allSatisfy { $0["params"]?["progressToken"] == "p1" && $0["params"]?["total"] == 2.0 })
        #expect(messages.last?["id"] == 5 && messages.last?["result"]?["structuredContent"]?["result_count"] == 2)
        #expect(events.last.map { $0.text.contains("\"id\":5") } == true)
    }

    @Test func resources() async throws {
        let t = try await setup()
        let id = t.config.id
        t.h.host.historyEntries[id] = [
            .init(sql: "SELECT 1", date: Date(timeIntervalSince1970: 1_000), ms: 2, ok: true),
            .init(sql: "SELECT 2", date: Date(timeIntervalSince1970: 2_000), ms: nil, ok: false),
        ]
        t.h.host.saved[id] = [MCPSavedQuery(path: "reports/daily", sql: "SELECT * FROM items", modified: Date(timeIntervalSince1970: 0))]
        let list = try await t.h.call("resources/list", token: t.token, session: t.session)["resources"]?.array ?? []
        #expect(list.compactMap { $0["uri"]?.string } == ["moonrow://history/\(id.uuidString)", "moonrow://queries/\(id.uuidString)"])
        let templates = try await t.h.call("resources/templates/list", token: t.token, session: t.session)["resourceTemplates"]?.array
        #expect(templates?.count == 2)
        let history = try await t.h.call("resources/read", ["uri": .string("moonrow://history/\(id.uuidString)")], token: t.token, session: t.session)
        let content = try #require(history["contents"]?.array?.first)
        #expect(content["mimeType"] == "application/json")
        let body = try JSONValue.decode(Data((content["text"]?.string ?? "").utf8))
        #expect(body["entries"]?.array?.compactMap { $0["sql"]?.string } == ["SELECT 2", "SELECT 1"])
        #expect(body["entries"]?.array?.first?["ok"] == false)
        let queries = try await t.h.call("resources/read", ["uri": .string("moonrow://queries/\(id.uuidString)")], token: t.token, session: t.session)
        let qBody = try JSONValue.decode(Data((queries["contents"]?.array?.first?["text"]?.string ?? "").utf8))
        #expect(qBody["queries"] == [["name": "reports/daily", "sql": "SELECT * FROM items", "modified": "1970-01-01T00:00:00Z"]])
        for bad in ["moonrow://history/\(id.uuidString)?x=1", "moonrow://history/\(id.uuidString)#a", "moonrow://other/\(id.uuidString)",
                    "moonrow://history/\(UUID().uuidString)", "file:///etc/passwd"] {
            await #expect(throws: MCPToolError.self) {
                _ = try await t.h.call("resources/read", ["uri": .string(bad)], token: t.token, session: t.session)
            }
        }
        let other = try t.h.token(.readOnly, access: .only([UUID()]))
        let s = try await t.h.initialize(token: other)
        #expect(try await t.h.call("resources/list", token: other, session: s)["resources"] == [])
        await #expect(throws: MCPToolError.self) {
            _ = try await t.h.call("resources/read", ["uri": .string("moonrow://history/\(id.uuidString)")], token: other, session: s)
        }
        let reads = try await t.h.log.entries(.init(category: .resource))
        #expect(reads.filter { $0.status == .success }.count == 2)
    }

    // MARK: - Servers

    /// A table on each test server, read and written through the tools; reads run in a
    /// read-only transaction, so a SELECT that writes fails there.
    @Test(arguments: ["MOONROW_TEST_PG", "MOONROW_TEST_MYSQL", "MOONROW_TEST_MARIADB"])
    func servers(_ variable: String) async throws {
        guard let (config, password) = serverConfig(variable) else { return }
        let host = TestHost([config], open: [config.id])
        host.setPassword(password, for: config.id)
        let h = try Harness(host: host)
        let token = try h.token()
        let s = try await h.initialize(token: token)
        func run(_ sql: String, read: Bool = false) async throws -> (JSONValue, Bool) {
            try await h.tool(read ? "execute_read_query" : "execute_query",
                             ["connection_id": .string(config.id.uuidString), "query": .string(sql)], token: token, session: s)
        }
        let table = "mcp_\(UUID().uuidString.prefix(8).lowercased())"
        let isPG = config.driver == .postgres
        _ = try await run("CREATE TABLE \(table) (id INT PRIMARY KEY, name VARCHAR(20), amount DECIMAL(8,2), flag BOOLEAN, at TIMESTAMP)")
        defer { Task { _ = try? await run("DROP TABLE \(table)"); await host.closeAll() } }
        let (ins, insErr) = try await run("INSERT INTO \(table) VALUES (1, 'a', 2.50, TRUE, '2026-01-02 03:04:05'), (2, NULL, NULL, FALSE, NULL)")
        #expect(!insErr && ins["rows_affected"] == 2)
        let (r, rErr) = try await run("SELECT * FROM \(table) ORDER BY id", read: true)
        #expect(!rErr)
        let rows = r["rows"]?.array ?? []
        #expect(rows.count == 2 && rows[0]["id"] == 1 && rows[0]["name"] == "a" && rows[1]["name"] == .null)
        #expect(rows[0]["amount"] == "2.50" || rows[0]["amount"] == 2.5)
        #expect(r["current_database"] == .string(config.database))
        #expect(r["database_type"] == .string(config.driver.rawValue))
        // The workspace moved to another database: the call follows it there, from the one the
        // session opened in, and back once the workspace is back.
        let other = isPG ? "template1" : "information_schema"
        host.workspaceDatabases[config.id] = other
        let (moved, movedErr) = try await run(isPG ? "SELECT current_database() AS db" : "SELECT DATABASE() AS db", read: true)
        #expect(!movedErr && moved["rows"] == [["db": .string(other)]] && moved["current_database"] == .string(other))
        host.workspaceDatabases[config.id] = nil
        let (back, backErr) = try await run("SELECT count(*) AS n FROM \(table)", read: true)
        #expect(!backErr && back["rows"] == [["n": 2]] && back["current_database"] == .string(config.database))
        // The guard: a read that writes is stopped by the server.
        if isPG {
            _ = try await run("CREATE SEQUENCE \(table)_seq")
            let (n, nErr) = try await run("SELECT nextval('\(table)_seq')", read: true)
            #expect(nErr && n["error"]?.string?.contains("read-only transaction") == true)
            _ = try await run("DROP SEQUENCE \(table)_seq")
        }
        // The session isn't left in a transaction: a write after a read commits.
        _ = try await run("SELECT 1", read: true)
        _ = try await run("UPDATE \(table) SET name = 'b' WHERE id = 2")
        let check = try await ConnectionFactory.open(config, password: password)
        #expect(try await check.execute("SELECT name FROM \(table) WHERE id = 2").rows.first?.first == .text("b"))
        await check.close()
    }
}
