import DBKit
import DriverSQLite
import Foundation

/// One thing an MCP client did, or tried to.
public struct MCPActivity: Sendable, Hashable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case auth, query, resource, system
    }

    public enum Status: String, Sendable, CaseIterable {
        case success, denied, error
    }

    public var id: UUID
    public var timestamp: Date
    public var category: Category
    public var tokenID: UUID?
    public var tokenName: String?
    public var tokenPrefix: String?
    public var client: String?
    public var clientAddress: String?
    public var connectionID: UUID?
    /// `tool.execute_query`, `token.created`, `session.start`, …
    public var action: String
    public var status: Status
    public var query: String?
    /// The details: the error, the arguments, the result's size.
    public var details: String?

    public init(
        id: UUID = UUID(), timestamp: Date = Date(), category: Category, token: MCPToken? = nil, client: String? = nil,
        clientAddress: String? = nil, connectionID: UUID? = nil, action: String, status: Status,
        query: String? = nil, details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.tokenID = token?.id
        self.tokenName = token?.name
        self.tokenPrefix = token?.prefix
        self.client = client
        self.clientAddress = clientAddress
        self.connectionID = connectionID
        self.action = action
        self.status = status
        self.query = query
        self.details = details
    }
}

/// The MCP activity log: a SQLite file (WAL), newest entries first.
public actor MCPActivityLog {
    public static let didChange = Notification.Name("MCPActivityLog.didChange")

    public struct Filter: Sendable, Hashable {
        public var since: Date?
        public var tokenID: UUID?
        public var category: MCPActivity.Category?
        /// Matched against the action, query, details, client and token name.
        public var search: String
        public var limit: Int

        public init(since: Date? = nil, tokenID: UUID? = nil, category: MCPActivity.Category? = nil, search: String = "", limit: Int = 5_000) {
            self.since = since
            self.tokenID = tokenID
            self.category = category
            self.search = search
            self.limit = limit
        }
    }

    public let url: URL
    private var db: SQLiteConnection?

    public init(url: URL) {
        self.url = url
    }

    private func open() async throws -> SQLiteConnection {
        if let db { return db }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: url.path)
        _ = try await db.execute("PRAGMA journal_mode = WAL")
        _ = try await db.execute("""
            CREATE TABLE IF NOT EXISTS activity (
                id TEXT PRIMARY KEY, timestamp REAL NOT NULL, category TEXT NOT NULL,
                token_id TEXT, token_name TEXT, token_prefix TEXT, client TEXT, client_address TEXT,
                connection_id TEXT, action TEXT NOT NULL, status TEXT NOT NULL, query TEXT, details TEXT
            )
            """)
        _ = try await db.execute("CREATE INDEX IF NOT EXISTS activity_time ON activity(timestamp DESC)")
        _ = try await db.execute("CREATE INDEX IF NOT EXISTS activity_token ON activity(token_id, timestamp DESC)")
        self.db = db
        return db
    }

    /// Recorded even from a task that was cancelled: a stopped tool call is activity too.
    public func record(_ a: MCPActivity) async {
        await Task { await self.write(a) }.value
    }

    private func write(_ a: MCPActivity) async {
        do {
            let db = try await open()
            func text(_ s: String?) -> DBValue { s.map(DBValue.text) ?? .null }
            _ = try await db.execute(
                "INSERT INTO activity VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                .text(a.id.uuidString), .double(a.timestamp.timeIntervalSince1970), .text(a.category.rawValue),
                text(a.tokenID?.uuidString), text(a.tokenName), text(a.tokenPrefix), text(a.client), text(a.clientAddress),
                text(a.connectionID?.uuidString), .text(a.action), .text(a.status.rawValue), text(a.query), text(a.details))
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            print("couldn't record MCP activity: \(error)")
        }
    }

    public func entries(_ filter: Filter = Filter()) async throws -> [MCPActivity] {
        let db = try await open()
        var clauses: [String] = []
        var values: [DBValue] = []
        if let since = filter.since {
            clauses.append("timestamp >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        if let token = filter.tokenID {
            clauses.append("token_id = ?")
            values.append(.text(token.uuidString))
        }
        if let category = filter.category {
            clauses.append("category = ?")
            values.append(.text(category.rawValue))
        }
        let search = filter.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let pattern = "%" + search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            let columns = ["action", "query", "details", "client", "token_name", "client_address"]
            clauses.append("(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            values += Array(repeating: .text(pattern), count: columns.count)
        }
        var sql = "SELECT * FROM activity"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY timestamp DESC LIMIT \(max(1, filter.limit))"
        let result = try await db.execute(SQLStatement(sql, bindings: values))
        let index = Dictionary(uniqueKeysWithValues: result.columns.enumerated().map { ($1.name, $0) })
        return result.rows.compactMap { row in
            func string(_ c: String) -> String? {
                guard let i = index[c], case .text(let s) = row[i] else { return nil }
                return s
            }
            guard let id = string("id").flatMap(UUID.init(uuidString:)), let i = index["timestamp"],
                  let category = string("category").flatMap(MCPActivity.Category.init(rawValue:)),
                  let status = string("status").flatMap(MCPActivity.Status.init(rawValue:)) else { return nil }
            let time: Double
            switch row[i] {
            case .double(let d): time = d
            case .integer(let n): time = Double(n)
            default: return nil
            }
            var a = MCPActivity(
                id: id, timestamp: Date(timeIntervalSince1970: time), category: category,
                client: string("client"), clientAddress: string("client_address"),
                connectionID: string("connection_id").flatMap(UUID.init(uuidString:)),
                action: string("action") ?? "", status: status, query: string("query"), details: string("details"))
            a.tokenID = string("token_id").flatMap(UUID.init(uuidString:))
            a.tokenName = string("token_name")
            a.tokenPrefix = string("token_prefix")
            return a
        }
    }

    /// Removes entries older than `date`; nil removes them all. Returns how many went.
    @discardableResult
    public func clear(olderThan date: Date?) async throws -> Int {
        let db = try await open()
        let result = if let date {
            try await db.execute("DELETE FROM activity WHERE timestamp < ?", .double(date.timeIntervalSince1970))
        } else {
            try await db.execute("DELETE FROM activity")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return result.rowsAffected ?? 0
    }

    public func close() async {
        await db?.close()
        db = nil
    }

    /// The entries as CSV, with a header.
    public nonisolated static func csv(_ entries: [MCPActivity]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ s: String?) -> String {
            guard let s else { return "" }
            guard s.contains(where: { ",\"\n\r".contains($0) }) else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["Time,Status,Category,Action,Token,Token Prefix,Client,Client Address,Connection,Query,Details"]
        for e in entries {
            lines.append([
                iso.string(from: e.timestamp), e.status.rawValue, e.category.rawValue, e.action, e.tokenName,
                e.tokenPrefix, e.client, e.clientAddress, e.connectionID?.uuidString, e.query, e.details,
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
