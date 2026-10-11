import AppCore
import AppKit
import DBKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TabulaActions {
    /// `TABULA_STORE` points at another connections file, for development.
    let store = ConnectionStore(fileURL: ProcessInfo.processInfo.environment["TABULA_STORE"]
        .map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? ConnectionStore.defaultFileURL())

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

    // MARK: - Actions

    @objc func showConnections(_ sender: Any?) {
        if welcome == nil {
            welcome = WelcomeWindowController(store: store, app: self)
        }
        welcome?.showWindow(nil)
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
        let form = ConnectionFormWindowController(config: config, isNew: isNew, store: store)
        form.onConnect = { [weak self, weak form] config in
            self?.connect(config, presentingErrorsIn: form?.window)
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
    /// or as an alert when there is none.
    func connect(_ config: ConnectionConfig, presentingErrorsIn window: NSWindow?) {
        Task {
            do {
                openWorkspace(config, try await ConnectionFactory.open(config))
            } catch {
                present(error, title: "Couldn't connect to \(config.displayName)", in: window)
            }
        }
    }

    private func openWorkspace(_ config: ConnectionConfig, _ connection: any DatabaseConnection) {
        let workspace = WorkspaceWindowController(config: config, connection: connection)
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
