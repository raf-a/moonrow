import AppCore
import AppKit
import DBKit
import DriverMySQL
import DriverPostgres
import MCPServer

/// The app's side of the MCP server: its saved connections, its workspaces, and the prompts
/// statements go through.
@MainActor
final class AppMCPHost: MCPHost {
    private weak var app: AppDelegate?
    /// The approval alerts on screen, for the dev harness.
    private(set) var approvals: [MCPApprovalPrompt] = []

    init(app: AppDelegate) {
        self.app = app
    }

    /// The connection's workspaces, frontmost first.
    private func workspaces(for id: UUID) -> [WorkspaceWindowController] {
        guard let app else { return [] }
        let order = NSApp.orderedWindows
        return app.workspaces.filter { $0.config.id == id }.sorted { a, b in
            (a.window.flatMap { order.firstIndex(of: $0) } ?? .max) < (b.window.flatMap { order.firstIndex(of: $0) } ?? .max)
        }
    }

    private func frontmost(_ id: UUID, database: String? = nil) -> WorkspaceWindowController? {
        workspaces(for: id).first { database == nil || $0.currentDatabase == database }
    }

    private func name(of id: UUID) -> String {
        app?.store.connection(id: id)?.displayName ?? frontmost(id)?.config.displayName ?? "The connection"
    }

    private func summary(_ config: ConnectionConfig) -> MCPConnectionSummary {
        MCPConnectionSummary(app?.store.connection(id: config.id) ?? config, tag: app?.store.tag(of: config)?.name)
    }

    private func info(_ w: WorkspaceWindowController) -> MCPOpenConnection {
        let version = (w.connection as? PostgresConnection)?.serverVersion ?? (w.connection as? MySQLConnection)?.serverVersion
        return MCPOpenConnection(
            summary: summary(w.config), serverVersion: version,
            currentDatabase: w.config.driver.isServer ? w.currentDatabase : "main", currentSchema: w.sidebar.schema)
    }

    func savedConnections() async -> [MCPConnectionSummary] {
        guard let app else { return [] }
        return app.store.connections.map(summary)
    }

    func openConnections() async -> [MCPOpenConnection] {
        guard let app else { return [] }
        var seen = Set<UUID>()
        return app.workspaces.compactMap { w in
            guard seen.insert(w.config.id).inserted, let front = frontmost(w.config.id) else { return nil }
            return info(front)
        }
    }

    func open(_ id: UUID, database: String?, tabbed: Bool) async throws -> MCPOpenConnection {
        guard let app, var config = app.store.connection(id: id) else { throw MCPToolError("No saved connection has that id.") }
        if let open = frontmost(id, database: config.driver.isServer ? database : nil) {
            open.window?.orderFront(nil)
            return info(open)
        }
        if let database, config.driver.isServer { config.database = database }
        let name = config.displayName
        let workspace: WorkspaceWindowController = try await withCheckedThrowingContinuation { continuation in
            app.connect(config, presentingErrorsIn: nil, placement: tabbed ? .tab : .window,
                        onOpen: { continuation.resume(returning: $0) },
                        onFailure: { continuation.resume(throwing: MCPToolError("Couldn't connect to “\(name)”; Moonrow shows why.")) })
        }
        return info(workspace)
    }

    func disconnect(_ id: UUID, database: String?) async throws -> Int {
        let targets = workspaces(for: id).filter { database == nil || $0.currentDatabase == database }
        var closed = 0, kept = 0
        for w in targets {
            // Staged changes and unsaved queries are the user's to keep or drop.
            if !w.changes.isEmpty || w.unsavedQueryCount > 0 {
                kept += 1
                continue
            }
            w.window?.close()
            closed += 1
        }
        if closed == 0, kept > 0 {
            throw MCPToolError("“\(name(of: id))” has staged changes or unsaved queries, so it stays open.")
        }
        return closed
    }

    func querySession(for id: UUID) async throws -> MCPQuerySession {
        guard let app, let w = frontmost(id) else {
            throw MCPToolError("“\(name(of: id))” isn't open in Moonrow; call open_connection first.")
        }
        if w.mcpSession == nil {
            guard let open = w.openSession else { throw MCPToolError("This workspace can't open a session for MCP.") }
            let config = w.config
            let log = w.queryLog
            let keepAlive = app.keepAliveInterval
            w.mcpSession = Task { @MainActor in
                // Where `openSession` lands: Postgres in the workspace's database, MySQL in the
                // connection's own (none when it names none), SQLite in its one file.
                let openedIn: String? = switch config.driver {
                case .postgres: w.currentDatabase
                case .mysql, .mariadb: config.database.isEmpty ? nil : config.database
                case .sqlite: nil
                }
                let connection = try await open()
                log.follow(connection, origin: "MCP")
                connection.setKeepAlive(keepAlive)
                return MCPQuerySession(id: UUID(), connection: connection, config: config, database: openedIn)
            }
        }
        do {
            var session = try await w.mcpSession!.value
            // Statements run in the database the workspace is in now.
            session.workspaceDatabase = w.currentDatabase
            return session
        } catch {
            w.mcpSession = nil
            throw error
        }
    }

