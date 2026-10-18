import Foundation

/// Why a session ended.
public enum MCPSessionEnd: String, Sendable {
    case clientRequested = "client_requested"
    case idleTimeout = "idle_timeout"
    case capacityEvicted = "capacity_evicted"
    case serverShutdown = "server_shutdown"
    case tokenRevoked = "token_revoked"
    case disconnected = "disconnected"
}

/// A client's session, as the Activity window lists it.
public struct MCPSessionInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var tokenID: UUID
    public var tokenName: String
    public var tokenPrefix: String
    public var clientName: String
    public var clientVersion: String
    public var clientAddress: String
    public var protocolVersion: String
    public var createdAt: Date
    public var lastActivity: Date
}

/// The open sessions, by `Mcp-Session-Id`.
public actor MCPSessionStore {
    public struct Limits: Sendable {
        public var maxSessions: Int
        public var idleTimeout: TimeInterval
        public init(maxSessions: Int = 32, idleTimeout: TimeInterval = 30 * 60) {
            self.maxSessions = maxSessions
            self.idleTimeout = idleTimeout
        }
    }

    private struct Session {
        var info: MCPSessionInfo
        var running: [JSONValue: @Sendable () -> Void] = [:]
        var streams: [UUID: AsyncStream<SSEEvent>.Continuation] = [:]
    }

    public let limits: Limits
    private var sessions: [String: Session] = [:]
    private let onEnd: @Sendable (MCPSessionInfo, MCPSessionEnd) -> Void

    public init(limits: Limits = Limits(), onEnd: @escaping @Sendable (MCPSessionInfo, MCPSessionEnd) -> Void = { _, _ in }) {
        self.limits = limits
        self.onEnd = onEnd
    }

    public var all: [MCPSessionInfo] {
        sessions.values.map(\.info).sorted { $0.createdAt < $1.createdAt }
    }

    /// Starts a session for an initialize request; past the cap the least recently active goes.
    public func start(_ info: MCPSessionInfo) -> String {
        sweep()
        while sessions.count >= limits.maxSessions,
              let oldest = sessions.values.min(by: { $0.info.lastActivity < $1.info.lastActivity }) {
            end(oldest.info.id, .capacityEvicted)
        }
        var info = info
        info.id = MCPTokenStore.randomBase64URL(24)
        sessions[info.id] = Session(info: info)
        return info.id
    }

    /// The session, marked active; nil when it doesn't exist (or ended).
    public func touch(_ id: String) -> MCPSessionInfo? {
        sweep()
        guard sessions[id] != nil else { return nil }
        sessions[id]!.info.lastActivity = Date()
        return sessions[id]!.info
    }

    public func info(_ id: String) -> MCPSessionInfo? { sessions[id]?.info }

    public func setClient(_ id: String, name: String, version: String) {
        sessions[id]?.info.clientName = name
        sessions[id]?.info.clientVersion = version
    }

    /// Records a running request, so `notifications/cancelled` can stop it.
    public func register(_ request: JSONValue, cancel: @escaping @Sendable () -> Void, in id: String) {
        sessions[id]?.running[request] = cancel
    }

    public func finished(_ request: JSONValue, in id: String) {
        sessions[id]?.running[request] = nil
    }

    public func cancel(_ request: JSONValue, in id: String) {
        sessions[id]?.running[request]?()
    }

    /// A stream for GET's SSE: keep-alive comments only, as the server sends nothing unasked.
    public func openStream(in id: String) -> AsyncStream<SSEEvent>? {
        guard sessions[id] != nil else { return nil }
        let key = UUID()
        let (stream, continuation) = AsyncStream<SSEEvent>.makeStream()
        sessions[id]?.streams[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.closeStream(key, in: id) }
        }
        return stream
    }

    private func closeStream(_ key: UUID, in id: String) {
        sessions[id]?.streams[key] = nil
    }

    /// Sends a keep-alive comment on every open GET stream.
    public func keepAlive() {
        for session in sessions.values {
            for stream in session.streams.values { stream.yield(.comment("keep-alive")) }
        }
    }

    public func end(_ id: String, _ reason: MCPSessionEnd) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for cancel in session.running.values { cancel() }
        for stream in session.streams.values { stream.finish() }
        onEnd(session.info, reason)
    }

    public func end(token: UUID) {
        for (id, s) in sessions where s.info.tokenID == token { end(id, .tokenRevoked) }
    }

    public func endAll(_ reason: MCPSessionEnd) {
        for id in sessions.keys { end(id, reason) }
    }

    /// Ends sessions idle for longer than the limit.
    public func sweep(now: Date = Date()) {
        for (id, s) in sessions where now.timeIntervalSince(s.info.lastActivity) > limits.idleTimeout {
            end(id, .idleTimeout)
        }
    }
}

/// Counts failed sign-ins per client address; past the limit, requests are turned away for a while.
public actor MCPRateLimiter {
    public let limit: Int
    public let window: TimeInterval
    private var failures: [String: [Date]] = [:]

    public init(limit: Int = 10, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Seconds to wait before trying again, or nil when the address may try.
    public func retryAfter(_ address: String, now: Date = Date()) -> Int? {
        let recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < window }
        failures[address] = recent.isEmpty ? nil : recent
        guard recent.count >= limit, let oldest = recent.first else { return nil }
        return max(1, Int((window - now.timeIntervalSince(oldest)).rounded(.up)))
    }

    public func failed(_ address: String, now: Date = Date()) {
        failures[address, default: []].append(now)
    }
}

/// One server-sent event.
public enum SSEEvent: Sendable, Hashable {
    case message(id: String?, JSONValue)
    /// An event id with empty data, so a client could resume from it.
    case prime(id: String)
    case comment(String)

    public var text: String {
        switch self {
        case .message(let id, let value):
            (id.map { "id: \($0)\n" } ?? "") + "event: message\ndata: \(value.text)\n\n"
        case .prime(let id): "id: \(id)\ndata: \n\n"
        case .comment(let c): ": \(c)\n\n"
        }
    }
}
