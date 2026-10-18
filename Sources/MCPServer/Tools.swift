import AppCore
import DBKit
import Foundation
import SQLScript
import WireSupport

/// Who is calling a tool, and how to report progress.
public struct MCPCallContext: Sendable {
    public var token: MCPToken
    public var client: String
    public var clientAddress: String
    /// Sends `notifications/progress` when the client asked for it.
    public var progress: (@Sendable (_ progress: Double, _ total: Double?, _ message: String) -> Void)?

    public init(token: MCPToken, client: String, clientAddress: String,
                progress: (@Sendable (Double, Double?, String) -> Void)? = nil) {
        self.token = token
        self.client = client
        self.clientAddress = clientAddress
        self.progress = progress
    }
}

/// A tool call's result: text (JSON) plus the same as structured content.
public struct MCPToolResult: Sendable {
    public var structured: JSONValue
    public var isError: Bool
    /// What the activity log keeps.
    public var status: MCPActivity.Status
    public var connectionID: UUID?
    public var query: String?
    public var details: String?

    static func error(_ message: String, status: MCPActivity.Status = .error, connection: UUID? = nil, query: String? = nil) -> MCPToolResult {
        MCPToolResult(structured: ["error": .string(message)], isError: true, status: status, connectionID: connection,
                      query: query, details: message)
    }

    public var json: JSONValue {
        let text: String = if isError, let message = structured["error"]?.string, structured.object?.count == 1 {
            message
        } else {
            structured.text
        }
        return ["content": [["type": "text", "text": .string(text)]], "structuredContent": structured, "isError": .bool(isError)]
    }
}

/// The tools: their definitions and what calling them does.
public final class MCPTools: Sendable {
    public static let rowLimit = 1_000
    /// Rows stop being added once a result's JSON passes this, and it's marked truncated.
    public static let resultByteLimit = 4 << 20
    public static let maxTimeout = 300

    let host: any MCPHost
    let runner = MCPQueryRunner()

    public init(host: any MCPHost) {
        self.host = host
    }

    public static let definitions: [JSONValue] = [
        tool("list_connections", "List Connections", "List the saved connections this token can use.",
             properties: [:], readOnly: true),
        tool("list_open_connections", "List Open Connections",
             "List the connections that are open in Moonrow, with their current database and schema.",
             properties: [:], readOnly: true),
        tool("open_connection", "Connect", "Open a saved connection in Moonrow, by its id.", properties: [
            "connection_id": ["type": "string", "description": "UUID of the saved connection"],
            "database": ["type": "string", "description": "Database to open (the connection's own when omitted)"],
            "tabbed": ["type": "boolean", "description": "Open as a tab of an open window when possible (default true); false opens a separate window"],
        ], required: ["connection_id"], readOnly: false, idempotent: true),
        tool("disconnect", "Disconnect", "Close a connection's workspaces.", properties: [
            "connection_id": ["type": "string", "description": "UUID of the connection to close"],
            "database": ["type": "string", "description": "Only the workspaces in this database (all when omitted)"],
        ], required: ["connection_id"], readOnly: false, destructive: false, idempotent: true),
        tool("execute_query", "Execute Query or Script",
             "Run a SQL statement or a script of several on an open connection. Statements that may change data need a Read & Write token and can need the user's approval.",
             properties: queryProperties("SQL statement or a script of several"), required: ["query"],
             readOnly: false, destructive: true),
        tool("execute_read_query", "Execute Read Query or Script",
             "Run a read-only SQL statement or script (SELECT, WITH, EXPLAIN, SHOW, DESCRIBE, VALUES, TABLE) on an open connection, inside a read-only transaction. Anything else is refused.",
             properties: queryProperties("Read-only SQL statement or a script of several"), required: ["query"],
             readOnly: true),
    ]