    func authorize(_ request: MCPStatementRequest) async -> MCPAuthorization {
        guard let app, let w = frontmost(request.connectionID), let window = w.window else {
            return .denied("“\(name(of: request.connectionID))” isn't open in Moonrow.")
        }
        if request.unsafe, app.settings.settings.mcpApproval {
            let prompt = MCPApprovalPrompt(request: request, connectionName: w.config.displayName)
            approvals.append(prompt)
            let answer = await prompt.run(on: window)
            approvals.removeAll { $0 === prompt }
            switch answer {
            case .allowed: break
            case .denied: return .denied("Denied in Moonrow.")
            case .timedOut(let after):
                let seconds = Int(after)
                return .denied("No answer in Moonrow within \(seconds) \(seconds == 1 ? "second" : "seconds"), so it didn't run.")
            }
        }
        guard await w.safety.approve(request.statements, from: request.client) else {
            return .denied("Safe mode in Moonrow didn't allow it.")
        }
        return .allowed
    }

    func didRun(_ statements: [MCPRanStatement], on id: UUID) async {
        guard let history = frontmost(id)?.environment.history ?? app?.queryHistory(for: id) else { return }
        for s in statements { history.add(.init(sql: s.sql, ms: s.milliseconds, ok: s.ok)) }
    }

    func history(for id: UUID) async -> [QueryHistory.Entry] {
        app?.queryHistory(for: id).entries ?? []
    }

    func savedQueries(for id: UUID) async -> [MCPSavedQuery] {
        guard let app, let config = app.store.connection(id: id) else { return [] }
        let store = app.savedQueryStore(for: config)
        return store.queries.compactMap { q in
            (try? store.text(of: q)).map { MCPSavedQuery(path: q.path, sql: $0, modified: q.modified) }
        }
    }
}

/// "Run this from <client>?": statements from MCP that may change data, when Settings ▸ MCP asks
/// for approval. Denied after 30 seconds on screen without an answer.
@MainActor
final class MCPApprovalPrompt {
    enum Answer: Equatable { case allowed, denied, timedOut(after: TimeInterval) }

    /// Seconds on screen without an answer before it counts as denied (shorter in the dev harness).
    static var timeout: TimeInterval = 30
    /// The longest a request waits behind another sheet before it counts as unanswered.
    static let queueLimit: TimeInterval = 600
    /// Windows with one of these going up, so the next waits its turn rather than queueing
    /// behind it in AppKit, where its clock would run unseen.
    private static var busy: Set<ObjectIdentifier> = []

    let alert = NSAlert()
    private var continuation: CheckedContinuation<Answer, Never>?

    init(request: MCPStatementRequest, connectionName: String) {
        let count = request.statements.count
        alert.messageText = count == 1
            ? "Run this statement from \(request.client) on “\(connectionName)”?"
            : "Run these \(count) statements from \(request.client) on “\(connectionName)”?"
        alert.informativeText = "It may change data. Token: \(request.token.name) (\(request.token.prefix)…)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let text = NSTextView()
        text.string = request.statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isEditable = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.frame = scroll.contentView.bounds
        text.autoresizingMask = [.width]
        alert.accessoryView = scroll
    }

    func run(on window: NSWindow) async -> Answer {
        // Behind another sheet (an earlier approval, safe mode, a panel) the alert isn't seen,
        // so it waits for the window, and the clock starts once it's up.
        let key = ObjectIdentifier(window)
        let queued = Date()
        while Self.busy.contains(key) || window.attachedSheet != nil {
            if Date().timeIntervalSince(queued) > Self.queueLimit { return .timedOut(after: Self.queueLimit) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.busy.insert(key)
        defer { Self.busy.remove(key) }
        let attention = NSApp.requestUserAttention(.criticalRequest)
        defer { NSApp.cancelUserAttentionRequest(attention) }
        return await withCheckedContinuation { c in
            continuation = c
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.finish(response == .alertFirstButtonReturn ? .allowed : .denied)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak window] in
                guard let self, self.continuation != nil else { return }
                self.finish(.timedOut(after: Self.timeout))
                if let sheet = window?.attachedSheet, sheet === self.alert.window { window?.endSheet(sheet) }
            }
        }
    }

