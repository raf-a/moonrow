import Foundation

public struct MCPHTTPRequest: Sendable {
    public var method: String
    /// The path, without the query.
    public var path: String
    public var headers: [(String, String)]
    public var body: Data
    public var clientAddress: String

    public init(method: String, path: String, headers: [(String, String)], body: Data = Data(), clientAddress: String = "127.0.0.1") {
        self.method = method.uppercased()
        self.path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        self.headers = headers
        self.body = body
        self.clientAddress = clientAddress
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

public struct MCPHTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// Server-sent events, until the stream ends.
        case events(AsyncStream<SSEEvent>)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    var data: Data? {
        if case .data(let d) = body { return d }
        return nil
    }

    static func json(_ status: Int, _ value: JSONValue, headers: [(String, String)] = []) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: .data(value.encoded()))
    }

    /// A JSON-RPC error without an id, as the transport's errors carry.
    static func rpcError(_ status: Int, _ message: String, code: Int = -32600, headers: [(String, String)] = []) -> MCPHTTPResponse {
        json(status, JSONRPCMessage.error(nil, JSONRPCError(code: code, message: message)).json, headers: headers)
    }
}

/// Streamable HTTP: `/mcp` (POST, GET, DELETE), the pairing exchange, CORS and auth.
public final class MCPRouter: Sendable {
    public static let realm = "Moonrow MCP"
    /// POST bodies larger than this are turned away.
    public static let maxBody = 8 << 20

    let tokens: MCPTokenStore
    let sessions: MCPSessionStore
    let limiter: MCPRateLimiter
    let dispatcher: MCPDispatcher
    let pairing: MCPPairing
    let log: MCPActivityLog?

    public init(tokens: MCPTokenStore, sessions: MCPSessionStore, limiter: MCPRateLimiter = MCPRateLimiter(),
                dispatcher: MCPDispatcher, pairing: MCPPairing, log: MCPActivityLog?) {
        self.tokens = tokens
        self.sessions = sessions
        self.limiter = limiter
        self.dispatcher = dispatcher
        self.pairing = pairing
        self.log = log
    }

