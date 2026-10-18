// moonrow-mcp: the stdio side of Moonrow's MCP server, for clients that start their servers as
// programs. It reads newline-delimited JSON-RPC on stdin, forwards each message to the app's
// Streamable HTTP endpoint and writes what comes back to stdout, one message per line.
//
// It finds the server through `MCP/mcp-server.json` in the app's folder (next to `MOONROW_STORE`'s
// file when that's set), starting the app when nothing is running. The token is
// `MOONROW_MCP_ACCESS_TOKEN`, else the one the app wrote into that file.

import CryptoKit
import Darwin
import Foundation

struct Discovery: Decodable {
    var port: Int
    var pid: Int32
    var protocolVersion: String
    var tls: Bool
    var tlsCertFingerprint: String?
    var token: String?
}

func log(_ text: String) {
    FileHandle.standardError.write(Data(("moonrow-mcp: " + text + "\n").utf8))
}

let environment = ProcessInfo.processInfo.environment

func discoveryURL() -> URL {
    if let path = environment["MOONROW_MCP_DISCOVERY"] { return URL(fileURLWithPath: path) }
    let root = environment["MOONROW_STORE"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Moonrow")
    return root.appending(path: "MCP/mcp-server.json")
}

/// The running server's file; nil when there's none or its app is gone.
func readDiscovery() -> Discovery? {
    guard let data = try? Data(contentsOf: discoveryURL()), let d = try? JSONDecoder().decode(Discovery.self, from: data) else { return nil }
    guard kill(d.pid, 0) == 0 || errno == EPERM else { return nil }
    return d
}

/// The server's file, starting the app (once) and waiting for it when there's none.
func findServer() async -> Discovery? {
    if let d = readDiscovery() { return d }
    if environment["MOONROW_MCP_NO_LAUNCH"] == nil {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "moonrow://integrations/start-mcp"]
        try? open.run()
        open.waitUntilExit()
    }
    let wait = Double(environment["MOONROW_MCP_WAIT"] ?? "") ?? 15
    let deadline = Date().addingTimeInterval(wait)
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(250))
        if let d = readDiscovery() { return d }
    }
    return nil
}

/// Accepts the server's self-signed certificate only when its SHA-256 is the one in the file.
final class Pinning: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?

    func pin(_ f: String?) { lock.withLock { fingerprint = f?.lowercased() } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let expected = lock.withLock({ fingerprint }) else { return (.cancelAuthenticationChallenge, nil) }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return actual == expected ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

enum ForwardError: Error {
    /// The session or the token is no longer good, or the server went away: find it again.
    case lost(String)
    case failed(String)
}

actor Bridge {
    let pinning = Pinning()
    let urlSession: URLSession
    var server: Discovery?
    var sessionID: String?
    var protocolVersion: String?
    var initialize: Data?
    var initialized: Data?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
    }

    var token: String? { environment["MOONROW_MCP_ACCESS_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } ?? server?.token }

    /// Sends one message from the client; returns the messages to write back.
    func forward(_ line: Data) async -> [Data] {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let method = object?["method"] as? String
        let id = object?["id"]
        if method == "initialize" {
            initialize = line
            sessionID = nil
        } else if method == "notifications/initialized" {
            initialized = line
        }
        for attempt in 0..<2 {
            do {
                if server == nil || attempt > 0 {
                    server = await findServer()
                    pinning.pin(server?.tlsCertFingerprint)
                    if attempt > 0 { sessionID = nil }
                }
                guard server != nil else { throw ForwardError.failed("Moonrow's MCP server isn't running. Turn it on in Moonrow's Settings ▸ MCP.") }
                guard token != nil else { throw ForwardError.failed("No access token: set MOONROW_MCP_ACCESS_TOKEN, or turn on Auto-generate in Moonrow's Settings ▸ MCP.") }
                if method != "initialize", sessionID == nil, initialize != nil { try await replay() }
                return try await post(line)
            } catch ForwardError.lost(let why) where attempt == 0 {
                log("reconnecting: \(why)")
                continue
            } catch ForwardError.lost(let why), ForwardError.failed(let why) {
                return id.map { [errorReply(id: $0, message: why)] } ?? []
            } catch {
                return id.map { [errorReply(id: $0, message: error.localizedDescription)] } ?? []
            }
        }
        return []
    }

    /// Starts a new session with the client's own initialize and initialized.
    private func replay() async throws {
        guard let initialize else { return }
        _ = try await post(initialize)
        if let initialized { _ = try await post(initialized) }
    }

    private func post(_ body: Data) async throws -> [Data] {
        guard let server, let token else { throw ForwardError.failed("No server") }
        var request = URLRequest(url: URL(string: "\(server.tls ? "https" : "http")://127.0.0.1:\(server.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw ForwardError.lost(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ForwardError.lost("no response") }
        if http.statusCode == 404 || http.statusCode == 401 { throw ForwardError.lost("HTTP \(http.statusCode)") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        if let v = http.value(forHTTPHeaderField: "MCP-Protocol-Version") { protocolVersion = v }
        if http.statusCode == 202 { return [] }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/event-stream") {
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if line.isEmpty || line.hasPrefix("id:") || line.hasPrefix("event:") {
                    // `lines` drops the blank line that ends an event, so an event ends at the next field too.
                    if !data.isEmpty { await emit(Data(data.utf8)); data = "" }
                }
            }
            if !data.isEmpty { await emit(Data(data.utf8)) }
            return []
        }
        var reply = Data()
        for try await byte in bytes { reply.append(byte) }
        if (200..<300).contains(http.statusCode) { return reply.isEmpty ? [] : [reply] }
        // An HTTP error's JSON-RPC body has no id; a request gets its own back.
        let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard let id = sent?["id"] else { return [] }
        let error = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["error"] as? [String: Any]
        return [errorReply(id: id, message: error?["message"] as? String ?? "HTTP \(http.statusCode)")]
    }

    /// Messages written as they arrive (a stream's progress, before the result).
    private func emit(_ message: Data) async {
        await Output.shared.write(message)
    }

    private func errorReply(id: Any, message: String) -> Data {
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
    }

    func ping() async {
        guard sessionID != nil else { return }
        _ = try? await post(Data(#"{"jsonrpc":"2.0","id":"moonrow-bridge-keepalive","method":"ping"}"#.utf8))
    }

    func close() async {
        guard let server, let token, let sessionID else { return }
        var request = URLRequest(url: URL(string: "\(server.tls ? "https" : "http")://127.0.0.1:\(server.port)/mcp")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.timeoutInterval = 2
        _ = try? await urlSession.data(for: request)
    }
}

/// stdout, one message per line, never interleaved.
actor Output {
    static let shared = Output()

    func write(_ message: Data) {
        // The keep-alive's answer is the bridge's own.
        if let o = try? JSONSerialization.jsonObject(with: message) as? [String: Any], o["id"] as? String == "moonrow-bridge-keepalive" {
            return
        }
        let line = String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

let bridge = Bridge()
let keepAlive = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await bridge.ping()
    }
}

// Messages are forwarded as they come, each on its own, and a forward is let go once it's
// written; initialize finishes before anything else is sent, so the session exists for it.
try await withThrowingDiscardingTaskGroup { group in
    for try await line in FileHandle.standardInput.bytes.lines {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        let data = Data(text.utf8)
        if text.contains("\"initialize\"") {
            for reply in await bridge.forward(data) { await Output.shared.write(reply) }
        } else {
            group.addTask { for reply in await bridge.forward(data) { await Output.shared.write(reply) } }
        }
    }
}
keepAlive.cancel()
await bridge.close()