    /// For the dev harness.
    func answer(_ allow: Bool) {
        alert.window.sheetParent?.endSheet(alert.window, returnCode: allow ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    private func finish(_ answer: Answer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

// MARK: - The server

extension AppDelegate {
    /// The MCP server, made the first time it's needed (the Keychain is read then).
    var mcp: MCPService {
        if let mcpService { return mcpService }
        let developing = ProcessInfo.processInfo.environment["MOONROW_STORE"] != nil
        let directory = dataRoot.appending(path: "MCP", directoryHint: .isDirectory)
        let tokenStorage: any MCPTokenStorage = developing
            ? FileTokenStorage(url: directory.appending(path: "tokens.json")) : KeychainTokenStorage()
        let certificateStorage: any MCPTokenStorage = developing
            ? FileTokenStorage(url: directory.appending(path: "certificate.json"))
            : KeychainTokenStorage(account: "certificate", label: "Moonrow MCP server certificate")
        let tokens: MCPTokenStore
        do {
            tokens = try MCPTokenStore(storage: tokenStorage)
        } catch {
            // Never overwrite tokens that couldn't be read; new ones last until quit.
            present(error, title: "Couldn't read the MCP access tokens; new tokens won't be kept after you quit", in: nil)
            tokens = (try? MCPTokenStore(storage: MemoryTokenStorage()))!
        }
        let host = AppMCPHost(app: self)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let service = MCPService(directory: directory, host: host, tokens: tokens, certificateStorage: certificateStorage, version: version)
        mcpHost = host
        mcpService = service
        return service
    }

    var mcpOptions: MCPService.Options {
        let s = settings.settings
        return MCPService.Options(port: s.mcpPort, remote: s.mcpRemote, autoToken: s.mcpAutoToken)
    }

    /// Starts, restarts or stops the server after the settings changed (`old` nil: at launch).
    func applyMCPSettings(old: AppSettings?) {
        let s = settings.settings
        let changed = old.map { $0.mcpEnabled != s.mcpEnabled || $0.mcpPort != s.mcpPort || $0.mcpRemote != s.mcpRemote
            || $0.mcpAutoToken != s.mcpAutoToken } ?? true
        guard changed else { return }
        if s.mcpEnabled {
            let options = mcpOptions
            Task { await mcp.start(options) }
        } else if mcpService != nil {
            Task { await mcp.stop() }
        }
    }

    /// `moonrow://integrations/start-mcp` (moonrow-mcp starting the app) and
    /// `moonrow://integrations/pair?…`.
    func handleIntegrationURL(_ url: URL) {
        guard url.host == "integrations" else { return }
        switch url.path {
        case "/start-mcp":
            ensureMCPRunning(reason: "An MCP client wants to use Moonrow's connections.") { _ in }
        case "/pair":
            let request: MCPPairingRequest
            do { request = try MCPPairingRequest(url: url) } catch {
                return present(error, title: "Couldn't pair", in: nil)
            }
            if let problem = Self.redirectProblem(request.redirect) {
                return present(MCPToolError("\(request.client) asks to be sent back to \(request.redirect.absoluteString), \(problem)."),
                               title: "Couldn't pair", in: nil)
            }
            ensureMCPRunning(reason: "\(request.client) wants to pair with Moonrow's MCP server.") { [weak self] running in
                guard running else { return }
                self?.askToPair(request)
            }
        default:
            break
        }
    }

    /// Runs `then(true)` once the server runs; when it's turned off, asks to turn it on first.
    private func ensureMCPRunning(reason: String, then: @escaping (Bool) -> Void) {
        if settings.settings.mcpEnabled {
            if case .running = mcp.state { return then(true) }
            let options = mcpOptions
            Task {
                let state = await mcp.start(options)
                if case .running = state { then(true) } else { then(false) }
            }
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Turn on the MCP server?"
        alert.informativeText = reason + " The MCP server is off in Settings ▸ MCP."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return then(false) }
        do {
            try settings.update { $0.mcpEnabled = true }
        } catch {
            present(error, title: "Couldn't save the setting", in: nil)
            return then(false)
        }
        // The settings observer starts it; wait for that.
        Task {
            for _ in 0..<50 {
                if case .running = mcp.state { return then(true) }
                if case .failed = mcp.state { return then(false) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            then(false)
        }
    }

    /// Why the redirect can't be opened, if it can't: a web page on this Mac may receive it, or
    /// an app of the client's own. One of the system's apps (Shortcuts, Terminal, System
    /// Settings, Finder…) would run, call, mount or configure something instead.
    static func redirectProblem(_ url: URL) -> String? {
        if MCPPairingRequest.isLoopback(url) { return nil }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "which nothing on this Mac opens" }
        let path = app.standardizedFileURL.path
        let system = ["/System/", "/usr/", "/Library/Apple/"].contains { path.hasPrefix($0) }
        return system ? "which would open \(app.deletingPathExtension().lastPathComponent)" : nil
    }

    private func askToPair(_ request: MCPPairingRequest) {
        NSApp.activate()
        let names: [String] = switch request.access {
        case .all: []
        case .only(let ids): ids.compactMap { store.connection(id: $0)?.displayName }
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(request.client) to use Moonrow's connections?"
        alert.informativeText = "\(request.client) asks for \(request.describe(connectionNames: names)). It gets an access token, "
            + "listed in Settings ▸ MCP, where you can revoke it. Pairing again replaces its earlier token."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let allow = alert.runModal() == .alertFirstButtonReturn
        let service = mcp
        Task {
            do {
                let back = allow ? try await service.approve(request) : await service.deny(request)
                // Denied, the client is told too (`error=user_denied`), so it stops waiting.
                NSWorkspace.shared.open(back)
            } catch {
                present(error, title: "Couldn't pair \(request.client)", in: nil)
            }
        }
    }
}
