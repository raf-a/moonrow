import AppCore
import DBKit
import Foundation

/// A saved connection as the tools describe it.
public struct MCPConnectionSummary: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var tag: String?
    public var driver: DriverKind
    /// The host (or socket), or the SQLite file's path.
    public var host: String
    public var port: Int?
    public var defaultDatabase: String
    public var username: String
    public var safeMode: SafeMode
    public var readOnly: Bool
    public var overSSH: Bool

    public init(_ c: ConnectionConfig, tag: String?) {
        id = c.id
        name = c.displayName
        self.tag = tag
        driver = c.driver
        host = c.driver.isServer ? (c.host.isEmpty ? "localhost" : c.host) : c.filePath
        port = c.driver.isServer && !c.usesSocket ? c.effectivePort : nil
        defaultDatabase = c.database
        username = c.user
        safeMode = c.safeMode
        readOnly = c.readOnly
        overSSH = c.usesSSH
    }
}

/// An open connection: a workspace on it.
public struct MCPOpenConnection: Sendable, Hashable {
    public var summary: MCPConnectionSummary
    public var serverVersion: String?
    public var currentDatabase: String?
    public var currentSchema: String?

    public init(summary: MCPConnectionSummary, serverVersion: String? = nil, currentDatabase: String? = nil, currentSchema: String? = nil) {
        self.summary = summary
        self.serverVersion = serverVersion
        self.currentDatabase = currentDatabase
        self.currentSchema = currentSchema
    }
}

/// The session MCP's statements run on: one per workspace, apart from the user's own, so they
/// never land in the user's transaction.
public struct MCPQuerySession: Sendable {
    /// Changes when the host opens another session (after the workspace reconnected).
    public var id: UUID
    public var connection: any DatabaseConnection
    public var config: ConnectionConfig
    /// The database the session was opened in: nil for SQLite, or a MySQL connection without
    /// one. The runner switches from here when a call wants another.
    public var database: String?
    /// The database the workspace is in now; statements run there unless the call names another.
    public var workspaceDatabase: String?

    public init(id: UUID, connection: any DatabaseConnection, config: ConnectionConfig, database: String?,
                workspaceDatabase: String? = nil) {
        self.id = id
        self.connection = connection
        self.config = config
        self.database = database
        self.workspaceDatabase = workspaceDatabase ?? database
    }
}

/// Statements an MCP client wants to run, for the host to approve.
public struct MCPStatementRequest: Sendable {
    public var connectionID: UUID
    public var statements: [String]
    /// Some statement may change something.
    public var unsafe: Bool
    public var client: String
    public var token: MCPToken
}

public enum MCPAuthorization: Sendable, Hashable {
    case allowed
    case denied(String)
}

/// A statement MCP ran, for the history.
public struct MCPRanStatement: Sendable, Hashable {
    public var sql: String
    public var milliseconds: Int
    public var ok: Bool
}

public struct MCPSavedQuery: Sendable, Hashable {
    public var path: String
    public var sql: String
    public var modified: Date

    public init(path: String, sql: String, modified: Date) {
        self.path = path
        self.sql = sql
        self.modified = modified
    }
}

/// What the server asks of the app: its connections, workspaces and prompts.
public protocol MCPHost: Sendable {
    func savedConnections() async -> [MCPConnectionSummary]
    func openConnections() async -> [MCPOpenConnection]
    /// Opens the connection's workspace (or brings it forward), in `database` when given.
    func open(_ id: UUID, database: String?, tabbed: Bool) async throws -> MCPOpenConnection
    /// Closes the connection's workspaces (those in `database`, when given); returns how many.
    func disconnect(_ id: UUID, database: String?) async throws -> Int
    /// The open connection's MCP session, opened when first needed. Throws when the connection
    /// isn't open.
    func querySession(for id: UUID) async throws -> MCPQuerySession
    /// The approval alert (when it's on) and the workspace's safe mode.
    func authorize(_ request: MCPStatementRequest) async -> MCPAuthorization
    /// Adds what ran to the connection's history.
    func didRun(_ statements: [MCPRanStatement], on id: UUID) async
    func history(for id: UUID) async -> [QueryHistory.Entry]
    func savedQueries(for id: UUID) async -> [MCPSavedQuery]
}

public struct MCPToolError: Error, Sendable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
