import AppCore
import Foundation
import NIOSSL
import WireSupport

/// The MCP server as the app runs it: started and stopped from Settings ▸ MCP, with its tokens,
/// sessions, activity log and discovery file.
public final class MCPService: @unchecked Sendable {
    /// Posted (on any thread) when the server starts, stops or fails.
    public static let stateDidChange = Notification.Name("MCPService.stateDidChange")

    public static let defaultPort = AppSettings.defaultMCPPort
    /// Tried in turn when the preferred port is busy, before any free one.
    public static let fallbackPorts = defaultPort...(defaultPort + 96)
    /// Activity older than this goes at each start.
    public static let activityDays = 90

    public struct Options: Sendable, Hashable {
        public var port: Int
        /// Listen on every interface, over TLS.
        public var remote: Bool
        /// Make a token for moonrow-mcp and put it in the discovery file.
        public var autoToken: Bool
        /// The address to listen on; nil is 127.0.0.1, or every interface with `remote`.
        public var bindHost: String?

        public init(port: Int = MCPService.defaultPort, remote: Bool = false, autoToken: Bool = true, bindHost: String? = nil) {
            self.port = port
            self.remote = remote
            self.autoToken = autoToken
            self.bindHost = bindHost
        }
    }

    public enum State: Sendable, Hashable {
        case stopped
        case running(port: Int, tls: Bool, fingerprint: String?)
        case failed(String)
    }

    /// What `mcp-server.json` holds, for moonrow-mcp to find the server.
    public struct Discovery: Codable, Sendable, Hashable {
        public var port: Int
        public var pid: Int32
        public var protocolVersion: String
        public var tls: Bool
        public var tlsCertFingerprint: String?
        public var token: String?
    }

    public let directory: URL
    public let tokens: MCPTokenStore
    public let sessions: MCPSessionStore
    public let log: MCPActivityLog
    public let pairing = MCPPairing()
    let certificateStorage: any MCPTokenStorage
    let router: MCPRouter
    private let server: MCPHTTPServer
    private let lock = NSLock()
    private var current: State = .stopped
    /// The options the server is running with.
    private var running: Options?
    private var timer: Task<Void, Never>?
    /// Starts and stops run one at a time: at launch the settings and a client's `start-mcp`
    /// URL both ask for a start, and two at once would each bind a port and make a token.
    private let starting = AsyncLock()

    /// `directory` is the app's `MCP` folder: the discovery file and the activity log live there.
    public init(directory: URL, host: any MCPHost, tokens: MCPTokenStore, certificateStorage: any MCPTokenStorage, version: String) {
        self.directory = directory
        self.tokens = tokens
        self.certificateStorage = certificateStorage
        let log = MCPActivityLog(url: directory.appending(path: "activity.db"))
        self.log = log
        sessions = MCPSessionStore { info, reason in
            Task {
                await log.record(MCPActivity(
                    category: .system, client: info.clientName, clientAddress: info.clientAddress,
                    action: "session.end", status: .success, details: reason.rawValue).with(tokenOf: info))
            }
        }
        let dispatcher = MCPDispatcher(host: host, log: log, version: version)
        router = MCPRouter(tokens: tokens, sessions: sessions, dispatcher: dispatcher, pairing: pairing, log: log)
        server = MCPHTTPServer(router: router)
    }

    public var discoveryURL: URL { directory.appending(path: "mcp-server.json") }

    public var state: State { lock.withLock { current } }

    private func set(_ state: State) {
        lock.withLock { current = state }
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }

    /// Starts the server with `options`, or restarts it when it runs with others; one already
    /// running with them stays as it is.
    @discardableResult
    public func start(_ options: Options) async -> State {
        await starting.lock()
        let state = await startLocked(options)
        await starting.unlock()
        return state
    }

