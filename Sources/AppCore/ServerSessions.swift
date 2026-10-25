import DBKit
import DriverMySQL
import DriverPostgres
import Foundation

/// The server's sessions, for Running Queries: who is connected and what each runs. Read on a
/// session of its own, so a long query on the workspace's session doesn't hold it up.
public struct ServerSession: Sendable, Hashable, Identifiable {
    /// The backend pid (Postgres) or connection id (MySQL).
    public var id: Int64
    public var user: String
    public var database: String
    public var client: String
    /// `active`, `idle in transaction`, …; MySQL's command (`Query`, `Sleep`).
    public var state: String
    /// Seconds the current statement (or state) has lasted.
    public var seconds: Double?
    public var query: String
    /// Not running anything.
    public var isIdle: Bool

    public init(id: Int64, user: String, database: String, client: String, state: String, seconds: Double?,
                query: String, isIdle: Bool) {
        self.id = id
        self.user = user
        self.database = database
        self.client = client
        self.state = state
        self.seconds = seconds
        self.query = query
        self.isIdle = isIdle
    }
}

public enum ServerSessions {
    /// Postgres and MySQL / MariaDB; SQLite has no server.
    public static func isSupported(_ connection: any DatabaseConnection) -> Bool {
        connection is PostgresConnection || connection is MySQLConnection
    }

    /// The id the server gives `connection`'s current session, so the list can mark it.
    public static func ownID(of connection: any DatabaseConnection) async -> Int64? {
        if let pg = connection as? PostgresConnection { return (try? await pg.backendProcessID()).map(Int64.init) }
        if let my = connection as? MySQLConnection { return (try? await my.connectionID).map(Int64.init) }
        return nil
    }

    /// Client sessions other than the one asking, longest-running first, idle ones last.
    public static func list(on connection: any DatabaseConnection) async throws -> [ServerSession] {
        var sessions: [ServerSession]
        if let pg = connection as? PostgresConnection {
            // Before 10 the view has only client sessions, and no backend_type.
            let clients = pg.versionNumber >= 100_000 ? "backend_type = 'client backend' AND " : ""
            let rows = try await connection.execute("""
                SELECT pid, coalesce(usename, ''), coalesce(datname, ''),
                       coalesce(host(client_addr), CASE WHEN client_port = -1 THEN 'local socket' ELSE '' END),
                       coalesce(state, ''), EXTRACT(EPOCH FROM (now() - coalesce(query_start, backend_start)))::float8,
                       coalesce(query, '')
                FROM pg_catalog.pg_stat_activity
                WHERE \(clients)pid <> pg_catalog.pg_backend_pid()
                """).rows
            sessions = rows.map { r in
                let state = r[4].string ?? ""
                return ServerSession(
                    id: r[0].int64 ?? 0, user: r[1].string ?? "", database: r[2].string ?? "", client: r[3].string ?? "",
                    state: state, seconds: r[5].double, query: r[6].string ?? "", isIdle: state == "idle")
            }
        } else if connection is MySQLConnection {
            let own = try await connection.execute("SELECT CONNECTION_ID()").rows.first?.first?.int64
            let rows = try await connection.execute("SHOW FULL PROCESSLIST").rows
            // Id, User, Host, db, Command, Time, State, Info (MariaDB adds Progress).
            sessions = rows.compactMap { r in
                guard r.count >= 8, let id = r[0].int64, id != own else { return nil }
                let command = r[4].string ?? ""
                guard command != "Daemon", command != "Binlog Dump" else { return nil }
                let detail = r[6].string ?? ""
                return ServerSession(
                    id: id, user: r[1].string ?? "", database: r[3].string ?? "", client: r[2].string ?? "",
                    state: detail.isEmpty ? command : "\(command): \(detail)", seconds: r[5].double,
                    query: r[7].string ?? "", isIdle: command == "Sleep")
            }
        } else {
            throw DatabaseError("This database has no server sessions to list.")
        }
        return sessions.sorted { a, b in
            if a.isIdle != b.isIdle { return !a.isIdle }
            return (a.seconds ?? 0) > (b.seconds ?? 0)
        }
    }

    /// Stops a session's statement (`pg_cancel_backend`, `KILL QUERY`), or with `terminate`
    /// ends the session itself (`pg_terminate_backend`, `KILL`).
    public static func kill(_ id: Int64, terminate: Bool, on connection: any DatabaseConnection) async throws {
        if connection is PostgresConnection {
            let function = terminate ? "pg_terminate_backend" : "pg_cancel_backend"
            let done = try await connection.execute(SQLStatement("SELECT pg_catalog.\(function)($1)", bindings: [.integer(id)]))
            if done.rows.first?.first == .bool(false) {
                throw DatabaseError("Session \(id) couldn't be signalled; it may have ended, or belongs to another user.")
            }
        } else if connection is MySQLConnection {
            _ = try await connection.execute(SQLStatement(terminate ? "KILL \(id)" : "KILL QUERY \(id)"))
        } else {
            throw DatabaseError("This database has no server sessions.")
        }
    }

    /// The SQL `kill` sends, for the sheet's confirmation.
    public static func killSQL(_ id: Int64, terminate: Bool, on connection: any DatabaseConnection) -> String {
        if connection is PostgresConnection { return "SELECT pg_catalog.\(terminate ? "pg_terminate_backend" : "pg_cancel_backend")(\(id))" }
        return terminate ? "KILL \(id)" : "KILL QUERY \(id)"
    }
}

extension DBValue {
    var string: String? {
        switch self {
        case .null: return nil
        case .text(let s): return s
        default: return displayString
        }
    }

    var int64: Int64? {
        switch self {
        case .integer(let n): return n
        case .double(let d): return Int64(exactly: d.rounded())
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .integer(let n): return Double(n)
        case .double(let d): return d
        case .text(let s): return Double(s)
        default: return nil
        }
    }
}
