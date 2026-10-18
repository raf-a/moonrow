import AppCore
import AppKit
import MCPServer

/// `MOONROW_MCP=<table>`: the MCP server as the app runs it, driven over HTTP and through
/// moonrow-mcp: the tools on the open workspace, the approval alert (allowed, denied, timed
/// out), safe mode on top, the query log and history, then Settings ▸ MCP, the token sheet and
/// the Activity window, snapshotted. It saves the database's connection into `MOONROW_STORE` and
/// writes a temporary table on MCP's own session; the file's tables aren't changed.
extension DevHarness {
    static func mcpDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.displayIfNeeded()
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        try app.store.save(workspace.config)
        let id = workspace.config.id

        // A port away from the default, so a Moonrow in use keeps its own.
        try app.settings.update {
            $0.mcpEnabled = true
            $0.mcpPort = 51_090
            $0.mcpApproval = true
            $0.mcpAutoToken = true
            $0.mcpRemote = false
        }
        let running = try await waitFor("server") { () -> Int? in
            if case .running(let port, _, _) = app.mcp.state { return port }
            return nil
        }
        let discovery = try JSONDecoder().decode(MCPService.Discovery.self, from: Data(contentsOf: app.mcp.discoveryURL))
        let token = try require(discovery.token, "the bridge's token")
        print("server: port \(running), discovery port \(discovery.port), token \(token.prefix(9))…")

        let client = HTTPClient(port: running, token: token)
        let initialize = try await client.send("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                                             "clientInfo": ["name": "Harness", "version": "1"]])
        print("initialize: \(initialize["result"]?["serverInfo"]?.text ?? initialize.text), session \(client.session != nil)")
        _ = try await client.send("notifications/initialized", nil)
        let tools = try await client.send("tools/list", [:])["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        print("tools: \(tools.joined(separator: ", "))")
        let list = try await client.tool("list_connections", [:])
        print("list_connections: \(list["connections"]?.array?.compactMap { $0["name"]?.string } ?? [])")
        let open = try await client.tool("list_open_connections", [:])
        print("list_open_connections: \(open["connections"]?.array?.map { "\($0["name"]?.string ?? "") (\($0["current_database"]?.string ?? "-"))" } ?? [])")
        let count = try await client.tool("execute_read_query", ["connection_id": .string(id.uuidString), "query": .string("select count(*) as n from \(table)")])
        print("read: \(count["rows"]?.text ?? count.text)")

        // A write waits for Allow in the workspace.
        let host = try require(app.mcpHost, "MCP host")
        func approval() async throws -> MCPApprovalPrompt {
            try await waitFor("approval alert") { host.approvals.first { $0.alert.window.isVisible } }
        }
        let write = "create temp table mcp_demo (x integer); insert into mcp_demo values (1), (2)"
        async let allowed = client.tool("execute_query", ["connection_id": .string(id.uuidString), "query": .string(write)])
        var prompt = try await approval()
        snap("m1-approval.png", window)
        snap("m1-approval-alert.png", prompt.alert.window)
        prompt.answer(true)
        print("allowed: \((try await allowed)["total_rows_affected"]?.text ?? "?") rows")

        async let denied = client.tool("execute_query", ["connection_id": .string(id.uuidString), "query": "delete from mcp_demo"])
        prompt = try await approval()
        prompt.answer(false)
        print("denied: \((try await denied)["error"]?.string ?? "?")")

        MCPApprovalPrompt.timeout = 1
        let timedOut = try await client.tool("execute_query", ["connection_id": .string(id.uuidString), "query": "delete from mcp_demo"])
        print("timed out: \(timedOut["error"]?.string ?? "?")")
        MCPApprovalPrompt.timeout = 30

        // Safe mode asks after the approval.
        let gate = workspace.safety
        let level = gate.level
        await gate.change(to: .alertWrites)
        async let safe = client.tool("execute_query", ["connection_id": .string(id.uuidString), "query": "insert into mcp_demo values (3)"])
        prompt = try await approval()
        prompt.answer(true)
        let safety = try await waitFor("safe mode prompt") { gate.prompt.flatMap { $0.sheet.isVisible ? $0 : nil } }
        snap("m2-safe-mode.png", safety.sheet)
        safety.respond(password: nil)
        print("safe mode confirmed: \((try await safe)["rows_affected"]?.text ?? "?") row")
        await gate.change(to: level)

        let rows = try await client.tool("execute_read_query", ["connection_id": .string(id.uuidString), "query": "select x from mcp_demo order by x"])
        print("temp table on MCP's session: \(rows["rows"]?.text ?? rows.text)")
        let logged = workspace.queryLog.entries.filter { $0.origin == "MCP" }
        print("query log: \(logged.count) MCP statements, e.g. \(logged.last.map { QueryLog.line($0, dialect: workspace.connection.dialect) } ?? "none")")
        print("history: \(workspace.environment.history.entries.prefix(3).map(\.sql))")
        let history = try await client.send("resources/read", ["uri": .string("moonrow://history/\(id.uuidString)")])
        print("history resource: \(history["result"]?["contents"]?.array?.first?["text"]?.string?.count ?? 0) characters")

        // moonrow-mcp, as a client starts it.
        if let bridge = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "moonrow-mcp"),
           FileManager.default.isExecutableFile(atPath: bridge.path) {
            print("bridge: \(try await runBridge(bridge, table: table))")
        } else {
            print("bridge: not built next to the app")
        }

        // Settings ▸ MCP, a new token, the Activity window.
        app.showMCPPreferences()
        let prefs = try await waitFor("settings window") { app.preferences?.window.flatMap { $0.isVisible ? $0 : nil } }
        try await Task.sleep(for: .milliseconds(500))
        let pane = try require(app.preferences?.mcp, "MCP pane")
        print("settings: \(pane.statusLabel.stringValue); \(pane.tokens.count) tokens; setup: \(pane.setupSnippet())")
        snap("m3-settings.png", prefs)
        pane.addToken(nil)
        let sheet = try await waitFor("token sheet") { pane.tokenSheet.flatMap { $0.window?.isVisible == true ? $0 : nil } }
        sheet.nameField.stringValue = "Harness"
        sheet.permissionPopup.selectItem(at: 1)
        sheet.choose([id])
        snap("m4-token-sheet.png", sheet.window)
        sheet.generate(nil)
        let made = try await waitFor("token") { sheet.tokenField.stringValue.isEmpty ? nil : sheet.tokenField.stringValue }
        snap("m5-token-made.png", sheet.window)
        print("made token \(made.prefix(9))…: verifies \(app.mcp.tokens.verify(made)?.permission.title ?? "no")")
        sheet.cancel(nil)
        try await Task.sleep(for: .milliseconds(300))
        snap("m6-settings-tokens.png", prefs)

        app.showMCPActivity(nil)
        let activity = try require(app.mcpActivity, "activity window")
        _ = try await waitFor("activity") { activity.entries.isEmpty ? nil : true }
        try await Task.sleep(for: .milliseconds(300))
        print("activity: \(activity.entries.count) entries: \(Set(activity.entries.map(\.action)).sorted().joined(separator: ", "))")
        activity.table.selectRowIndexes([0], byExtendingSelection: false)
        snap("m7-activity.png", activity.window)
        activity.viewSegment.selectedSegment = 1
        NSApp.sendAction(try require(activity.viewSegment.action, "segment action"), to: activity.viewSegment.target, from: activity.viewSegment)
        _ = try await waitFor("clients") { activity.clients.isEmpty ? nil : true }
        try await Task.sleep(for: .milliseconds(300))
        print("clients: \(activity.clients.map { "\($0.clientName) \($0.clientVersion) via \($0.tokenName)" })")
        snap("m8-clients.png", activity.window)

        try app.settings.update { $0.mcpEnabled = false }
        _ = try await waitFor("server to stop") { app.mcp.state == .stopped ? true : nil }
        // Stopped is reported first; the sessions, the listener and the file go after it.
        let removed = (try? await waitFor("discovery file to go", seconds: 5) {
            FileManager.default.fileExists(atPath: app.mcp.discoveryURL.path) ? nil : true
        }) != nil
        print("stopped: discovery file \(removed ? "removed" : "left")")
    }

