import Foundation
import Testing
@testable import MCPServer

/// Tokens, pairing and the activity log.
@Suite struct TokenTests {
    @Test func tokensAreHashedAndReloaded() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-tokens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let store = try MCPTokenStore(storage: FileTokenStorage(url: url))
        let (record, secret) = try store.create(name: "Agent", permission: .readWrite, access: .only([id]))
        #expect(secret.hasPrefix("mr_") && secret.count == 3 + 43)
        #expect(record.prefix == String(secret.prefix(9)))
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains(secret) && !file.contains(String(secret.dropFirst(9))))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)

        let reloaded = try MCPTokenStore(storage: FileTokenStorage(url: url))
        let found = try #require(reloaded.verify(secret))
        #expect(found.id == record.id && found.permission == .readWrite && found.access == .only([id]))
        #expect(found.lastUsedAt != nil)
        #expect(reloaded.verify(secret + "x") == nil && reloaded.verify("") == nil)

        try reloaded.forget(connection: id)
        #expect(reloaded.token(id: record.id)?.access == .only([]))
        try reloaded.revoke(id: record.id)
        #expect(reloaded.verify(secret) == nil && reloaded.token(id: record.id)?.status == "Revoked")
        try reloaded.delete(id: record.id)
        #expect(reloaded.tokens.isEmpty)
        // Records that can't be read are an error, never replaced by none.
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try MCPTokenStore(storage: FileTokenStorage(url: url)) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test func permissionsAndAutomaticTokens() throws {
        #expect(MCPPermission.readOnly.scopes == [.toolsRead, .resourcesRead])
        #expect(MCPPermission.readWrite.scopes.contains(.toolsWrite) && !MCPPermission.readWrite.scopes.contains(.toolsControl))
        #expect(MCPPermission.fullAccess.scopes == Set(MCPScope.allCases))
        #expect(MCPPermission(requested: "write") == .readWrite && MCPPermission(requested: "nope") == nil)
        let store = try MCPTokenStore(storage: MemoryTokenStorage())
        try store.create(name: "auto", permission: .fullAccess, automatic: true)
        try store.create(name: "mine", permission: .readOnly)
        try store.removeAutomatic()
        #expect(store.tokens.map(\.name) == ["mine"])
    }

    @Test func pairingRequests() throws {
        let challenge = MCPPairing.challenge(for: String(repeating: "v", count: 50))
        let ok = try MCPPairingRequest(url: URL(string:
            "moonrow://integrations/pair?client=Raycast&permission=write&redirect_uri=raycast://oauth&code_challenge=\(challenge)&code_challenge_method=S256&state=xyz")!)
        #expect(ok.client == "Raycast" && ok.permission == .readWrite && ok.access == .all && ok.state == "xyz")
        #expect(ok.redirect(code: "abc").absoluteString == "raycast://oauth?code=abc&state=xyz")
        #expect(ok.redirect(code: nil).absoluteString == "raycast://oauth?error=user_denied&state=xyz")
        #expect(ok.describe(connectionNames: []) == "Read & Write access to all connections")
        let id = UUID()
        let one = try MCPPairingRequest(url: URL(string:
            "moonrow://integrations/pair?client=App&connections=\(id.uuidString)&redirect_uri=http://127.0.0.1:9000/cb&code_challenge=\(challenge)")!)
        #expect(one.permission == .readOnly && one.access == .only([id]))
        #expect(one.describe(connectionNames: ["Shop"]) == "Read Only access to “Shop”")

        func fails(_ query: String) -> Bool {
            (try? MCPPairingRequest(url: URL(string: "moonrow://integrations/pair?" + query)!)) == nil
        }
        #expect(fails("redirect_uri=app://cb&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=https://evil.example/cb&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=javascript:alert(1)&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=file:///tmp/x&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=shortcuts://run-shortcut&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=ssh://evil.example&code_challenge=\(challenge)"))
        #expect(fails("client=A&redirect_uri=x-apple.systempreferences:com.apple.preference&code_challenge=\(challenge)"))
        #expect(MCPPairingRequest.isLoopback(URL(string: "http://localhost:3000/cb")!))
        #expect(!MCPPairingRequest.isLoopback(URL(string: "raycast://oauth")!))
        #expect(fails("client=A&redirect_uri=app://cb&code_challenge=short"))
        #expect(fails("client=A&redirect_uri=app://cb&code_challenge=\(challenge)&code_challenge_method=plain"))
        #expect(fails("client=A&redirect_uri=app://cb&code_challenge=\(challenge)&connections=nope"))
        #expect(fails("client=A&redirect_uri=app://cb&code_challenge=\(challenge)&permission=root"))
    }

    @Test func pairingExchange() async throws {
        let pairing = MCPPairing()
        let verifier = "a-verifier-long-enough-to-be-real-0123456789"
        let code = await pairing.add(token: "mr_secret", challenge: MCPPairing.challenge(for: verifier))
        await #expect(throws: MCPPairing.ExchangeError.challengeMismatch) { try await pairing.exchange(code: code, verifier: "other") }
        // A code is good once, whatever happened.
        await #expect(throws: MCPPairing.ExchangeError.notFound) { try await pairing.exchange(code: code, verifier: verifier) }
        let code2 = await pairing.add(token: "mr_secret", challenge: MCPPairing.challenge(for: verifier))
        #expect(try await pairing.exchange(code: code2, verifier: verifier) == "mr_secret")
        let old = await pairing.add(token: "t", challenge: "c", now: Date().addingTimeInterval(-MCPPairing.lifetime - 1))
        await #expect(throws: MCPPairing.ExchangeError.expired) { try await pairing.exchange(code: old, verifier: "x") }
        // At most so many wait.
        var codes: [String] = []
        for _ in 0..<(MCPPairing.maxPending + 2) { codes.append(await pairing.add(token: "t", challenge: "c")) }
        await #expect(throws: MCPPairing.ExchangeError.notFound) { try await pairing.exchange(code: codes[0], verifier: "x") }
        // RFC 7636's example.
        #expect(MCPPairing.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pairingThroughTheService() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-pair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MCPService(directory: dir, host: TestHost([]), tokens: try MCPTokenStore(storage: MemoryTokenStorage()),
                                 certificateStorage: MemoryTokenStorage(), version: "test")
        let verifier = "verifier-verifier-verifier-verifier-verifier"
        let request = try MCPPairingRequest(url: URL(string:
            "moonrow://integrations/pair?client=Tool&permission=read&redirect_uri=tool://cb&code_challenge=\(MCPPairing.challenge(for: verifier))")!)
        let first = try await service.approve(request)
        let second = try await service.approve(request)
        // Pairing again revokes the client's earlier token.
        #expect(service.tokens.tokens.filter { $0.client == "Tool" }.map(\.isActive) == [false, true])
        let code = try #require(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value)
        let exchange = await service.router.handle(MCPHTTPRequest(method: "POST", path: "/v1/integrations/exchange", headers: [
            ("Content-Type", "application/json"),
        ], body: (["code": .string(code), "code_verifier": .string(verifier)] as JSONValue).encoded()))
        #expect(exchange.status == 200)
        let token = try #require(exchange.json?["token"]?.string)
        #expect(service.tokens.verify(token)?.permission == .readOnly)
        let again = await service.router.handle(MCPHTTPRequest(method: "POST", path: "/v1/integrations/exchange", headers: [],
            body: (["code": .string(code), "code_verifier": .string(verifier)] as JSONValue).encoded()))
        #expect(again.status == 400 && again.json?["error"] == "Pairing code not found")
        _ = first
        #expect(await service.deny(request).absoluteString == "tool://cb?error=user_denied")
    }

    @Test func activityLog() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-activity-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = MCPActivityLog(url: url)
        let store = try MCPTokenStore(storage: MemoryTokenStorage())
        let (token, _) = try store.create(name: "Agent", permission: .readOnly)
        let old = Date().addingTimeInterval(-10 * 86_400)
        await log.record(MCPActivity(timestamp: old, category: .auth, action: "token.created", status: .success))
        await log.record(MCPActivity(category: .query, token: token, client: "Claude", clientAddress: "127.0.0.1",
                                     action: "tool.execute_query", status: .denied, query: "DELETE FROM a, b", details: "said \"no\""))
        let all = try await log.entries()
        #expect(all.map(\.action) == ["tool.execute_query", "token.created"])
        #expect(all[0].tokenName == "Agent" && all[0].tokenPrefix == token.prefix && all[0].client == "Claude")
        #expect(try await log.entries(.init(since: Date().addingTimeInterval(-60))).count == 1)
        #expect(try await log.entries(.init(tokenID: token.id)).count == 1)
        #expect(try await log.entries(.init(search: "delete")).count == 1)
        #expect(try await log.entries(.init(search: "100%")).isEmpty)
        let csv = MCPActivityLog.csv(all)
        #expect(csv.hasPrefix("Time,Status,Category,Action,Token,"))
        #expect(csv.contains(",denied,query,tool.execute_query,Agent,") && csv.contains("\"DELETE FROM a, b\",\"said \"\"no\"\"\""))
        #expect(try await log.clear(olderThan: Date().addingTimeInterval(-86_400)) == 1)
        #expect(try await log.entries().count == 1)
        await log.close()
    }
}
