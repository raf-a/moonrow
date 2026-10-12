import AppCore
import AppKit
import DBKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TabulaActions {
    /// `TABULA_STORE` points at another connections file, for development.
    let store = ConnectionStore(fileURL: ProcessInfo.processInfo.environment["TABULA_STORE"]
        .map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? ConnectionStore.defaultFileURL())

    /// History and saved queries live next to the connections file, so `TABULA_STORE` moves them too.
    var dataRoot: URL { store.fileURL.deletingLastPathComponent() }
    lazy var settings = SettingsStore(fileURL: SettingsStore.fileURL(root: dataRoot))
    private var preferences: PreferencesWindowController?
    /// Passwords: the login Keychain, or with `TABULA_STORE` a plain file next to it, so
    /// development runs never touch real credentials.
    lazy var secrets: any SecretStore = ProcessInfo.processInfo.environment["TABULA_STORE"] == nil
        ? KeychainSecretStore() : FileSecretStore(url: dataRoot.appending(path: "secrets.json"))
    /// Shared by every workspace open on the same connection.
    private var histories: [UUID: QueryHistory] = [:]
    private var savedQueries: [UUID: SavedQueries] = [:]

    /// Dev harness only: accept unknown SSH host keys without asking.
    var autoTrustHostKeys = false

    /// The workspaces to reopen at the next launch.
    lazy var sessions = SessionStore(fileURL: SessionStore.fileURL(root: dataRoot))
    private var sessionSave: Task<Void, Never>?
    private var isTerminating = false

    private(set) var welcome: WelcomeWindowController?
    /// The open connection picker, if any.
    private(set) var picker: ConnectionPicker?
    private var forms: [ConnectionFormWindowController] = []
    private(set) var workspaces: [WorkspaceWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        let settingsError = settings.load()
        AppStyle.settings = settings.settings
        AppStyle.apply()
        NSApp.mainMenu = MainMenu.build(keyBindings: settings.settings.keyBindings)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SettingsStore.didChange, object: settings)
        if let settingsError {
            present(settingsError, title: "Your preferences couldn't be read, so the defaults are used. The old file was kept as settings.json.bak.", in: nil)
        }
    }

    @objc private func settingsChanged() {
        let old = AppStyle.settings
        AppStyle.settings = settings.settings
        if old.keyBindings != settings.settings.keyBindings {
            NSApp.mainMenu = MainMenu.build(keyBindings: settings.settings.keyBindings)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadStore()
        // Database paths on the command line open directly: `Tabula ~/data/app.db`.
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            .map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in files { openFile(url) }
        // The workspaces open at the last quit come back, unless files were named or a dev
        // harness is running.
        var reopening = 0
        if files.isEmpty, settings.settings.reopenWorkspaces, DevHarness.allowsSessionRestore {
            reopening = reopenWorkspaces()
        }
        if workspaces.isEmpty, reopening == 0 { showWelcome(nil) }
        NSApp.activate()
        DevHarness.runIfRequested(self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        saveSession()
    }

    // MARK: - Session

    /// Reconnects each saved workspace and reopens its tabs. Returns how many it tries.
    private func reopenWorkspaces() -> Int {
        var count = 0
        for session in sessions.load() {
            let config: ConnectionConfig
            if let saved = store.connection(id: session.connectionID) {
                config = saved
            } else if let path = session.filePath, FileManager.default.fileExists(atPath: path) {
                var file = ConnectionConfig.sqliteFile(URL(filePath: path))
                file.safeMode = settings.settings.defaultSafeMode
                config = file
            } else {
                continue  // the connection was deleted since
            }
            count += 1
            connect(config, presentingErrorsIn: nil,
                    onOpen: { workspace in workspace.restore(session) },
                    onFailure: { [weak self] in if self?.workspaces.isEmpty ?? false { self?.showWelcome(nil) } })
        }
        return count
    }

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
        let open = workspaces.compactMap { w -> WorkspaceSession? in
            if store.connection(id: w.config.id) != nil { return w.sessionSnapshot(filePath: nil) }
            // A file opened directly isn't saved; its path brings it back. Unsaved server
            // connections (dev switches) aren't kept.
            if w.config.driver == .sqlite { return w.sessionSnapshot(filePath: w.config.expandedFilePath) }
            return nil
        }
        do { try sessions.save(open) } catch { print("couldn't save the session: \(error)") }
    }

    /// Files dropped on the Dock icon or opened from Finder: SQL files open in query tabs,
    /// anything else as a SQLite database.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "sql" {
                guard let workspace = frontmostWorkspace else { return needWorkspace(for: url) }
                workspace.openSQLFile(url)
            } else {
                openFile(url)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Staged changes are never dropped silently: ask, one workspace at a time, then quit again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = workspaces.first(where: { !$0.changes.isEmpty }) else { return .terminateNow }
        workspace.resolveStagedChanges(before: "Quitting") { NSApp.terminate(nil) }
        return .terminateCancel
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
        if preferences == nil { preferences = PreferencesWindowController(settings: settings) }
        preferences?.showWindow(nil)
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

    /// File ▸ Open Database File…, and the welcome window's button: SQLite databases.
    @objc func openDatabaseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a SQLite database"
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.openFile(url) }
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
        let form = ConnectionFormWindowController(config: config, isNew: isNew, store: store, secrets: secrets)
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

    func openFile(_ url: URL) {
        var config = ConnectionConfig.sqliteFile(url)
        config.safeMode = settings.settings.defaultSafeMode
        connect(config, presentingErrorsIn: nil)
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
                    case .keychain: login = config.driver.isServer ? try secrets.password(for: config.id) : nil
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
                let workspace = openWorkspace(
                    config, try await ConnectionFactory.open(config, password: login, ssh: ssh), password: login, placement: placement)
                onOpen?(workspace)
            } catch {
                present(error, title: "Couldn't connect to \(config.displayName)", in: window)
                onFailure?()
            }
        }
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
    private func askPassword(for config: ConnectionConfig, in window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Password for \(config.displayName)"
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
    }

    func duplicateConnection(_ id: UUID) throws {
        guard let copy = try store.duplicate(id: id) else { return }
        secrets.copyAll(from: id, to: copy.id)
    }

    @discardableResult
    private func openWorkspace(_ config: ConnectionConfig, _ connection: any DatabaseConnection, password: String?,
                               placement: WorkspacePlacement) -> WorkspaceWindowController {
        let history = histories[config.id] ?? QueryHistory(fileURL: QueryHistory.fileURL(root: dataRoot, connection: config.id))
        let saved = savedQueries[config.id] ?? SavedQueries(directory: SavedQueries.directory(root: dataRoot, connection: config.id))
        histories[config.id] = history
        savedQueries[config.id] = saved
        let workspace = WorkspaceWindowController(
            config: config, connection: connection, history: history, savedQueries: saved, password: password)
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
