import AppCore
import AppKit
import DBKit
import DriverRemoteSQLite
import DriverSQLite
import MCPServer
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, MoonrowActions {
    /// `MOONROW_STORE` points at another connections file, for development.
    let store = ConnectionStore(fileURL: ProcessInfo.processInfo.environment["MOONROW_STORE"]
        .map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? ConnectionStore.defaultFileURL())

    /// History and saved queries live next to the connections file, so `MOONROW_STORE` moves them too.
    var dataRoot: URL { store.fileURL.deletingLastPathComponent() }
    lazy var settings = SettingsStore(fileURL: SettingsStore.fileURL(root: dataRoot))
    private(set) var preferences: PreferencesWindowController?
    /// Passwords: the login Keychain, or with `MOONROW_STORE` a plain file next to it, so
    /// development runs never touch real credentials.
    lazy var secrets: any SecretStore = ProcessInfo.processInfo.environment["MOONROW_STORE"] == nil
        ? KeychainSecretStore() : FileSecretStore(url: dataRoot.appending(path: "secrets.json"))
    /// Shared by every workspace open on the same connection.
    private var histories: [UUID: QueryHistory] = [:]
    /// By directory path: shared by every workspace whose connection uses that queries folder.
    private var savedQueries: [String: SavedQueries] = [:]
    private var columnLayouts: [UUID: ColumnLayouts] = [:]

    /// Dev harness only: accept unknown SSH host keys without asking.
    var autoTrustHostKeys = false

    /// The workspaces to reopen at the next launch.
    lazy var sessions = SessionStore(fileURL: SessionStore.fileURL(root: dataRoot))
    private var sessionSave: Task<Void, Never>?
    private var isTerminating = false

    private(set) var welcome: WelcomeWindowController?
    /// The open connection picker, if any.
    private(set) var picker: ConnectionPicker?
    private(set) var forms: [ConnectionFormWindowController] = []
    private(set) var workspaces: [WorkspaceWindowController] = []
    /// Settings ▸ MCP's server and the app's side of it, once needed (`mcp`).
    var mcpService: MCPService?
    var mcpHost: AppMCPHost?
    private(set) var mcpActivity: MCPActivityWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["MOONROW_STORE"] == nil { adoptTabulaData() }
        let settingsError = settings.load()
        AppStyle.settings = settings.settings
        AppStyle.apply()
        NSApp.mainMenu = MainMenu.build(keyBindings: settings.settings.keyBindings)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SettingsStore.didChange, object: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: ConnectionStore.didChange, object: store)
        if let settingsError {
            present(settingsError, title: "Your preferences couldn't be read, so the defaults are used. The old file was kept as settings.json.bak.", in: nil)
        }
    }

    /// Moves what the app kept under its working name, Tabula: the data folder and the
    /// defaults. Keychain items move one by one as they're read.
    private func adoptTabulaData() {
        ConnectionStore.adoptLegacyDirectory()
        let legacy = "dev.tabula.Tabula"
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, id != legacy,
              let old = defaults.persistentDomain(forName: legacy) else { return }
        defaults.setPersistentDomain((defaults.persistentDomain(forName: id) ?? [:]).merging(old) { current, _ in current },
                                     forName: id)
        defaults.removePersistentDomain(forName: legacy)
    }

    @objc private func settingsChanged() {
        let old = AppStyle.settings
        AppStyle.settings = settings.settings
        if old.keyBindings != settings.settings.keyBindings {
            NSApp.mainMenu = MainMenu.build(keyBindings: settings.settings.keyBindings)
        }
        if old.keepAlive != settings.settings.keepAlive {
            for w in workspaces { w.connection.setKeepAlive(keepAliveInterval) }
        }
        applyMCPSettings(old: old)
    }

    /// How often idle workspace sessions are pinged; nil when Keep connection alive is off.
    var keepAliveInterval: Duration? { settings.settings.keepAlive ? .seconds(30) : nil }

    /// Workspace titles follow edits to a connection's tag and to the tags themselves.
    @objc private func storeChanged() {
        for w in workspaces {
            w.tag = tag(of: w.config)
            if let saved = store.connection(id: w.config.id) { w.follow(saved) }
        }
    }

    /// The saved connection's tag (its config as opened when it isn't saved).
    private func tag(of config: ConnectionConfig) -> ConnectionTag? {
        store.tag(of: store.connection(id: config.id) ?? config)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadStore()
        do {
            try SavedQueries.adoptLegacyFolders(store: store, root: dataRoot)
        } catch {
            present(error, title: "Couldn't record your connections' queries folders", in: nil)
        }
        // The workspaces open at the last quit come back, unless a dev harness is running.
        var reopening = 0
        if settings.settings.reopenWorkspaces, DevHarness.allowsSessionRestore {
            reopening = reopenWorkspaces()
        }
        if workspaces.isEmpty, reopening == 0 { showWelcome(nil) }
        applyMCPSettings(old: nil)
        // `MOONROW_BACKGROUND` keeps a harness run behind the apps in use.
        if ProcessInfo.processInfo.environment["MOONROW_BACKGROUND"] == nil { NSApp.activate() }
        DevHarness.runIfRequested(self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        // Saved queries write what was typed in the last second too.
        for workspace in workspaces { workspace.saveSavedQueries() }
        saveSession()
        // moonrow-mcp mustn't find a server that's gone.
        mcpService?.removeDiscoveryFile()
    }

    // MARK: - Session

    /// Reconnects each saved workspace and reopens its tabs. Returns how many it tries.
    private func reopenWorkspaces() -> Int {
        var count = 0
        for session in sessions.load() {
            guard var config = store.connection(id: session.connectionID) else {
                continue  // the connection was deleted since
            }
            // Back in the database ⌘K had switched to; the saved connection keeps its own.
            if config.driver == .postgres, let database = session.database { config.database = database }
            count += 1
            unrestored.append(session)
            connect(config, presentingErrorsIn: nil,
                    onFailure: { [weak self] in if self?.workspaces.isEmpty ?? false { self?.showWelcome(nil) } })
        }
        return count
    }

    /// Workspaces of the last session that haven't opened: still connecting, or they couldn't.
    /// They stay in the session, and the next workspace opened on their connection gets their
    /// panes and tabs (unsaved queries included).
    private var unrestored: [WorkspaceSession] = []

    /// Writes what every workspace shows, a second after the last change.
    func scheduleSessionSave() {
        sessionSave?.cancel()
        sessionSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    func saveSession() {
        sessionSave?.cancel()
        sessionSave = nil
        // Only saved connections come back; the harnesses' unsaved ones aren't kept.
        let open = workspaces.filter { store.connection(id: $0.config.id) != nil }.map { $0.sessionSnapshot() }
            + unrestored.filter { store.connection(id: $0.connectionID) != nil }
        do { try sessions.save(open) } catch { print("couldn't save the session: \(error)") }
    }

    /// SQL files dropped on the Dock icon or opened from Finder open in query tabs. Databases
    /// open through connections only.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "moonrow" { handleIntegrationURL(url) }
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "sql" {
            guard let workspace = frontmostWorkspace else { return needWorkspace(for: url) }
            workspace.openSQLFile(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Staged changes are never dropped silently: ask, one workspace at a time, then quit again.
    /// Unsaved queries come back with the session; when workspaces don't reopen, quitting asks
    /// about them too, and each workspace closes once answered.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let workspace = workspaces.first(where: { !$0.changes.isEmpty }) {
            workspace.resolveStagedChanges(before: "Quitting") { NSApp.terminate(nil) }
            return .terminateCancel
        }
        if !settings.settings.reopenWorkspaces, let workspace = workspaces.first(where: { $0.unsavedQueryCount > 0 }) {
            workspace.reviewUnsavedQueries(quitting: true) { [weak workspace] in
                workspace?.window?.close()
                NSApp.terminate(nil)
            }
            return .terminateCancel
        }
        return .terminateNow
    }

    // MARK: - Actions

    /// The welcome window: at launch, from the Dock, File ▸ New Window and Window ▸ Connections.
    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            welcome = WelcomeWindowController(store: store, app: self)
        }
        welcome?.showWindow(nil)
    }

    /// Open Connection… (⇧⌘K): the connection picker; the choice opens as a tab of the
    /// frontmost workspace window.
    @objc func showConnections(_ sender: Any?) {
        showPicker(title: "Open Connection", placement: .tab)
    }

    /// File ▸ New Window (⌥⌘N): the welcome window, whose connections open in windows of their own.
    @objc func newWindow(_ sender: Any?) {
        showWelcome(sender)
    }

    /// A sheet on the frontmost workspace window, or a window of its own when none is open.
    private func showPicker(title: String, placement: WorkspacePlacement) {
        if let open = picker {
            open.window.makeKeyAndOrderFront(nil)
            return
        }
        let main = NSApp.mainWindow ?? NSApp.keyWindow
        let host = workspaces.first { $0.window === main }?.window ?? workspaces.last?.window
        let picker = ConnectionPicker(store: store, title: title, placement: placement)
        picker.onConnect = { [weak self] config, placement in
            self?.connect(config, presentingErrorsIn: self?.frontmostWorkspace?.window, placement: placement)
        }
        picker.onNewConnection = { [weak self] in self?.newConnection(nil) }
        picker.onEdit = { [weak self] config in self?.editConnection(config, isNew: false) }
        picker.onClose = { [weak self, weak picker] in if self?.picker === picker { self?.picker = nil } }
        self.picker = picker
        // A window busy with another sheet gets a free-standing picker.
        picker.show(on: host?.attachedSheet == nil ? host : nil)
    }

    /// ⇧⌘] / ⇧⌘[: the next or previous workspace window, in tab order where windows are merged.
    @objc func selectNextWorkspace(_ sender: Any?) { cycleWorkspaces(by: 1) }
    @objc func selectPreviousWorkspace(_ sender: Any?) { cycleWorkspaces(by: -1) }

    private func cycleWorkspaces(by delta: Int) {
        let mine = Set(workspaces.compactMap(\.window).map(ObjectIdentifier.init))
        var ordered: [NSWindow] = []
        for window in workspaces.compactMap(\.window) where !ordered.contains(window) {
            ordered += (window.tabbedWindows ?? [window]).filter { mine.contains(ObjectIdentifier($0)) && !ordered.contains($0) }
        }
        guard ordered.count > 1 else { return NSSound.beep() }
        let current = ordered.firstIndex { $0.isKeyWindow || $0 === NSApp.mainWindow } ?? 0
        let next = ordered[(current + delta + ordered.count) % ordered.count]
        if let group = next.tabGroup, group.windows.count > 1 { group.selectedWindow = next }
        next.makeKeyAndOrderFront(nil)
    }

    /// ⌘W outside a workspace closes the window.
    @objc func closeTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func newConnection(_ sender: Any?) {
        editConnection(ConnectionConfig(safeMode: settings.settings.defaultSafeMode), isNew: true)
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferences == nil {
            preferences = PreferencesWindowController(settings: settings, updater: updates.updater, store: store) { [unowned self] in mcp }
            preferences?.mcp.onShowActivity = { [weak self] in self?.showMCPActivity(nil) }
        }
        preferences?.showWindow(nil)
    }

    /// Settings ▸ MCP.
    func showMCPPreferences() {
        showPreferences(nil)
        preferences?.show(pane: PreferencesWindowController.mcpPane)
    }

    /// Window ▸ MCP Activity, and Settings ▸ MCP ▸ Activity….
    @objc func showMCPActivity(_ sender: Any?) {
        if mcpActivity == nil { mcpActivity = MCPActivityWindowController(service: mcp) }
        mcpActivity?.showWindow(nil)
    }

    /// Settings ▸ Locations.
    func showLocations() {
        showPreferences(nil)
        preferences?.show(pane: PreferencesWindowController.locationsPane)
    }

    // MARK: - Updates

    let updates = Updates()

    @objc func checkForUpdates(_ sender: Any?) {
        updates.controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) { return updates.updater.canCheckForUpdates }
        return true
    }

    // MARK: - Backup and restore

    private(set) var backupWindow: BackupWindowController?
    private(set) var restoreWindow: RestoreWindowController?

    private var toolEnvironment: ToolWindowEnvironment {
        ToolWindowEnvironment(
            store: store,
            login: { [weak self] config, window in await self?.toolLogin(config, in: window) },
            locator: { [weak self] in self?.settings.settings.toolLocator ?? ToolLocator() },
            onRestored: { [weak self] id in
                for workspace in self?.workspaces ?? [] where workspace.config.id == id { workspace.sidebar.reload() }
            },
            showLocations: { [weak self] in self?.showLocations() })
    }

    /// The password a workspace on this connection logged in with, else what its password mode
    /// gives (asking if it asks); with the SSH login. Nil when cancelled.
    private func toolLogin(_ config: ConnectionConfig, in window: NSWindow?) async -> (password: String?, ssh: SSHLogin)? {
        let ssh = sshLogin(for: config, in: window)
        if let open = workspaces.first(where: { $0.config.id == config.id }) { return (open.loginPassword, ssh) }
        switch config.passwordMode {
        case .keychain: return ((try? secrets.password(for: config.id)) ?? nil, ssh)
        case .none: return (nil, ssh)
        case .ask:
            guard let typed = await askPassword(for: config, in: window) else { return nil }
            return (typed, ssh)
        }
    }

    /// The frontmost workspace's connection and database, for the windows to start on.
    private var frontmostTarget: (id: UUID, database: String?)? {
        guard let workspace = frontmostWorkspace, workspace.config.driver.isServer, store.connection(id: workspace.config.id) != nil else { return nil }
        return (workspace.config.id, workspace.currentDatabase)
    }

    /// File ▸ Backup… and the welcome window's button.
    @objc func backupDatabases(_ sender: Any?) {
        if backupWindow == nil { backupWindow = BackupWindowController(environment: toolEnvironment) }
        guard let window = backupWindow else { return }
        let target = frontmostTarget
        window.preferredDatabase = target?.database
        window.showWindow(nil)
        window.reloadConnections(select: target?.id)
    }

    /// File ▸ Restore… and the welcome window's button.
    @objc func restoreDatabase(_ sender: Any?) {
        if restoreWindow == nil { restoreWindow = RestoreWindowController(environment: toolEnvironment) }
        guard let window = restoreWindow else { return }
        let target = frontmostTarget
        window.preferredDatabase = target?.database
        window.showWindow(nil)
        window.reloadConnections(select: target?.id)
    }

    /// File ▸ Open… (⌘O): SQL files, each in a new query tab of the frontmost workspace.
    @objc func openDocument(_ sender: Any?) {
        guard let workspace = frontmostWorkspace else { return needWorkspace(for: nil) }
        let panel = NSOpenPanel()
        panel.message = "Choose SQL files to open in \(workspace.config.displayName)"
        panel.allowedContentTypes = Self.sqlTypes
        panel.allowsMultipleSelection = true
        panel.begin { [weak workspace] response in
            guard response == .OK else { return }
            for url in panel.urls { workspace?.openSQLFile(url) }
        }
    }

    static let sqlTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]

    /// The workspace SQL files open in: the frontmost one, else the one opened last.
    var frontmostWorkspace: WorkspaceWindowController? {
        let main = NSApp.mainWindow ?? NSApp.keyWindow
        return workspaces.first { $0.window === main } ?? workspaces.last
    }

    /// A SQL file needs a connection to run against.
    private func needWorkspace(for url: URL?) {
        let alert = NSAlert()
        alert.messageText = url.map { "Connect to a database to open “\($0.lastPathComponent)”" } ?? "Connect to a database first"
        alert.informativeText = "SQL files open in a query tab of a connection's workspace. Open a connection, then choose File ▸ Open… again."
        alert.runModal()
        showWelcome(nil)
    }

    // MARK: - Windows

    func editConnection(_ config: ConnectionConfig, isNew: Bool) {
        if let open = forms.first(where: { $0.config.id == config.id }) {
            open.showWindow(nil)
            return
        }
        let form = ConnectionFormWindowController(config: config, isNew: isNew, store: store, secrets: secrets, dataRoot: dataRoot)
        form.isOpenInWorkspace = { [weak self] id in self?.workspaces.contains { $0.config.id == id } ?? false }
        form.onQueriesFolderChange = { [weak self] config, change, transfer in
            try self?.changeQueriesFolder(of: config, change, transfer)
        }
        form.sshLogin = { [weak self, weak form] config, password, passphrase in
            self?.sshLogin(for: config, password: password, keyPassphrase: passphrase, in: form?.window) ?? SSHLogin()
        }
        form.onConnect = { [weak self, weak form] config, password in
            self?.connect(config, password: .some(password), presentingErrorsIn: form?.window)
        }
        form.onClose = { [weak self, weak form] in
            self?.forms.removeAll { $0 === form }
        }
        forms.append(form)
        form.showWindow(nil)
    }

    /// Opens a workspace window for the connection. Errors appear as a sheet on `window`,
    /// or as an alert when there is none. `password` is what the form had typed; without it the
    /// password comes from the connection's password mode. Over SSH, `sshPassword` overrides the
    /// saved one.
    /// The workspace opens as a tab of the frontmost workspace window unless `placement` says
    /// otherwise.
    func connect(_ config: ConnectionConfig, password: String?? = nil, sshPassword: String? = nil,
                 presentingErrorsIn window: NSWindow?, placement: WorkspacePlacement = .tab,
                 onOpen: ((WorkspaceWindowController) -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        Task {
            do {
                let login: String?
                if let password {
                    login = password
                } else {
                    switch config.passwordMode {
                    // SQLite's is a SQLCipher passphrase, when the database is encrypted.
                    case .keychain: login = try secrets.password(for: config.id)
                    case .none: login = nil
                    case .ask:
                        guard let typed = await askPassword(for: config, in: window) else {
                            onFailure?()
                            return
                        }
                        login = typed
                    }
                }
                let ssh = sshLogin(for: config, password: sshPassword, in: window)
                let connection: any DatabaseConnection
                var copy: String?
                do {
                    connection = try await ConnectionFactory.open(config, password: login, ssh: ssh)
                } catch RemoteSQLiteError.noSQLite(let command) {
                    // No sqlite3 on the server: a copy of the file, if the user wants one.
                    guard await offerCopy(of: config, missing: command, in: window) else {
                        onFailure?()
                        return
                    }
                    connection = try await ConnectionFactory.open(config, password: login, ssh: ssh, remoteCopy: true)
                    copy = (connection as? SQLiteConnection)?.path
                }
                let workspace = openWorkspace(config, connection, password: login, placement: placement)
                workspace.isRemoteCopy = copy != nil
                // Running Queries, imports, search and the diagram open sessions of their own the
                // same way, in the database the workspace is in now (a remote file's copy: that copy).
                workspace.openSession = { [weak workspace] in
                    var c = config
                    if config.driver == .postgres, let database = workspace?.currentDatabase { c.database = database }
                    if let copy {
                        c.overSSH = false
                        c.filePath = copy
                    }
                    return try await ConnectionFactory.open(c, password: login, ssh: ssh)
                }
                onOpen?(workspace)
                offerServerKind(ConnectionFactory.serverKind(of: connection), for: config, in: workspace)
            } catch {
                present(error, title: "Couldn't connect to \(config.displayName)", in: window)
                onFailure?()
            }
        }
    }

    /// A MySQL connection that reached a MariaDB server (or the other way round) offers to change
    /// its type, or to keep it, which is remembered. The open workspace keeps its type until the
    /// next connect.
    private func offerServerKind(_ server: DriverKind?, for config: ConnectionConfig, in workspace: WorkspaceWindowController) {
        guard var saved = store.connection(id: config.id), let other = saved.suggestedDriver(forServer: server),
              let window = workspace.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(config.displayName)” is a \(other.displayName) server"
        alert.informativeText = "It's saved as a \(saved.driver.displayName) connection."
        alert.addButton(withTitle: "Change to \(other.displayName)")
        alert.addButton(withTitle: "Keep \(saved.driver.displayName)")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                saved.driver = other
            } else {
                saved.keepsDriverForOtherServer = true
            }
            do { try self?.store.save(saved) } catch { present(error, title: "Couldn't save the connection", in: window) }
        }
    }

    /// Asks whether to open a copy of a SQLite file on a server that has no sqlite3.
    private func offerCopy(of config: ConnectionConfig, missing command: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "The server has no \(command)"
        alert.informativeText = "\(config.displayName) is opened with the server's own sqlite3, which isn't there. "
            + "A copy of the file can be opened instead: changes stay in the copy on this Mac and are never written back to the server."
        alert.addButton(withTitle: "Open a Copy")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    /// What a tunnel needs to log in: the SSH secrets (typed in the form, else saved), sheets on
    /// `window` for anything ssh asks, and the Keychain for answers the user wants kept.
    func sshLogin(for config: ConnectionConfig, password: String? = nil, keyPassphrase: String? = nil,
                  in window: NSWindow?) -> SSHLogin {
        let secrets = secrets
        let id = config.id
        let autoTrust = autoTrustHostKeys
        let saved = config.sshPasswordMode == .keychain ? try? secrets.secret(.sshPassword, for: id) : nil
        let sheetWindow = WeakWindow(window)
        return SSHLogin(
            password: password ?? saved,
            keyPassphrase: keyPassphrase ?? (try? secrets.secret(.sshKeyPassphrase, for: id)),
            responder: { request in
                if autoTrust, case .hostKey = request.prompt {
                    print("trusting SSH host key \(request.prompt.fingerprint ?? "?")")
                    return SSHAnswer("yes")
                }
                return await SSHPromptSheet.ask(request, in: sheetWindow)
            },
            onSave: { secret, value in
                try? secrets.setSecret(value, secret == .password ? .sshPassword : .sshKeyPassphrase, for: id)
            },
            knownHostsFiles: SSHLogin.knownHostsFiles(root: dataRoot))
    }

    /// Nil when cancelled.
    func askPassword(for config: ConnectionConfig, in window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = "\(config.driver.isServer ? "Password" : "Passphrase") for \(config.displayName)"
        alert.informativeText = config.summary
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func deleteConnection(_ id: UUID) throws {
        try store.delete(id: id)
        secrets.removeAll(for: id)
        try? mcpService?.tokens.forget(connection: id)
    }

    /// The connection's query history, shared with its workspaces.
    func queryHistory(for id: UUID) -> QueryHistory {
        if let history = histories[id] { return history }
        let history = QueryHistory(fileURL: QueryHistory.fileURL(root: dataRoot, connection: id))
        histories[id] = history
        return history
    }

    /// The connection's saved queries, shared with its workspaces.
    func savedQueryStore(for config: ConnectionConfig) -> SavedQueries {
        savedQueries(at: SavedQueries.directory(root: dataRoot, for: config))
    }

    func duplicateConnection(_ id: UUID) throws {
        guard let copy = try store.duplicate(id: id) else { return }
        secrets.copyAll(from: id, to: copy.id)
    }

    /// The store for a queries folder, shared by every workspace using it.
    private func savedQueries(at directory: URL) -> SavedQueries {
        let key = directory.standardizedFileURL.path
        if let store = savedQueries[key] { return store }
        let store = SavedQueries(directory: directory)
        savedQueries[key] = store
        return store
    }

    /// A connection's queries folder changes: what's being edited in the old one is saved, its
    /// queries are moved or copied (or left there, when `transfer` is nil), and the
    /// connection's open workspaces switch to the new folder.
    private func changeQueriesFolder(of config: ConnectionConfig, _ change: SavedQueries.FolderChange,
                                     _ transfer: SavedQueries.Transfer?) throws {
        let users = workspaces.filter { SavedQueries.sameDirectory($0.environment.savedQueries.directory, change.source) }
        for w in users { w.saveSavedQueries() }
        var moved: [String: String] = [:]
        if let transfer {
            // A folder under Queries that's left empty goes; one chosen elsewhere stays.
            let inRoot = change.source.deletingLastPathComponent().standardizedFileURL.path
                == SavedQueries.queriesRoot(dataRoot).standardizedFileURL.path
            moved = try SavedQueries.transfer(transfer, from: change.source, to: change.destination,
                                              removeSource: transfer == .move && inRoot)
        }
        let store = savedQueries(at: change.destination)
        store.reload()
        for w in workspaces where w.config.id == config.id { w.useSavedQueries(store, moved: moved) }
    }

    @discardableResult
    private func openWorkspace(_ config: ConnectionConfig, _ connection: any DatabaseConnection, password: String?,
                               placement: WorkspacePlacement) -> WorkspaceWindowController {
        let history = histories[config.id] ?? QueryHistory(fileURL: QueryHistory.fileURL(root: dataRoot, connection: config.id))
        let saved = savedQueries(at: SavedQueries.directory(root: dataRoot, for: config))
        histories[config.id] = history
        let layouts = columnLayouts[config.id] ?? ColumnLayouts(fileURL: ColumnLayouts.fileURL(root: dataRoot, connection: config.id))
        columnLayouts[config.id] = layouts
        let workspace = WorkspaceWindowController(
            config: config, tag: tag(of: config), connection: connection, history: history, savedQueries: saved,
            password: password)
        workspace.environment.columnLayouts = layouts
        workspace.savedDatabase = store.connection(id: config.id)?.database ?? config.database
        workspace.onOpenDatabaseInNewTab = { [weak self, weak workspace] database in
            guard let self, let workspace else { return }
            var c = workspace.config
            c.database = database
            self.connect(c, password: .some(workspace.loginPassword), presentingErrorsIn: workspace.window, placement: .tab)
        }
        connection.setKeepAlive(keepAliveInterval)
        // A level picked in the toolbar is kept with the saved connection.
        workspace.safety.onLevelChange = { [weak self] level in
            guard let self, var saved = self.store.connection(id: config.id) else { return }
            saved.safeMode = level
            do { try self.store.save(saved) } catch { present(error, title: "Couldn't save the safe mode", in: nil) }
        }
        workspace.onClose = { [weak self, weak workspace] in
            guard let self else { return }
            self.workspaces.removeAll { $0 === workspace }
            // Closed by hand, it won't come back; open at quit, it will.
            if !self.isTerminating { self.saveSession() }
        }
        workspace.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        show(workspace, placement)
        workspaces.append(workspace)
        if let i = unrestored.firstIndex(where: { $0.connectionID == config.id }) {
            workspace.restore(unrestored.remove(at: i))
        }
        welcome?.close()
        forms.first { $0.config.id == config.id }?.close()
        scheduleSessionSave()
        return workspace
    }

    /// A new workspace joins the frontmost workspace window as a tab, or (from the welcome
    /// window, or with no workspace open) opens a window of its own.
    private func show(_ workspace: WorkspaceWindowController, _ placement: WorkspacePlacement) {
        guard let window = workspace.window else { return }
        if placement == .tab, let frontmost = frontmostWorkspace?.window {
            frontmost.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Its own window, whatever the system's "Prefer tabs" setting says; it can still be
            // merged later (Window ▸ Merge All Windows) or dragged into another window's tabs.
            window.tabbingMode = .disallowed
            workspace.showWindow(nil)
            window.tabbingMode = .automatic
        }
    }

    private func loadStore() {
        do {
            try store.load()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Your saved connections couldn't be loaded"
            alert.informativeText = "\(error)\n\nStart with an empty list? The old file is kept next to it with a .bak extension."
            alert.addButton(withTitle: "Start Empty")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertFirstButtonReturn else {
                NSApp.terminate(nil)
                return
            }
            do {
                try store.moveAsideUnreadableFile()
            } catch {
                present(error, title: "Couldn't move the file aside", in: nil)
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
func present(_ error: any Error, title: String, in window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = (error as? DatabaseError)?.message ?? error.localizedDescription
    if let window {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}