    /// moonrow-mcp with the harness's store: initialize, a read, and stdin closed.
    private static func runBridge(_ bridge: URL, table: String) async throws -> String {
        let process = Process()
        process.executableURL = bridge
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key == "MOONROW_STORE" || $0.key == "PATH" || $0.key == "HOME" }
            .merging(["MOONROW_MCP_NO_LAUNCH": "1"]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"moonrow-mcp harness","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute_read_query","arguments":{"query":"select count(*) as n from \#(table)"}}}"#,
        ]
        for line in lines { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }
        let reader = output.fileHandleForReading
        let replies: [String] = await Task.detached {
            var found: [String] = []
            var buffer = Data()
            while found.count < 2 {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let i = buffer.firstIndex(of: 10) {
                    found.append(String(decoding: buffer[..<i], as: UTF8.self))
                    buffer.removeSubrange(...i)
                }
            }
            return found
        }.value
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let rows = replies.compactMap { try? JSONValue.decode(Data($0.utf8)) }.first { $0["id"] == 2 }?["result"]?["structuredContent"]?["rows"]
        return "\(replies.count) replies, rows \(rows?.text ?? "none"), exit \(process.terminationStatus)"
    }

    /// Streamable HTTP as a client speaks it.
    @MainActor private final class HTTPClient {
        let url: URL
        let token: String
        var session: String?
        private var nextID: Int64 = 1

        init(port: Int, token: String) {
            url = URL(string: "http://127.0.0.1:\(port)/mcp")!
            self.token = token
        }

        func send(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
            var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params {
                message["params"] = params
                message["id"] = .int(nextID)
                nextID += 1
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = JSONValue.object(message).encoded()
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            let (data, response) = try await URLSession.shared.data(for: request)
            if let id = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") { session = id }
            return data.isEmpty ? .null : try JSONValue.decode(data)
        }

        /// A tool's structured result.
        func tool(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            try await send("tools/call", ["name": .string(name), "arguments": arguments])["result"]?["structuredContent"] ?? .null
        }
    }
}
