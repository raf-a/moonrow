import AppCore
import DBKit
import DriverSQLite
import Foundation
@testable import MCPServer

/// The app's side, as the tests play it: saved connections, the open ones, and what the
/// approval and safe mode answer.
final class TestHost: MCPHost, @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [ConnectionConfig]
    private var passwords: [UUID: String] = [:]
    private var openIDs: Set<UUID> = []
    private var sessions: [UUID: MCPQuerySession] = [:]
    private var _authorization: MCPAuthorization = .allowed
    private var _requests: [MCPStatementRequest] = []
    private var _ran: [UUID: [MCPRanStatement]] = [:]
    var historyEntries: [UUID: [QueryHistory.Entry]] = [:]
    var saved: [UUID: [MCPSavedQuery]] = [:]
    /// The database "the workspace is in", when not the one the session opened in.
    var workspaceDatabases: [UUID: String] = [:]

    init(_ configs: [ConnectionConfig], open: Set<UUID> = []) {
        self.configs = configs
        openIDs = open
    }

    var authorization: MCPAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }

    var requests: [MCPStatementRequest] { lock.withLock { _requests } }
    func ran(_ id: UUID) -> [MCPRanStatement] { lock.withLock { _ran[id] ?? [] } }
    func setPassword(_ p: String?, for id: UUID) { lock.withLock { passwords[id] = p } }
    func setOpen(_ id: UUID) { lock.withLock { _ = openIDs.insert(id) } }

    func savedConnections() async -> [MCPConnectionSummary] {
        lock.withLock { configs }.map { MCPConnectionSummary($0, tag: nil) }
    }

    func openConnections() async -> [MCPOpenConnection] {
        let open = lock.withLock { configs.filter { openIDs.contains($0.id) } }
        return open.map { MCPOpenConnection(summary: MCPConnectionSummary($0, tag: nil), currentDatabase: $0.driver.isServer ? $0.database : "main") }
    }

    func open(_ id: UUID, database: String?, tabbed: Bool) async throws -> MCPOpenConnection {
        let config: ConnectionConfig? = lock.withLock {
            openIDs.insert(id)
            return configs.first { $0.id == id }
        }
        guard let config else { throw MCPToolError("No such connection") }
        return MCPOpenConnection(summary: MCPConnectionSummary(config, tag: nil), currentDatabase: database ?? config.database)
    }

    func disconnect(_ id: UUID, database: String?) async throws -> Int {
        let session: MCPQuerySession? = lock.withLock {
            openIDs.remove(id)
            return sessions.removeValue(forKey: id)
        }
        await session?.connection.close()
        return session == nil ? 0 : 1
    }

    func querySession(for id: UUID) async throws -> MCPQuerySession {
        let (config, existing, password, workspace): (ConnectionConfig?, MCPQuerySession?, String?, String?) = lock.withLock {
            (configs.first { $0.id == id && openIDs.contains(id) }, sessions[id], passwords[id], workspaceDatabases[id])
        }
        if var existing {
            existing.workspaceDatabase = workspace ?? existing.database
            return existing
        }
        guard let config else { throw MCPToolError("The connection isn't open; call open_connection first.") }
        let connection = try await ConnectionFactory.open(config, password: password)
        let opened = config.driver.isServer && !config.database.isEmpty ? config.database : nil
        let session = MCPQuerySession(id: UUID(), connection: connection, config: config, database: opened,
                                      workspaceDatabase: workspace ?? opened)
        lock.withLock { sessions[id] = session }
        return session
    }

    func authorize(_ request: MCPStatementRequest) async -> MCPAuthorization {
        lock.withLock {
            _requests.append(request)
            return _authorization
        }
    }

    func didRun(_ statements: [MCPRanStatement], on id: UUID) async {
        lock.withLock { _ran[id, default: []] += statements }
    }

    func history(for id: UUID) async -> [QueryHistory.Entry] { lock.withLock { historyEntries[id] ?? [] } }
    func savedQueries(for id: UUID) async -> [MCPSavedQuery] { lock.withLock { saved[id] ?? [] } }

    func closeAll() async {
        let all = lock.withLock { () -> [MCPQuerySession] in
            defer { sessions = [:] }
            return Array(sessions.values)
        }
        for s in all { await s.connection.close() }
    }
}

