import AppCore
import Foundation
import Testing
@testable import MCPServer

/// JSON-RPC, Streamable HTTP's rules, sessions and auth, driven through the router.
@Suite struct ProtocolTests {
    @Test func parsesMessages() throws {
        let request = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8))
        #expect(request == .request(id: 7, method: "ping", params: nil))
        let note = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(note == .notification(method: "notifications/initialized", params: nil))
        let response = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"a","result":{}}"#.utf8))
        #expect(response == .response(id: "a", result: [:], error: nil))
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)) }
        #expect(throws: JSONRPCError.invalidRequest) { try JSONRPCMessage.parse(Data(#"{"id":1,"method":"ping"}"#.utf8)) }
        #expect(throws: JSONRPCError.invalidRequest) { try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":{},"method":"ping"}"#.utf8)) }
        #expect(throws: JSONRPCError.parse) { try JSONRPCMessage.parse(Data("{".utf8)) }
        // Big integers and fractions survive.
        let value = try JSONValue.decode(Data(#"{"a":9007199254740993,"b":1.5,"c":[true,null,"x"]}"#.utf8))
        #expect(value["a"] == .int(9_007_199_254_740_993))
        #expect(value["b"] == .double(1.5))
        #expect(value.text == #"{"a":9007199254740993,"b":1.5,"c":[true,null,"x"]}"#)
    }

    @Test func initializeNegotiatesAndStartsASession() async throws {
        let h = try Harness(host: TestHost([]))
        let token = try h.token()
        for (asked, answered) in [("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("2024-11-05", "2025-11-25")] {
            let r = await h.post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": .string(asked), "capabilities": [:], "clientInfo": ["name": "c", "version": "2"],
            ]], token: token)
            #expect(r.status == 200)
            #expect(r.header("Mcp-Session-Id")?.allSatisfy { (0x21...0x7E).contains($0.asciiValue ?? 0) } == true)
            let result = try #require(r.json?["result"])
            #expect(result["protocolVersion"] == .string(answered))
            #expect(result["serverInfo"]?["name"] == "moonrow")
            #expect(result["capabilities"]?["tools"] != nil)
            #expect(result["capabilities"]?["resources"] != nil)
        }
        #expect(await h.sessions.all.count == 3)
        #expect(await h.sessions.all.first?.clientName == "c")
    }

    @Test func sessionRules() async throws {
        let h = try Harness(host: TestHost([]))
        let token = try h.token(), other = try h.token()
        let session = try await h.initialize(token: token)
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "ping"]
        #expect(await h.post(ping, token: token, session: session).status == 200)
        #expect(await h.post(ping, token: token).status == 400)
        #expect(await h.post(ping, token: token, session: "nope").status == 404)
        // Another token can't use the session.
        #expect(await h.post(ping, token: other, session: session).status == 404)
        // A notification or a response is accepted without a body.
        let note = await h.post(["jsonrpc": "2.0", "method": "notifications/progress", "params": [:]], token: token, session: session)
        #expect(note.status == 202 && note.data?.isEmpty == true)
        #expect(await h.post(["jsonrpc": "2.0", "id": 9, "result": [:]], token: token, session: session).status == 202)
        // The protocol version header must be one we speak.
        #expect(await h.post(ping, token: token, session: session, headers: [("MCP-Protocol-Version", "2025-06-18")]).status == 200)
        #expect(await h.post(ping, token: token, session: session, headers: [("MCP-Protocol-Version", "1999-01-01")]).status == 400)
        // Batches and bad JSON.
        let batch = await h.router.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: [
            ("Content-Type", "application/json"), ("Authorization", "Bearer \(token)"), ("Mcp-Session-Id", session),
        ], body: Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)))
        #expect(batch.status == 400)
        #expect(batch.json?["error"]?["code"] == -32600)
        #expect(batch.json?["id"] == .null)
        // Content types.
        let text = await h.router.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: [
            ("Content-Type", "text/plain"), ("Authorization", "Bearer \(token)"), ("Mcp-Session-Id", session),
        ], body: ping.encoded()))
        #expect(text.status == 415)
        #expect(await h.post(ping, token: token, session: session, accept: "text/html").status == 406)
        // Unknown methods are JSON-RPC errors.
        await #expect(throws: MCPToolError.self) { _ = try await h.call("nothing/here", token: token, session: session) }
        // DELETE ends it; afterwards it's unknown.
        let delete = await h.router.handle(MCPHTTPRequest(method: "DELETE", path: "/mcp", headers: [
            ("Authorization", "Bearer \(token)"), ("Mcp-Session-Id", session),
        ]))
        #expect(delete.status == 200)
        #expect(await h.post(ping, token: token, session: session).status == 404)
    }

    @Test func authAndRateLimit() async throws {
        let h = try Harness(host: TestHost([]), limiter: MCPRateLimiter(limit: 3, window: 60))
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]]
        let none = await h.post(ping, token: nil)
        #expect(none.status == 401)
        #expect(none.header("WWW-Authenticate") == #"Bearer realm="Moonrow MCP", error="invalid_token""#)
        #expect(await h.post(ping, token: "mr_wrong").status == 401)
        #expect(await h.post(ping, token: "Basic abc").status == 401)
        // Past the limit a bad token is turned away for a while; a good one from the same
        // address (every local client's) still gets through.
        let limited = await h.post(ping, token: "mr_wrong")
        #expect(limited.status == 429)
        #expect(Int(limited.header("Retry-After") ?? "") ?? 0 > 0)
        let token = try h.token()
        #expect(await h.post(ping, token: token).status == 200)
        // Turned-away attempts aren't counted or logged, so the lockout doesn't feed itself.
        let failures = try await h.log.entries(.init(category: .auth))
        #expect(failures.count == 3 && failures.allSatisfy { $0.status == .denied })
    }

    @Test func revokedAndExpiredTokens() async throws {
        let h = try Harness(host: TestHost([]))
        let (record, token) = try h.tokens.create(name: "t", permission: .readOnly)
        let session = try await h.initialize(token: token)
        try h.tokens.revoke(id: record.id)
        #expect(await h.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], token: token, session: session).status == 401)
        let (_, expired) = try h.tokens.create(name: "e", permission: .readOnly, expiresAt: Date().addingTimeInterval(-1))
        #expect(h.tokens.verify(expired) == nil)
    }

    @Test func originsAndPreflight() async throws {
        let h = try Harness(host: TestHost([]))
        let token = try h.token()
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]]
        let evil = await h.post(ping, token: token, headers: [("Origin", "http://evil.example")])
        #expect(evil.status == 403)
        #expect(evil.json?["error"] != nil)
        let local = await h.post(ping, token: token, headers: [("Origin", "http://localhost:3000")])
        #expect(local.status == 200)
        #expect(local.header("Access-Control-Allow-Origin") == "http://localhost:3000")
        let preflight = await h.router.handle(MCPHTTPRequest(method: "OPTIONS", path: "/mcp", headers: [("Origin", "http://127.0.0.1:8080")]))
        #expect(preflight.status == 204)
        #expect(preflight.header("Access-Control-Allow-Headers")?.contains("Mcp-Session-Id") == true)
        #expect(await h.router.handle(MCPHTTPRequest(method: "OPTIONS", path: "/mcp", headers: [("Origin", "https://localhost.evil.example")])).status == 403)
        #expect(await h.router.handle(MCPHTTPRequest(method: "GET", path: "/other", headers: [])).status == 404)
    }

    @Test func getStreams() async throws {
        let h = try Harness(host: TestHost([]))
        let token = try h.token()
        let session = try await h.initialize(token: token)
        func get(_ headers: [(String, String)]) async -> MCPHTTPResponse {
            await h.router.handle(MCPHTTPRequest(method: "GET", path: "/mcp", headers: [("Authorization", "Bearer \(token)")] + headers))
        }
        #expect(await get([("Accept", "application/json"), ("Mcp-Session-Id", session)]).status == 405)
        #expect(await get([("Accept", "text/event-stream"), ("Mcp-Session-Id", session), ("Last-Event-ID", "x-1")]).status == 501)
        #expect(await get([("Accept", "text/event-stream")]).status == 400)
        let stream = await get([("Accept", "text/event-stream"), ("Mcp-Session-Id", session)])
        #expect(stream.status == 200 && stream.header("Content-Type") == "text/event-stream")
        await h.sessions.keepAlive()
        await h.sessions.end(session, .clientRequested)
        #expect(await stream.events() == [.comment("keep-alive")])
    }

    @Test func sessionLimits() async throws {
        let h = try Harness(host: TestHost([]), limits: .init(maxSessions: 2, idleTimeout: 60))
        let token = try h.token()
        let a = try await h.initialize(token: token)
        let b = try await h.initialize(token: token)
        _ = await h.sessions.touch(a)
        let c = try await h.initialize(token: token)
        // The least recently active went.
        #expect(await h.sessions.info(b) == nil)
        #expect(await h.sessions.info(a) != nil)
        #expect(await h.sessions.info(c) != nil)
        await h.sessions.sweep(now: Date().addingTimeInterval(120))
        #expect(await h.sessions.all.isEmpty)
    }

    @Test func pingPromptsAndCompletions() async throws {
        let h = try Harness(host: TestHost([]))
        let token = try h.token()
        let s = try await h.initialize(token: token)
        #expect(try await h.call("ping", token: token, session: s) == [:])
        #expect(try await h.call("prompts/list", token: token, session: s) == ["prompts": []])
        #expect(try await h.call("logging/setLevel", ["level": "info"], token: token, session: s) == [:])
        #expect(try await h.call("completion/complete", token: token, session: s)["completion"]?["values"] == [])
        let tools = try await h.call("tools/list", token: token, session: s)["tools"]?.array ?? []
        #expect(tools.compactMap { $0["name"]?.string } == [
            "list_connections", "list_open_connections", "open_connection", "disconnect", "execute_query", "execute_read_query",
        ])
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" && $0["annotations"]?["title"] != nil })
        #expect(tools.last?["annotations"]?["readOnlyHint"] == true)
    }
}
