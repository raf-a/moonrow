import AppCore
import Foundation

/// MCP's methods over JSON-RPC: what each request in a session gets back.
public final class MCPDispatcher: Sendable {
    /// The newest first; a client asking for another of these gets it back, any other gets the newest.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static var latestProtocolVersion: String { protocolVersions[0] }

    public static let instructions = """
        Moonrow's database connections. list_connections lists the saved ones and list_open_connections \
        those open in the app; statements run on open connections only (open_connection opens one). \
        Use execute_read_query for reads; execute_query runs anything, and statements that may change \
        data can need the user's approval in Moonrow.
        """

    let tools: MCPTools
    let host: any MCPHost
    let log: MCPActivityLog?
    let version: String

    public init(host: any MCPHost, log: MCPActivityLog?, version: String) {
        self.host = host
        self.tools = MCPTools(host: host)
        self.log = log
        self.version = version
    }

    public struct Caller: Sendable {
        public var token: MCPToken
        public var session: MCPSessionInfo?
        public var clientAddress: String

        public init(token: MCPToken, session: MCPSessionInfo?, clientAddress: String) {
            self.token = token
            self.session = session
            self.clientAddress = clientAddress
        }

        var client: String { session.map { $0.clientName.isEmpty ? "MCP client" : $0.clientName } ?? "MCP client" }
    }

    /// The version to answer an initialize request with.
    public static func negotiate(_ requested: String?) -> String {
        guard let requested, protocolVersions.contains(requested) else { return latestProtocolVersion }
        return requested
    }