    public func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        let origin = request.header("Origin")
        if let origin, !Self.isLocalOrigin(origin) {
            return .rpcError(403, "Forbidden origin: \(origin)")
        }
        var response = await route(request)
        if let origin {
            response.headers += [
                ("Access-Control-Allow-Origin", origin), ("Vary", "Origin"),
                ("Access-Control-Expose-Headers", "Mcp-Session-Id, MCP-Protocol-Version, WWW-Authenticate"),
            ]
        }
        return response
    }

    private func route(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        if request.method == "OPTIONS" {
            return MCPHTTPResponse(status: 204, headers: [
                ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
                ("Access-Control-Allow-Headers", "Authorization, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID"),
                ("Access-Control-Max-Age", "600"),
            ])
        }
        switch request.path {
        case "/mcp", "/mcp/":
            break
        case "/v1/integrations/exchange":
            return await exchange(request)
        default:
            return .rpcError(404, "Not found")
        }
        guard let token = tokens.verify(Self.bearer(request)) else {
            // Every local client arrives from 127.0.0.1, so a valid token is never held up by
            // another client's failures; past the limit, the failing ones are turned away.
            if let wait = await limiter.retryAfter(request.clientAddress) {
                return .rpcError(429, "Too many failed attempts", headers: [("Retry-After", String(wait))])
            }
            await authenticationFailed(request)
            return .rpcError(401, "Unauthorized", code: -32001, headers: [
                ("WWW-Authenticate", "Bearer realm=\"\(Self.realm)\", error=\"invalid_token\""),
            ])
        }
        switch request.method {
        case "POST": return await post(request, token: token)
        case "GET": return await get(request, token: token)
        case "DELETE":
            guard let id = request.header("Mcp-Session-Id") else { return .rpcError(400, "Missing Mcp-Session-Id") }
            guard let info = await sessions.info(id), info.tokenID == token.id else { return .rpcError(404, "Session not found") }
            await sessions.end(id, .clientRequested)
            return MCPHTTPResponse(status: 200)
        default:
            return MCPHTTPResponse(status: 405, headers: [("Allow", "GET, POST, DELETE, OPTIONS")])
        }
    }

    /// `http(s)://localhost`, `127.0.0.1` or `[::1]`, any port. Anything else may be a web page
    /// reaching the server through DNS rebinding.
    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let u = URLComponents(string: origin), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// The bearer token in the request, or "" without one.
    private static func bearer(_ request: MCPHTTPRequest) -> String {
        let header = request.header("Authorization") ?? ""
        let parts = header.split(separator: " ", maxSplits: 1)
        return parts.count == 2 && parts[0].lowercased() == "bearer" ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    }

    /// Counts a request without a usable token against its address and logs it.
    private func authenticationFailed(_ request: MCPHTTPRequest) async {
        let secret = Self.bearer(request)
        await limiter.failed(request.clientAddress)
        let prefix = secret.isEmpty ? nil : String(secret.prefix(MCPTokenStore.tokenPrefix.count + 6))
        await log?.record(MCPActivity(
            category: .auth, clientAddress: request.clientAddress, action: "auth.failed", status: .denied,
            details: secret.isEmpty ? "No token" : "Unknown or revoked token \(prefix ?? "")"))
    }

    // MARK: - POST

    private func post(_ request: MCPHTTPRequest, token: MCPToken) async -> MCPHTTPResponse {
        let type = request.header("Content-Type")?.lowercased() ?? ""
        guard type.hasPrefix("application/json") else { return .rpcError(415, "Content-Type must be application/json") }
        let accept = request.header("Accept")?.lowercased() ?? "*/*"
        let acceptsJSON = accept.contains("application/json") || accept.contains("*/*")
        let acceptsEvents = accept.contains("text/event-stream") || accept.contains("*/*")
        guard acceptsJSON || acceptsEvents else { return .rpcError(406, "Accept must include application/json or text/event-stream") }
        guard request.body.count <= Self.maxBody else { return .rpcError(413, "Request too large") }
        let message: JSONRPCMessage
        do { message = try JSONRPCMessage.parse(request.body) } catch {
            return .json(400, JSONRPCMessage.error(nil, error).json)
        }
        if case .request(let id, "initialize", let params) = message {
            return await initialize(id: id, params: params, request: request, token: token)
        }
        guard let sessionID = request.header("Mcp-Session-Id") else { return .rpcError(400, "Missing Mcp-Session-Id") }
        guard let session = await sessions.touch(sessionID), session.tokenID == token.id else {
            return .rpcError(404, "Session not found")
        }
        if let version = request.header("MCP-Protocol-Version"), !MCPDispatcher.protocolVersions.contains(version) {
            return .rpcError(400, "Unsupported MCP-Protocol-Version: \(version)")
        }
        switch message {
        case .notification(let method, let params):
            if method == "notifications/cancelled", let id = params?["requestId"] {
                await sessions.cancel(id, in: sessionID)
            }
            return MCPHTTPResponse(status: 202)
        case .response:
            return MCPHTTPResponse(status: 202)
        case .request(let id, let method, let params):
            let caller = MCPDispatcher.Caller(token: token, session: session, clientAddress: request.clientAddress)
            let progressToken = params?["_meta"]?["progressToken"]
            if let progressToken, acceptsEvents {
                return await streamed(id: id, method: method, params: params, caller: caller, progressToken: progressToken, sessionID: sessionID)
            }
            let reply = await run(id: id, method: method, params: params, caller: caller, sessionID: sessionID, progress: nil)
            return .json(200, reply.json)
        }
    }

    private func initialize(id: JSONValue, params: JSONValue?, request: MCPHTTPRequest, token: MCPToken) async -> MCPHTTPResponse {
        let client = params?["clientInfo"]
        let requested = params?["protocolVersion"]?.string
        let version = MCPDispatcher.negotiate(requested)
        let info = MCPSessionInfo(
            id: "", tokenID: token.id, tokenName: token.name, tokenPrefix: token.prefix,
            clientName: client?["name"]?.string ?? "", clientVersion: client?["version"]?.string ?? "",
            clientAddress: request.clientAddress, protocolVersion: version, createdAt: Date(), lastActivity: Date())
        let sessionID = await sessions.start(info)
        await log?.record(MCPActivity(
            category: .system, token: token, client: info.clientName, clientAddress: request.clientAddress,
            action: "session.start", status: .success,
            details: "\(info.clientName) \(info.clientVersion), protocol \(version)".trimmingCharacters(in: .whitespaces)))
        let reply = JSONRPCMessage.result(id, dispatcher.initializeResult(requested: requested))
        return .json(200, reply.json, headers: [("Mcp-Session-Id", sessionID), ("MCP-Protocol-Version", version)])
    }

    /// Runs a request as a task the session can cancel.
    private func run(id: JSONValue, method: String, params: JSONValue?, caller: MCPDispatcher.Caller, sessionID: String,
                     progress: (@Sendable (Double, Double?, String) -> Void)?) async -> JSONRPCMessage {
        let dispatcher = self.dispatcher
        let task = Task { () -> JSONRPCMessage in
            do throws(JSONRPCError) {
                return .result(id, try await dispatcher.handle(method: method, params: params, caller: caller, progress: progress))
            } catch {
                return .error(id, error)
            }
        }
        await sessions.register(id, cancel: { task.cancel() }, in: sessionID)
        let reply = await task.value
        await sessions.finished(id, in: sessionID)
        return reply
    }

    private func streamed(id: JSONValue, method: String, params: JSONValue?, caller: MCPDispatcher.Caller,
                          progressToken: JSONValue, sessionID: String) async -> MCPHTTPResponse {
        let (stream, continuation) = AsyncStream<SSEEvent>.makeStream()
        let streamID = MCPTokenStore.randomBase64URL(9)
        let counter = Counter()
        continuation.yield(.prime(id: "\(streamID)-0"))
        let progress: @Sendable (Double, Double?, String) -> Void = { done, total, message in
            var p: [String: JSONValue] = ["progressToken": progressToken, "progress": .double(done), "message": .string(message)]
            if let total { p["total"] = .double(total) }
            continuation.yield(.message(id: "\(streamID)-\(counter.next())",
                                        JSONRPCMessage.notification(method: "notifications/progress", params: .object(p)).json))
        }
        Task {
            let reply = await run(id: id, method: method, params: params, caller: caller, sessionID: sessionID, progress: progress)
            continuation.yield(.message(id: "\(streamID)-\(counter.next())", reply.json))
            continuation.finish()
        }
        return MCPHTTPResponse(status: 200, headers: [
            ("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache"),
        ], body: .events(stream))
    }

    // MARK: - GET

    private func get(_ request: MCPHTTPRequest, token: MCPToken) async -> MCPHTTPResponse {
        let accept = request.header("Accept")?.lowercased() ?? ""
        guard accept.contains("text/event-stream") else {
            return MCPHTTPResponse(status: 405, headers: [("Allow", "POST, DELETE, OPTIONS")])
        }
        if request.header("Last-Event-ID") != nil { return .rpcError(501, "Resuming streams isn't supported") }
        guard let sessionID = request.header("Mcp-Session-Id") else { return .rpcError(400, "Missing Mcp-Session-Id") }
        guard let session = await sessions.touch(sessionID), session.tokenID == token.id,
              let stream = await sessions.openStream(in: sessionID) else { return .rpcError(404, "Session not found") }
        return MCPHTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
                               body: .events(stream))
    }

    // MARK: - Pairing

    private func exchange(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.method == "POST" else { return MCPHTTPResponse(status: 405, headers: [("Allow", "POST, OPTIONS")]) }
        if let wait = await limiter.retryAfter(request.clientAddress) {
            return .rpcError(429, "Too many failed attempts", headers: [("Retry-After", String(wait))])
        }
        guard let body = try? JSONValue.decode(request.body), let code = body["code"]?.string,
              let verifier = body["code_verifier"]?.string else {
            return .json(400, ["error": "code and code_verifier are required"])
        }
        do {
            let token = try await pairing.exchange(code: code, verifier: verifier)
            let record = tokens.verify(token)
            await log?.record(MCPActivity(category: .auth, token: record, client: record?.client, clientAddress: request.clientAddress,
                                          action: "pairing.exchange", status: .success))
            return .json(200, ["token": .string(token)])
        } catch {
            await limiter.failed(request.clientAddress)
            await log?.record(MCPActivity(category: .auth, clientAddress: request.clientAddress, action: "pairing.exchange",
                                          status: .denied, details: error.errorDescription))
            return .json(400, ["error": .string(error.errorDescription ?? "")])
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
