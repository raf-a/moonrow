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
    /// Passwords: the login Keychain, or with `TABULA_STORE` a plain file next to it, so
    /// development runs never touch real credentials.
    lazy var secrets: any SecretStore = ProcessInfo.processInfo.environment["TABULA_STORE"] == nil
        ? KeychainSecretStore() : FileSecretStore(url: dataRoot.appending(path: "secrets.json"))
    /// Shared by every workspace open on the same connection.
    private var histories: [UUID: QueryHistory] = [:]
    private var savedQueries: [UUID: SavedQueries] = [:]

    private var welcome: WelcomeWindowController?
    private var forms: [ConnectionFormWindowController] = []
    private(set) var workspaces: [WorkspaceWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadStore()
        // Database paths on the command line open directly: `Tabula ~/data/app.db`.
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(filePath: (arg as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { openFile(url) }
        }
        if workspaces.isEmpty { showConnections(nil) }
        NSApp.activate()
        DevHarness.runIfRequested(self)
    }

    /// Files dropped on the Dock icon or opened from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConnections(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Staged grid edits are never dropped silently: ask, one workspace at a time, then quit again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace = workspaces.first(where: \.hasPendingEdits) else { return .terminateNow }
        workspace.resolvePendingEdits(before: "Quitting") { NSApp.terminate(nil) }
        return .terminateCancel
    }

    // MARK: - Actions

    @objc func showConnections(_ sender: Any?) {
        if welcome == nil {
            welcome = WelcomeWindowController(store: store, app: self)
        }
        welcome?.showWindow(nil)
    }

    /// ⌘W outside a workspace closes the window.
    @objc func closeTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func newConnection(_ sender: Any?) {
        editConnection(ConnectionConfig(), isNew: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a SQLite database"
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.openFile(url) }
        }
    }

    // MARK: - Windows

    func editConnection(_ config: ConnectionConfig, isNew: Bool) {
        if let open = forms.first(where: { $0.config.id == config.id }) {
            open.showWindow(nil)
            return
        }
        let form = ConnectionFormWindowController(config: config, isNew: isNew, store: store, secrets: secrets)
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
        connect(.sqliteFile(url), presentingErrorsIn: nil)
    }

    /// Opens a workspace window for the connection. Errors appear as a sheet on `window`,
    /// or as an alert when there is none. `password` is what the form had typed; without it the
    /// password comes from the connection's password mode.
    func connect(_ config: ConnectionConfig, password: String?? = nil, presentingErrorsIn window: NSWindow?) {
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
                        guard let typed = await askPassword(for: config, in: window) else { return }
                        login = typed
                    }
                }
                openWorkspace(config, try await ConnectionFactory.open(config, password: login))
            } catch {
                present(error, title: "Couldn't connect to \(config.displayName)", in: window)
            }
        }
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
        try? secrets.setPassword(nil, for: id)
    }

    func duplicateConnection(_ id: UUID) throws {
        guard let copy = try store.duplicate(id: id) else { return }
        if let password = try? secrets.password(for: id) { try? secrets.setPassword(password, for: copy.id) }
    }

    private func openWorkspace(_ config: ConnectionConfig, _ connection: any DatabaseConnection) {
        let history = histories[config.id] ?? QueryHistory(fileURL: QueryHistory.fileURL(root: dataRoot, connection: config.id))
        let saved = savedQueries[config.id] ?? SavedQueries(directory: SavedQueries.directory(root: dataRoot, connection: config.id))
        histories[config.id] = history
        savedQueries[config.id] = saved
        let workspace = WorkspaceWindowController(config: config, connection: connection, history: history, savedQueries: saved)
        workspace.onClose = { [weak self, weak workspace] in
            self?.workspaces.removeAll { $0 === workspace }
        }
        workspaces.append(workspace)
        workspace.showWindow(nil)
        welcome?.close()
        forms.first { $0.config.id == config.id }?.close()
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