/// A SQLite file with a table of every kind of value.
func sampleDatabase(rows: Int = 3) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-\(UUID().uuidString).sqlite")
    let db = try SQLiteConnection(path: url.path)
    _ = try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, price REAL, data BLOB, note TEXT)")
    _ = try await db.execute("INSERT INTO items VALUES (1, 'pen', 1.5, x'00ff', NULL), (2, 'ink', 3.25, NULL, 'blue'), (3, 'pad', 2, NULL, NULL)")
    if rows > 3 {
        _ = try await db.execute("WITH RECURSIVE n(x) AS (SELECT 4 UNION ALL SELECT x + 1 FROM n WHERE x < \(rows)) INSERT INTO items (id, name) SELECT x, 'item ' || x FROM n")
    }
    await db.close()
    return url
}

/// A router over a host, with a token store in memory, for driving the protocol without a socket.
struct Harness {
    let host: TestHost
    let tokens: MCPTokenStore
    let sessions: MCPSessionStore
    let router: MCPRouter
    let log: MCPActivityLog
    let pairing = MCPPairing()

    init(host: TestHost, limiter: MCPRateLimiter = MCPRateLimiter(), limits: MCPSessionStore.Limits = .init()) throws {
        self.host = host
        tokens = try MCPTokenStore(storage: MemoryTokenStorage())
        sessions = MCPSessionStore(limits: limits)
        log = MCPActivityLog(url: FileManager.default.temporaryDirectory.appending(path: "moonrow-mcp-activity-\(UUID().uuidString).db"))
        let dispatcher = MCPDispatcher(host: host, log: log, version: "1.0-test")
        router = MCPRouter(tokens: tokens, sessions: sessions, limiter: limiter, dispatcher: dispatcher, pairing: pairing, log: log)
    }

    func token(_ permission: MCPPermission = .fullAccess, access: MCPConnectionAccess = .all) throws -> String {
        try tokens.create(name: "test", permission: permission, access: access).1
    }

    func post(_ body: JSONValue, token: String?, session: String? = nil, headers: [(String, String)] = [],
              accept: String = "application/json, text/event-stream") async -> MCPHTTPResponse {
        var h: [(String, String)] = [("Content-Type", "application/json"), ("Accept", accept)]
        if let token { h.append(("Authorization", "Bearer \(token)")) }
        if let session { h.append(("Mcp-Session-Id", session)) }
        return await router.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: h + headers, body: body.encoded()))
    }

    /// Initializes and returns the session id.
    func initialize(token: String, version: String = "2025-11-25") async throws -> String {
        let r = await post(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [
            "protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"],
        ]], token: token)
        guard let id = r.header("Mcp-Session-Id") else { throw MCPToolError("no session: \(r.status)") }
        _ = await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token, session: id)
        return id
    }

    /// A request's result (or error) in a session.
    func call(_ method: String, _ params: JSONValue = [:], token: String, session: String) async throws -> JSONValue {
        let r = await post(["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params], token: token, session: session,
                           accept: "application/json")
        guard let data = r.data else { throw MCPToolError("not JSON") }
        let reply = try JSONValue.decode(data)
        if let error = reply["error"] { throw MCPToolError(error["message"]?.string ?? error.text) }
        return reply["result"] ?? .null
    }

    /// A tool's structured result and whether it's an error.
    func tool(_ name: String, _ arguments: JSONValue = [:], token: String, session: String) async throws -> (JSONValue, Bool) {
        let result = try await call("tools/call", ["name": .string(name), "arguments": arguments], token: token, session: session)
        return (result["structuredContent"] ?? .null, result["isError"]?.bool ?? false)
    }
}

extension MCPHTTPResponse {
    var json: JSONValue? { data.flatMap { try? JSONValue.decode($0) } }

    /// The events of a streamed response, until it ends.
    func events() async -> [SSEEvent] {
        guard case .events(let stream) = body else { return [] }
        var all: [SSEEvent] = []
        for await e in stream { all.append(e) }
        return all
    }
}

func serverConfig(_ variable: String) -> (ConnectionConfig, String?)? {
    guard let text = ProcessInfo.processInfo.environment[variable], let (config, password) = ConnectionConfig.parse(url: text) else { return nil }
    return (config, password)
}