    private static func queryProperties(_ query: String) -> [String: JSONValue] {
        [
            "connection_id": ["type": "string", "description": "UUID of an open connection (optional when only one is open)"],
            "query": ["type": "string", "description": .string(query)],
            "database": ["type": "string", "description": "The database to run it in (the workspace's when omitted)"],
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": .int(Int64(maxTimeout)),
                                "description": .string("Seconds each statement may run (default and maximum \(maxTimeout))")],
        ]
    }

    private static func tool(
        _ name: String, _ title: String, _ description: String, properties: [String: JSONValue], required: [String] = [],
        readOnly: Bool, destructive: Bool = false, idempotent: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        var annotations: [String: JSONValue] = ["title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": false]
        if !readOnly {
            annotations["destructiveHint"] = .bool(destructive)
            annotations["idempotentHint"] = .bool(idempotent)
        }
        return ["name": .string(name), "title": .string(title), "description": .string(description),
                "inputSchema": .object(schema), "annotations": .object(annotations)]
    }

    /// The scope each tool needs to be called at all.
    static func scope(of tool: String) -> MCPScope? {
        switch tool {
        case "list_connections", "list_open_connections", "execute_query", "execute_read_query": .toolsRead
        case "open_connection", "disconnect": .toolsControl
        default: nil
        }
    }

    public func call(_ name: String, arguments: [String: JSONValue], context: MCPCallContext) async -> MCPToolResult {
        guard let scope = Self.scope(of: name) else { return .error("Unknown tool: \(name)") }
        guard context.token.permission.scopes.contains(scope) else {
            return .error("This token is \(context.token.permission.title); \(name) needs a Full Access token.", status: .denied)
        }
        do {
            switch name {
            case "list_connections": return try await listConnections(context)
            case "list_open_connections": return try await listOpenConnections(context)
            case "open_connection": return try await open(arguments, context)
            case "disconnect": return try await disconnect(arguments, context)
            case "execute_query": return try await execute(arguments, context, readTool: false)
            default: return try await execute(arguments, context, readTool: true)
            }
        } catch is CancellationError {
            return .error("Cancelled.")
        } catch {
            return .error(ScriptRunnerMessage.text(error))
        }
    }

    // MARK: - Connections

    private func listConnections(_ context: MCPCallContext) async throws -> MCPToolResult {
        let open = Dictionary(await host.openConnections().map { ($0.summary.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = await host.savedConnections().filter { context.token.access.allows($0.id) }
        let items = list.map { Self.json($0, open: open[$0.id]) }
        return MCPToolResult(structured: ["connections": .array(items)], isError: false, status: .success,
                             details: "\(items.count) connections")
    }

    private func listOpenConnections(_ context: MCPCallContext) async throws -> MCPToolResult {
        let open = await host.openConnections().filter { context.token.access.allows($0.summary.id) }
        let items = open.map { Self.json($0.summary, open: $0) }
        return MCPToolResult(structured: ["connections": .array(items)], isError: false, status: .success,
                             details: "\(items.count) open")
    }

    static func json(_ c: MCPConnectionSummary, open: MCPOpenConnection?) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(c.id.uuidString), "name": .string(c.name), "tag": c.tag.map(JSONValue.string) ?? .null,
            "driver": .string(c.driver.rawValue), "host": .string(c.host),
            "port": c.port.map { .int(Int64($0)) } ?? .null,
            "default_database": .string(c.defaultDatabase), "username": .string(c.username),
            "safe_mode": .string(c.safeMode.rawValue), "read_only": .bool(c.readOnly), "over_ssh": .bool(c.overSSH),
            "is_open": .bool(open != nil),
        ]
        if let open {
            o["server_version"] = open.serverVersion.map(JSONValue.string) ?? .null
            o["current_database"] = open.currentDatabase.map(JSONValue.string) ?? .null
            o["current_schema"] = open.currentSchema.map(JSONValue.string) ?? .null
        }
        return .object(o)
    }

    private func connectionID(_ arguments: [String: JSONValue], _ context: MCPCallContext, openOnly: Bool) async throws -> UUID {
        if let text = arguments["connection_id"]?.string {
            guard let id = UUID(uuidString: text) else { throw MCPToolError("connection_id isn't a UUID: \(text)") }
            guard context.token.access.allows(id) else { throw MCPToolError("This token can't use that connection.") }
            return id
        }
        guard openOnly else { throw MCPToolError("connection_id is required.") }
        let open = await host.openConnections().filter { context.token.access.allows($0.summary.id) }
        guard open.count == 1 else {
            throw MCPToolError(open.isEmpty ? "No connection is open; call open_connection first."
                : "Several connections are open; pass connection_id (list_open_connections has them).")
        }
        return open[0].summary.id
    }

    private func open(_ arguments: [String: JSONValue], _ context: MCPCallContext) async throws -> MCPToolResult {
        let id = try await connectionID(arguments, context, openOnly: false)
        guard await host.savedConnections().contains(where: { $0.id == id }) else {
            return .error("No saved connection has that id.", connection: id)
        }
        let database = arguments["database"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let open = try await host.open(id, database: database, tabbed: arguments["tabbed"]?.bool ?? true)
        return MCPToolResult(structured: ["connection": Self.json(open.summary, open: open)], isError: false,
                             status: .success, connectionID: id, details: open.currentDatabase.map { "database \($0)" })
    }

    private func disconnect(_ arguments: [String: JSONValue], _ context: MCPCallContext) async throws -> MCPToolResult {
        let id = try await connectionID(arguments, context, openOnly: false)
        let database = arguments["database"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let closed = try await host.disconnect(id, database: database)
        await runner.forget(id)
        return MCPToolResult(structured: ["closed_workspaces": .int(Int64(closed))], isError: false, status: .success,
                             connectionID: id, details: "\(closed) closed")
    }

    // MARK: - Statements

    private func execute(_ arguments: [String: JSONValue], _ context: MCPCallContext, readTool: Bool) async throws -> MCPToolResult {
        guard let query = arguments["query"]?.string, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("query is required.")
        }
        let id: UUID
        do { id = try await connectionID(arguments, context, openOnly: true) } catch let e as MCPToolError {
            let denied = e.message.hasPrefix("This token")
            return .error(e.message, status: denied ? .denied : .error, query: query)
        }
        let session: MCPQuerySession
        do { session = try await host.querySession(for: id) } catch {
            return .error(ScriptRunnerMessage.text(error), connection: id, query: query)
        }
        let dialect = session.config.driver.lexer
        let statements = SQLSplitter.split(query, dialect: dialect)
        guard !statements.isEmpty else { return .error("The query has no statements.", connection: id, query: query) }
        let unsafe = statements.first { SQLClassifier.kind(of: $0.text, dialect: dialect) == .write }
        if let unsafe {
            if readTool {
                return .error("execute_read_query runs reads only, and this may change data: \(Self.excerpt(unsafe.text))",
                              status: .denied, connection: id, query: query)
            }
            if !context.token.permission.scopes.contains(.toolsWrite) {
                return .error("This token is Read Only; statements that may change data need a Read & Write token.",
                              status: .denied, connection: id, query: query)
            }
            if session.config.readOnly {
                return .error("“\(session.config.displayName)” is read-only; it doesn't run statements that may change data.",
                              status: .denied, connection: id, query: query)
            }
        }
        let request = MCPStatementRequest(connectionID: id, statements: statements.map(\.text), unsafe: unsafe != nil,
                                          client: context.client, token: context.token)
        if case .denied(let reason) = await host.authorize(request) {
            return .error(reason, status: .denied, connection: id, query: query)
        }
        let timeout = min(max(arguments["timeout_seconds"]?.int.map(Int.init) ?? Self.maxTimeout, 1), Self.maxTimeout)
        let database = arguments["database"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        // Reads run in a read-only transaction, so a statement taken for a read can't write.
        let guarded = unsafe == nil
        let run = try await runner.run(statements, on: session, database: database, guarded: guarded,
                                       timeout: .seconds(timeout), progress: context.progress)
        await host.didRun(run.ran, on: id)
        return run.result(connection: id, query: query)
    }

    static func excerpt(_ sql: String) -> String {
        let line = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }
}

/// Runs MCP's statements, one call at a time per session, keeping track of each session's database.
actor MCPQueryRunner {
    private struct State {
        var session: UUID
        var lock = AsyncLock()
        var database: String?
    }

    private var states: [UUID: State] = [:]

    func forget(_ connection: UUID) {
        states[connection] = nil
    }

    private func state(for s: MCPQuerySession) -> (AsyncLock, String?) {
        if states[s.config.id]?.session != s.id {
            states[s.config.id] = State(session: s.id, database: s.database)
        }
        return (states[s.config.id]!.lock, states[s.config.id]!.database)
    }

    private func setDatabase(_ name: String?, for s: MCPQuerySession) {
        if states[s.config.id]?.session == s.id { states[s.config.id]?.database = name }
    }

    struct Run: Sendable {
        var results: [JSONValue] = []
        var ran: [MCPRanStatement] = []
        var failure: String?
        var database: String?
        var driver: DriverKind

        func result(connection: UUID, query: String) -> MCPToolResult {
            var o: [String: JSONValue]
            let rows = results.reduce(0) { $0 + Int($1["row_count"]?.int ?? 0) }
            let affected = results.reduce(0) { $0 + Int($1["rows_affected"]?.int ?? 0) }
            let ms = results.reduce(0) { $0 + Int($1["execution_time_ms"]?.int ?? 0) }
            if results.count == 1, failure == nil {
                o = results[0].object ?? [:]
            } else {
                o = ["results": .array(results), "result_count": .int(Int64(results.count)),
                     "total_row_count": .int(Int64(rows)), "total_rows_affected": .int(Int64(affected)),
                     "total_execution_time_ms": .int(Int64(ms))]
            }
            o["current_database"] = database.map(JSONValue.string) ?? .null
            o["database_type"] = .string(driver.rawValue)
            if let failure { o["error"] = .string(failure) }
            let details = failure ?? "\(results.count) \(results.count == 1 ? "statement" : "statements"), \(rows) rows, \(ms) ms"
            return MCPToolResult(structured: .object(o), isError: failure != nil, status: failure == nil ? .success : .error,
                                 connectionID: connection, query: query, details: details)
        }
    }

    func run(
        _ statements: [SQLStatementRange], on s: MCPQuerySession, database requested: String?, guarded: Bool,
        timeout: Duration, progress: (@Sendable (Double, Double?, String) -> Void)?
    ) async throws -> Run {
        let (lock, current) = state(for: s)
        await lock.lock()
        do {
            let run = try await runLocked(statements, on: s, current: current, requested: requested, guarded: guarded,
                                          timeout: timeout, progress: progress)
            await lock.unlock()
            return run
        } catch {
            await lock.unlock()
            throw error
        }
    }

    private func runLocked(
        _ statements: [SQLStatementRange], on s: MCPQuerySession, current: String?, requested: String?, guarded: Bool,
        timeout: Duration, progress: (@Sendable (Double, Double?, String) -> Void)?
    ) async throws -> Run {
        let db = s.connection
        let driver = s.config.driver
        var run = Run(driver: driver)
        // Each call runs in the database it names, else the workspace's; `current` is where the
        // session is now (where it was opened, or the last switch).
        let target = driver.isServer ? (requested ?? s.workspaceDatabase) : nil
        if let target, target != current, DatabaseCatalog.canSwitch(db) {
            do {
                try await DatabaseCatalog.switchTo(target, on: db)
                setDatabase(target, for: s)
            } catch {
                run.failure = "Couldn't switch to \(target): \(ScriptRunnerMessage.text(error))"
                run.database = current
                return run
            }
        }
        run.database = driver.isServer ? (target ?? current) : "main"
        let (begin, end) = Self.guardStatements(driver)
        if guarded { _ = try await db.execute(SQLStatement(begin)) }
        await consume(statements, on: db, timeout: timeout, progress: progress, into: &run)
        // Ended before the lock is let go, so the next call never starts inside it.
        if guarded { _ = try? await db.execute(SQLStatement(end)) }
        try Task.checkCancellation()
        return run
    }

    private func consume(
        _ statements: [SQLStatementRange], on db: any DatabaseConnection, timeout: Duration,
        progress: (@Sendable (Double, Double?, String) -> Void)?, into run: inout Run
    ) async {
        var columns: [ResultColumn] = []
        var rows: [JSONValue] = []
        var bytes = 0
        var cut = false
        let total = Double(statements.count)
        let events = ScriptRunner.run(statements, on: db, options: ScriptRunner.Options(
            rowLimit: MCPTools.rowLimit, stopOnError: true, batchSize: 200, timeout: timeout))
        for await event in events {
            switch event {
            case .started(let index):
                columns = []
                rows = []
                bytes = 0
                cut = false
                progress?(Double(index), total, statements.count == 1 ? "Running the statement"
                    : "Running statement \(index + 1) of \(statements.count)")
            case .columns(_, let c):
                columns = c
            case .rows(_, let batch):
                guard !cut else { break }
                let names = Self.uniqueNames(columns.map(\.name))
                let items = batch.map { row -> JSONValue in
                    var o: [String: JSONValue] = [:]
                    for (i, value) in row.enumerated() where i < names.count { o[names[i]] = Self.json(value) }
                    return .object(o)
                }
                // The batch is measured as one; only the batch that crosses the limit is measured row by row.
                let size = JSONValue.array(items).encoded().count
                if bytes + size <= MCPTools.resultByteLimit {
                    bytes += size
                    rows += items
                } else {
                    for item in items {
                        bytes += item.encoded().count
                        if bytes > MCPTools.resultByteLimit { cut = true; break }
                        rows.append(item)
                    }
                }
            case .finished(let index, let outcome):
                let ms = Self.milliseconds(outcome.duration)
                var r: [String: JSONValue] = [
                    "row_count": .int(Int64(rows.count)), "execution_time_ms": .int(Int64(ms)),
                    "is_truncated": .bool(outcome.truncated || cut),
                ]
                if !columns.isEmpty {
                    r["columns"] = .array(zip(Self.uniqueNames(columns.map(\.name)), columns).map { name, c in
                        ["name": .string(name), "type": c.typeName.map(JSONValue.string) ?? .null]
                    })
                    r["rows"] = .array(rows)
                }
                r["rows_affected"] = outcome.rowsAffected.map { .int(Int64($0)) } ?? .null
                r["status_message"] = .string(columns.isEmpty
                    ? (outcome.rowsAffected.map { "\($0) \($0 == 1 ? "row" : "rows") affected" } ?? "Done")
                    : "\(rows.count) \(rows.count == 1 ? "row" : "rows")" + (outcome.truncated || cut ? " (truncated)" : ""))
                if statements.count > 1 { r["statement"] = .string(statements[index].text) }
                run.results.append(.object(r))
                run.ran.append(MCPRanStatement(sql: statements[index].text, milliseconds: ms, ok: true))
            case .failed(let index, let failure):
                run.failure = statements.count == 1 ? failure.message : "Statement \(index + 1) failed: \(failure.message)"
                run.ran.append(MCPRanStatement(sql: statements[index].text, milliseconds: Self.milliseconds(failure.duration), ok: false))
            case .done:
                progress?(total, total, "Done")
            }
        }
    }

    /// What starts and ends a read-only stretch on each kind of database.
    static func guardStatements(_ driver: DriverKind) -> (String, String) {
        switch driver {
        case .sqlite: ("PRAGMA query_only = 1", "PRAGMA query_only = 0")
        case .postgres, .mysql, .mariadb: ("START TRANSACTION READ ONLY", "ROLLBACK")
        }
    }

    static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Column names as row keys: a repeated name gets `_2`, `_3`, ….
    static func uniqueNames(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            return n == 1 ? name : "\(name)_\(n)"
        }
    }

    /// A value as JSON: numbers and booleans as such, blobs as `0x…` hex.
    static func json(_ v: DBValue) -> JSONValue {
        switch v {
        case .null: .null
        case .integer(let i): .int(i)
        case .double(let d): d.isFinite ? .double(d) : .string(String(d))
        case .text(let s): .string(s)
        case .bool(let b): .bool(b)
        case .blob(let data): .string("0x" + data.map { String(format: "%02x", $0) }.joined())
        }
    }
}

/// The text of an error, as the query editor shows it.
enum ScriptRunnerMessage {
    static func text(_ error: any Error) -> String {
        if let e = error as? MCPToolError { return e.message }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}