    public func initializeResult(requested: String?) -> JSONValue {
        [
            "protocolVersion": .string(Self.negotiate(requested)),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": false, "listChanged": false],
                "prompts": ["listChanged": false],
                "logging": [:],
                "completions": [:],
            ],
            "serverInfo": ["name": "moonrow", "title": "Moonrow", "version": .string(version)],
            "instructions": .string(Self.instructions),
        ]
    }

    /// Answers one request (not initialize, which the transport handles with the session).
    public func handle(method: String, params: JSONValue?, caller: Caller,
                       progress: (@Sendable (Double, Double?, String) -> Void)?) async throws(JSONRPCError) -> JSONValue {
        let params = params?.object ?? [:]
        switch method {
        case "ping", "logging/setLevel":
            return .object([:])
        case "tools/list":
            return ["tools": .array(MCPTools.definitions)]
        case "tools/call":
            guard let name = params["name"]?.string else { throw .invalidParams("tools/call needs a name") }
            guard MCPTools.scope(of: name) != nil else { throw .invalidParams("Unknown tool: \(name)") }
            let arguments = params["arguments"]?.object ?? [:]
            let context = MCPCallContext(token: caller.token, client: caller.client, clientAddress: caller.clientAddress, progress: progress)
            let result = await tools.call(name, arguments: arguments, context: context)
            await log?.record(MCPActivity(
                category: .query, token: caller.token, client: caller.session?.clientName, clientAddress: caller.clientAddress,
                connectionID: result.connectionID ?? arguments["connection_id"]?.string.flatMap(UUID.init(uuidString:)),
                action: "tool." + name, status: result.status, query: result.query, details: result.details))
            return result.json
        case "resources/list":
            try requireResources(caller)
            return ["resources": .array(await resources(caller))]
        case "resources/templates/list":
            try requireResources(caller)
            return ["resourceTemplates": [
                ["uriTemplate": "moonrow://history/{connection_id}", "name": "history", "title": "Query History",
                 "description": "The statements run on a connection, newest first", "mimeType": "application/json"],
                ["uriTemplate": "moonrow://queries/{connection_id}", "name": "queries", "title": "Saved Queries",
                 "description": "A connection's saved queries, with their SQL", "mimeType": "application/json"],
            ]]
        case "resources/read":
            try requireResources(caller)
            guard let uri = params["uri"]?.string else { throw .invalidParams("resources/read needs a uri") }
            do {
                let contents = try await read(uri, caller)
                await log?.record(MCPActivity(
                    category: .resource, token: caller.token, client: caller.session?.clientName,
                    clientAddress: caller.clientAddress, connectionID: Self.parse(uri)?.1, action: "resource.read",
                    status: .success, details: uri))
                return ["contents": [contents]]
            } catch {
                await log?.record(MCPActivity(
                    category: .resource, token: caller.token, client: caller.session?.clientName,
                    clientAddress: caller.clientAddress, action: "resource.read", status: error.code == -32002 ? .error : .denied,
                    details: uri + ": " + error.message))
                throw error
            }
        case "prompts/list":
            return ["prompts": []]
        case "prompts/get":
            throw .invalidParams("Unknown prompt: \(params["name"]?.string ?? "")")
        case "completion/complete":
            return ["completion": ["values": [], "total": 0, "hasMore": false]]
        default:
            throw .methodNotFound(method)
        }
    }

    private func requireResources(_ caller: Caller) throws(JSONRPCError) {
        guard caller.token.permission.scopes.contains(.resourcesRead) else {
            throw JSONRPCError(code: -32001, message: "This token can't read resources.")
        }
    }

    // MARK: - Resources

    private func resources(_ caller: Caller) async -> [JSONValue] {
        await host.savedConnections().filter { caller.token.access.allows($0.id) }.flatMap { c -> [JSONValue] in
            let id = c.id.uuidString
            return [
                ["uri": .string("moonrow://history/\(id)"), "name": .string("history-\(id)"),
                 "title": .string("Query History for \(c.name)"), "mimeType": "application/json"],
                ["uri": .string("moonrow://queries/\(id)"), "name": .string("queries-\(id)"),
                 "title": .string("Saved Queries for \(c.name)"), "mimeType": "application/json"],
            ]
        }
    }

    enum ResourceKind: String { case history, queries }

    /// `moonrow://history/<uuid>` → (.history, uuid). Query strings and fragments aren't taken.
    static func parse(_ uri: String) -> (ResourceKind, UUID)? {
        guard let u = URLComponents(string: uri), u.scheme == "moonrow", u.query == nil, u.fragment == nil,
              let kind = u.host.flatMap(ResourceKind.init(rawValue:)) else { return nil }
        let parts = u.path.split(separator: "/")
        guard parts.count == 1, let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (kind, id)
    }

    /// At most this many history entries are returned.
    public static let historyLimit = 1_000

    private func read(_ uri: String, _ caller: Caller) async throws(JSONRPCError) -> JSONValue {
        guard let (kind, id) = Self.parse(uri) else { throw .resourceNotFound(uri) }
        guard caller.token.access.allows(id) else {
            throw JSONRPCError(code: -32001, message: "This token can't use that connection.", data: ["uri": .string(uri)])
        }
        guard await host.savedConnections().contains(where: { $0.id == id }) else { throw .resourceNotFound(uri) }
        let iso = ISO8601DateFormatter()
        let body: JSONValue
        switch kind {
        case .history:
            let entries = await host.history(for: id).sorted { $0.date > $1.date }.prefix(Self.historyLimit)
            body = ["connection_id": .string(id.uuidString), "entries": .array(entries.map { e in
                ["sql": .string(e.sql), "date": .string(iso.string(from: e.date)),
                 "execution_time_ms": e.ms.map { .int(Int64($0)) } ?? .null, "ok": .bool(e.ok)]
            })]
        case .queries:
            let queries = await host.savedQueries(for: id)
            body = ["connection_id": .string(id.uuidString), "queries": .array(queries.map { q in
                ["name": .string(q.path), "sql": .string(q.sql), "modified": .string(iso.string(from: q.modified))]
            })]
        }
        return ["uri": .string(uri), "mimeType": "application/json", "text": .string(body.text)]
    }
}