    private func startLocked(_ options: Options) async -> State {
        if case .running = state, lock.withLock({ running }) == options { return state }
        await stop(reason: .serverShutdown)
        do {
            var tls: NIOSSLContext?
            var fingerprint: String?
            if options.remote {
                let cert = try MCPTLS.certificate(storage: certificateStorage)
                tls = try MCPTLS.context(cert)
                fingerprint = cert.fingerprint
            }
            // Port 0 takes any free port at once (the tests' choice).
            let preferred = (0...65_535).contains(options.port) ? options.port : Self.defaultPort
            let ports = preferred == 0 ? [] : [preferred] + Self.fallbackPorts.filter { $0 != preferred }
            let port = try await server.start(host: options.bindHost ?? (options.remote ? "0.0.0.0" : "127.0.0.1"),
                                              ports: ports, tls: tls)
            try tokens.removeAutomatic()
            var secret: String?
            if options.autoToken {
                secret = try tokens.create(name: "moonrow-mcp", permission: .fullAccess, automatic: true).1
            }
            try writeDiscovery(Discovery(
                port: port, pid: ProcessInfo.processInfo.processIdentifier, protocolVersion: MCPDispatcher.latestProtocolVersion,
                tls: options.remote, tlsCertFingerprint: fingerprint, token: secret))
            _ = try? await log.clear(olderThan: Date().addingTimeInterval(-Double(Self.activityDays) * 86_400))
            await log.record(MCPActivity(category: .system, action: "server.start", status: .success,
                                         details: "Port \(port)" + (options.remote ? ", remote access over TLS" : "")))
            let sessions = self.sessions
            let timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    await sessions.keepAlive()
                    await sessions.sweep()
                }
            }
            lock.withLock {
                self.timer = timer
                running = options
            }
            let state = State.running(port: port, tls: options.remote, fingerprint: fingerprint)
            set(state)
            return state
        } catch {
            await server.stop()
            let state = State.failed(String(describing: error))
            await log.record(MCPActivity(category: .system, action: "server.start", status: .error, details: String(describing: error)))
            set(state)
            return state
        }
    }

    public func stop() async {
        await starting.lock()
        await stop(reason: .serverShutdown)
        set(.stopped)
        await starting.unlock()
    }

    /// Stops a running server; the state is `.stopped` from here (a failed one keeps its error
    /// until `stop()`), so nothing takes a server that's restarting for one that's up.
    private func stop(reason: MCPSessionEnd) async {
        let (timer, wasRunning) = lock.withLock { () -> (Task<Void, Never>?, Bool) in
            defer {
                self.timer = nil
                running = nil
            }
            let wasRunning = if case .running = current { true } else { false }
            return (self.timer, wasRunning)
        }
        timer?.cancel()
        if wasRunning { set(.stopped) }
        await sessions.endAll(reason)
        await server.stop()
        try? FileManager.default.removeItem(at: discoveryURL)
        if wasRunning { await log.record(MCPActivity(category: .system, action: "server.stop", status: .success)) }
    }

    /// Removes the discovery file at once, for quitting (where nothing can be awaited).
    public func removeDiscoveryFile() {
        try? FileManager.default.removeItem(at: discoveryURL)
    }

    private func writeDiscovery(_ d: Discovery) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Created owner-only before the token goes in.
        FileManager.default.createFile(atPath: discoveryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try encoder.encode(d).write(to: discoveryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryURL.path)
    }

    // MARK: - Tokens

    public func createToken(name: String, permission: MCPPermission, access: MCPConnectionAccess, client: String? = nil) async throws -> (MCPToken, String) {
        let made = try tokens.create(name: name, permission: permission, access: access, client: client)
        await log.record(MCPActivity(category: .auth, token: made.0, client: client, action: "token.created", status: .success,
                                     details: "\(permission.title), " + Self.describe(access)))
        return made
    }

    public func revokeToken(id: UUID) async throws {
        let token = tokens.token(id: id)
        try tokens.revoke(id: id)
        await sessions.end(token: id)
        await log.record(MCPActivity(category: .auth, token: token, action: "token.revoked", status: .success))
    }

    public func deleteToken(id: UUID) async throws {
        let token = tokens.token(id: id)
        try tokens.delete(id: id)
        await sessions.end(token: id)
        await log.record(MCPActivity(category: .auth, token: token, action: "token.deleted", status: .success))
    }

    /// Answers a pairing request the user allowed: the client's earlier tokens are revoked, a new
    /// one is made, and the URL to send the browser back to (with the one-time code) returned.
    public func approve(_ request: MCPPairingRequest) async throws -> URL {
        for t in tokens.tokens where t.client == request.client && t.isActive {
            try await revokeToken(id: t.id)
        }
        let (_, secret) = try await createToken(name: request.client, permission: request.permission, access: request.access,
                                                client: request.client)
        let code = await pairing.add(token: secret, challenge: request.codeChallenge)
        return request.redirect(code: code)
    }

    public func deny(_ request: MCPPairingRequest) async -> URL {
        await log.record(MCPActivity(category: .auth, client: request.client, action: "pairing.request", status: .denied))
        return request.redirect(code: nil)
    }

    public static func describe(_ access: MCPConnectionAccess) -> String {
        switch access {
        case .all: "all connections"
        case .only(let ids): ids.count == 1 ? "1 connection" : "\(ids.count) connections"
        }
    }

    /// Exports the certificate's PEM, making the certificate first if there's none.
    public func certificatePEM() throws -> String {
        try MCPTLS.certificate(storage: certificateStorage).certificatePEM
    }
}

extension MCPActivity {
    func with(tokenOf info: MCPSessionInfo) -> MCPActivity {
        var a = self
        a.tokenID = info.tokenID
        a.tokenName = info.tokenName
        a.tokenPrefix = info.tokenPrefix
        return a
    }
}
