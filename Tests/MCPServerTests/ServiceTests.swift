import AppCore
import CryptoKit
import Foundation
import Testing
@testable import MCPServer

/// The server on a socket: HTTP, the discovery file, TLS, and moonrow-mcp in front of it.
@Suite(.serialized) struct ServiceTests {
    private struct Running {
        let service: MCPService
        let dir: URL
        let config: ConnectionConfig
        let host: TestHost

        var discovery: MCPService.Discovery {
            get throws { try JSONDecoder().decode(MCPService.Discovery.self, from: Data(contentsOf: service.discoveryURL)) }
        }

        func stop() async {
            await service.stop()
            await host.closeAll()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func start(remote: Bool = false, autoToken: Bool = true) async throws -> Running {
        let dir = FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-service-\(UUID().uuidString)")
        let config = ConnectionConfig.sqliteFile(try await sampleDatabase())
        let host = TestHost([config], open: [config.id])
        let service = MCPService(directory: dir, host: host, tokens: try MCPTokenStore(storage: MemoryTokenStorage()),
                                 certificateStorage: FileTokenStorage(url: dir.appending(path: "cert.json")), version: "9.9")
        // Port 0 would do, but the real preferred-port path is what's tested: a free one near ours.
        let state = await service.start(.init(port: 0, remote: remote, autoToken: autoToken, bindHost: "127.0.0.1"))
        guard case .running = state else { throw MCPToolError("didn't start: \(state)") }
        return Running(service: service, dir: dir, config: config, host: host)
    }

    @Test func servesOverHTTP() async throws {
        let r = try await start()
        defer { Task { await r.stop() } }
        let d = try r.discovery
        #expect(d.pid == ProcessInfo.processInfo.processIdentifier && d.protocolVersion == "2025-11-25" && !d.tls)
        let token = try #require(d.token)
        #expect(r.service.tokens.tokens.filter(\.isAutomatic).map(\.name) == ["moonrow-mcp"])
        #expect((try FileManager.default.attributesOfItem(atPath: r.service.discoveryURL.path)[.posixPermissions] as? Int) == 0o600)

        let url = URL(string: "http://127.0.0.1:\(d.port)/mcp")!
        func post(_ body: JSONValue, session: String? = nil) async throws -> (JSONValue?, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data.isEmpty ? nil : try JSONValue.decode(data), response as! HTTPURLResponse)
        }
        let (initialize, response) = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "urlsession", "version": "1"],
        ]])
        #expect(initialize?["result"]?["serverInfo"]?["version"] == "9.9")
        let session = try #require(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (_, accepted) = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)
        #expect(accepted.statusCode == 202)
        let (call, _) = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "execute_read_query", "arguments": ["query": "SELECT name FROM items WHERE id = 2"],
        ]], session: session)
        #expect(call?["result"]?["structuredContent"]?["rows"] == [["name": "ink"]])
        // Progress comes as server-sent events over the socket too.
        var stream = URLRequest(url: url)
        stream.httpMethod = "POST"
        stream.httpBody = (["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "execute_read_query", "_meta": ["progressToken": 1], "arguments": ["query": "SELECT 1"],
        ]] as JSONValue).encoded()
        stream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        stream.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        stream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        stream.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        let (data, sse) = try await URLSession.shared.data(for: stream)
        #expect((sse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("notifications/progress") && text.contains("\"id\":3"))
        // A session the client ends is logged.
        var delete = URLRequest(url: url)
        delete.httpMethod = "DELETE"
        delete.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        delete.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        #expect((try await URLSession.shared.data(for: delete).1 as? HTTPURLResponse)?.statusCode == 200)
        try await Task.sleep(for: .milliseconds(100))
        let actions = try await r.service.log.entries().map(\.action)
        #expect(actions.contains("session.start") && actions.contains("session.end") && actions.contains("server.start"))

        await r.service.stop()
        #expect(!FileManager.default.fileExists(atPath: r.service.discoveryURL.path))
        #expect(r.service.state == .stopped)
    }

    @Test func busyPortFallsBack() async throws {
        let a = try await start()
        defer { Task { await a.stop() } }
        let taken = try a.discovery.port
        let b = MCPService(directory: a.dir.appending(path: "b"), host: a.host, tokens: try MCPTokenStore(storage: MemoryTokenStorage()),
                           certificateStorage: MemoryTokenStorage(), version: "1")
        guard case .running(let port, _, _) = await b.start(.init(port: taken, autoToken: false, bindHost: "127.0.0.1")) else {
            Issue.record("didn't start")
            return
        }
        #expect(port != taken)
        #expect(try JSONDecoder().decode(MCPService.Discovery.self, from: Data(contentsOf: b.discoveryURL)).token == nil)
        await b.stop()
    }

    @Test func servesOverTLSWithAPinnedCertificate() async throws {
        let r = try await start(remote: true)
        defer { Task { await r.stop() } }
        let d = try r.discovery
        #expect(d.tls)
        let fingerprint = try #require(d.tlsCertFingerprint)
        let pem = try r.service.certificatePEM()
        #expect(MCPTLS.fingerprint(pem: pem) == fingerprint)
        // The same certificate comes back until the addresses change.
        let storage = FileTokenStorage(url: r.dir.appending(path: "cert.json"))
        let cert = try MCPTLS.certificate(storage: storage)
        #expect(cert.fingerprint == fingerprint && cert.hosts.contains("localhost") && cert.hosts.contains("127.0.0.1"))
        #expect(try MCPTLS.certificate(storage: storage, hosts: cert.hosts + ["10.9.8.7"]).fingerprint != fingerprint)
        // It names the Mac's addresses too (no link-local zones), so remote clients can check them.
        let hosts = MCPTLS.hosts()
        #expect(Set(hosts).isSuperset(of: ["localhost", "127.0.0.1", "::1"]) && !hosts.contains { $0.contains("%") })
        #expect(hosts.count > 3, "the host name or a network address")

        final class Pin: NSObject, URLSessionDelegate, @unchecked Sendable {
            let expected: String
            init(_ e: String) { expected = e }
            func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
                -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return (.cancelAuthenticationChallenge, nil) }
                let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
                return actual == expected ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
            }
        }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(d.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = (["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]] as JSONValue).encoded()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(d.token ?? "")", forHTTPHeaderField: "Authorization")
        let pinned = URLSession(configuration: .ephemeral, delegate: Pin(fingerprint), delegateQueue: nil)
        let (data, response) = try await pinned.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONValue.decode(data)["result"]?["protocolVersion"] == "2025-11-25")
        // Without the pin the self-signed certificate isn't trusted.
        await #expect(throws: (any Error).self) { _ = try await URLSession(configuration: .ephemeral).data(for: request) }
        let wrong = URLSession(configuration: .ephemeral, delegate: Pin(String(repeating: "0", count: 64)), delegateQueue: nil)
        await #expect(throws: (any Error).self) { _ = try await wrong.data(for: request) }
    }

    // MARK: - moonrow-mcp

    /// The bridge `swift test` builds next to the test bundle.
    static var bridgePath: String {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let path = URL(filePath: bundle.bundlePath).deletingLastPathComponent().appending(path: "moonrow-mcp").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appending(path: ".build/debug/moonrow-mcp").path
    }

    /// moonrow-mcp as a client runs it: lines in, lines out.
    final class Bridge: @unchecked Sendable {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        private let lock = NSLock()
        private var lines: [String] = []
        private var buffer = Data()

        init(discovery: URL, environment: [String: String] = [:]) throws {
            process.executableURL = URL(fileURLWithPath: ServiceTests.bridgePath)
            process.environment = ["MOONROW_MCP_DISCOVERY": discovery.path, "MOONROW_MCP_NO_LAUNCH": "1", "MOONROW_MCP_WAIT": "1",
                                   "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                // At the end the handler would be called again and again.
                guard let self, !data.isEmpty else { h.readabilityHandler = nil; return }
                self.lock.withLock {
                    self.buffer.append(data)
                    while let i = self.buffer.firstIndex(of: 10) {
                        self.lines.append(String(decoding: self.buffer[..<i], as: UTF8.self))
                        self.buffer.removeSubrange(...i)
                    }
                }
            }
            try process.run()
        }

        func send(_ message: JSONValue) {
            input.fileHandleForWriting.write(message.encoded() + Data([10]))
        }

        /// The reply to request `id`, waiting up to `seconds`.
        func reply(_ id: JSONValue, seconds: Double = 10) async throws -> JSONValue {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let found = lock.withLock { lines.compactMap { try? JSONValue.decode(Data($0.utf8)) }.first { $0["id"] == id } }
                if let found { return found }
                try await Task.sleep(for: .milliseconds(50))
            }
            // Stopped first: reading the stderr of a bridge that's still running waits for it.
            process.terminate()
            _ = exited(within: 5)
            throw MCPToolError("no reply to \(id.text); stderr: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        var allLines: [String] { lock.withLock { lines } }

        func close() {
            try? input.fileHandleForWriting.close()
            // A bridge that doesn't stop at the end of its input fails the test instead of hanging it.
            if !exited(within: 10) {
                process.terminate()
                Issue.record("moonrow-mcp kept running after its input closed")
                _ = exited(within: 5)
            }
        }

        /// Whether the bridge has exited, waiting up to `seconds`. Not waitUntilExit, which runs the
        /// current thread's run loop and, on a concurrency thread, can miss the exit and wait forever.
        private func exited(within seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            return !process.isRunning
        }
    }

    @Test func bridgeForwardsAndRecovers() async throws {
        let r = try await start()
        defer { Task { await r.stop() } }
        let bridge = try Bridge(discovery: r.service.discoveryURL)
        bridge.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "bridge-test", "version": "1"],
        ]])
        #expect(try await bridge.reply(1)["result"]?["serverInfo"]?["name"] == "moonrow")
        bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        bridge.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "execute_read_query", "arguments": ["query": "SELECT count(*) AS n FROM items"],
        ]])
        #expect(try await bridge.reply(2)["result"]?["structuredContent"]?["rows"] == [["n": 3]])
        // Progress is passed on as it comes.
        bridge.send(["jsonrpc": "2.0", "id": "p", "method": "tools/call", "params": [
            "name": "execute_read_query", "_meta": ["progressToken": "t"], "arguments": ["query": "SELECT 1; SELECT 2"],
        ]])
        _ = try await bridge.reply("p")
        #expect(bridge.allLines.contains { $0.contains("notifications/progress") })
        #expect(await r.service.sessions.all.map(\.clientName) == ["bridge-test"])

        // The server restarts: a new port and a new token. The bridge finds it and starts a new
        // session with the client's initialize.
        await r.service.stop()
        guard case .running = await r.service.start(.init(port: 0, autoToken: true, bindHost: "127.0.0.1")) else {
            Issue.record("didn't restart")
            return
        }
        bridge.send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "execute_read_query", "arguments": ["query": "SELECT 'again' AS x"],
        ]])
        #expect(try await bridge.reply(3)["result"]?["structuredContent"]?["rows"] == [["x": "again"]])
        #expect(await r.service.sessions.all.map(\.clientName) == ["bridge-test"])

        // The app goes away: requests get an error, not silence.
        await r.service.stop()
        bridge.send(["jsonrpc": "2.0", "id": 4, "method": "ping"])
        let error = try await bridge.reply(4, seconds: 15)["error"]?["message"]?.string
        #expect(error?.contains("isn't running") == true)
        bridge.close()
        #expect(bridge.process.terminationStatus == 0)
        // Every line is one JSON-RPC message.
        #expect(bridge.allLines.allSatisfy { (try? JSONRPCMessage.parse(Data($0.utf8))) != nil })
    }

    @Test func bridgeUsesTheEnvironmentToken() async throws {
        let r = try await start(autoToken: false)
        defer { Task { await r.stop() } }
        #expect(try r.discovery.token == nil)
        let missing = try Bridge(discovery: r.service.discoveryURL)
        missing.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        #expect(try await missing.reply(1)["error"]?["message"]?.string?.contains("MOONROW_MCP_ACCESS_TOKEN") == true)
        missing.close()

        let (_, token) = try r.service.tokens.create(name: "env", permission: .readOnly)
        let bridge = try Bridge(discovery: r.service.discoveryURL, environment: ["MOONROW_MCP_ACCESS_TOKEN": token])
        bridge.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
        #expect(try await bridge.reply(1)["result"] != nil)
        bridge.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "execute_query", "arguments": ["query": "DELETE FROM items"],
        ]])
        #expect(try await bridge.reply(2)["result"]?["isError"] == true)
        bridge.close()
        // Closing stdin ends the session.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await r.service.sessions.all.isEmpty)
    }
}
