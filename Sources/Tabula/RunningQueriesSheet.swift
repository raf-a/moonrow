import AppCore
import AppKit
import DBKit

/// Connection ▸ Running Queries…: the server's sessions on a session of the sheet's own, with
/// Refresh and Kill. Kill stops the selected session's statement; with ⌥ it ends the session.
/// The workspace's own session is marked. Idle sessions are hidden unless asked for.
@MainActor
final class RunningQueriesSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let open: () async throws -> any DatabaseConnection
    private let workspaceID: Int64?
    private var connection: (any DatabaseConnection)?
    private var all: [ServerSession] = []
    private var shown: [ServerSession] = []
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Connecting…")
    private let showIdle = NSButton(checkboxWithTitle: "Show idle sessions", target: nil, action: nil)
    private let killButton = NSButton(title: "Kill", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var flagsMonitor: Any?

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("id", "ID", 64), ("user", "User", 90), ("database", "Database", 100), ("client", "Client", 110),
        ("state", "State", 110), ("time", "Time", 64), ("query", "Query", 360),
    ]

    init(open: @escaping () async throws -> any DatabaseConnection, workspaceID: Int64?) {
        self.open = open
        self.workspaceID = workspaceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.title = "Running Queries"
        window.minSize = NSSize(width: 560, height: 260)
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for c in Self.columns {
            let column = NSTableColumn(identifier: .init(c.id))
            column.title = c.title
            column.width = c.width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showIdle.target = self
        showIdle.action = #selector(filterChanged(_:))
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = .command
        killButton.target = self
        killButton.action = #selector(kill(_:))
        killButton.toolTip = "Stop the session's statement; with ⌥, end the session"
        let dismiss = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        dismiss.keyEquivalent = "\u{1B}"
        let bottom = NSStackView(views: [showIdle, status, NSView(), refreshButton, killButton, dismiss])
        bottom.spacing = 8

        let root = NSView()
        for v in [scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
        updateButtons()
        // Kill becomes "End Session" while ⌥ is down.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.updateButtons(option: event.modifierFlags.contains(.option)) }
            return event
        }
    }

    func begin(on window: NSWindow) {
        guard let sheet = self.window else { return }
        window.beginSheet(sheet) { _ in _ = self }
        Task { await connect() }
    }

    private func connect() async {
        do {
            connection = try await open()
            await reload()
        } catch {
            show(error)
        }
    }

    private func reload() async {
        guard let connection else { return }
        refreshButton.isEnabled = false
        defer { refreshButton.isEnabled = true }
        do {
            all = try await ServerSessions.list(on: connection)
            applyFilter()
            let active = all.filter { !$0.isIdle }.count
            status.textColor = .secondaryLabelColor
            status.stringValue = "\(all.count) session\(all.count == 1 ? "" : "s"), \(active) running · \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            show(error)
        }
    }

    private func applyFilter() {
        let selected = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : nil
        shown = showIdle.state == .on ? all : all.filter { !$0.isIdle || $0.id == workspaceID }
        table.reloadData()
        if let selected, let i = shown.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        updateButtons()
    }

    private func show(_ error: any Error) {
        status.textColor = .systemRed
        status.stringValue = (error as? DatabaseError)?.message ?? "\(error)"
        status.toolTip = status.stringValue
    }

    private func updateButtons(option: Bool = NSEvent.modifierFlags.contains(.option)) {
        killButton.title = option ? "End Session" : "Kill"
        killButton.isEnabled = connection != nil && table.selectedRow >= 0
    }

    @objc private func filterChanged(_ sender: Any?) { applyFilter() }

    @objc func refresh(_ sender: Any?) { Task { await reload() } }

    @objc private func kill(_ sender: Any?) {
        guard let connection, table.selectedRow >= 0, table.selectedRow < shown.count, let window else { return NSSound.beep() }
        let session = shown[table.selectedRow]
        let terminate = NSEvent.modifierFlags.contains(.option)
        let alert = NSAlert()
        alert.messageText = terminate ? "End session \(session.id)?" : "Stop the statement of session \(session.id)?"
        var info = ServerSessions.killSQL(session.id, terminate: terminate, on: connection)
        if session.id == workspaceID { info = "This is the workspace's own session.\n" + info }
        alert.informativeText = info
        alert.addButton(withTitle: terminate ? "End Session" : "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await ServerSessions.kill(session.id, terminate: terminate, on: connection)
                    try? await Task.sleep(for: .milliseconds(200))
                    await self?.reload()
                } catch {
                    self?.show(error)
                }
            }
        }
    }

    @objc private func dismiss(_ sender: Any?) {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if let sheet = window { sheet.sheetParent?.endSheet(sheet) }
        let connection = connection
        self.connection = nil
        Task { await connection?.close() }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let s = shown[row]
        let text: String = switch id {
        case "id": s.id == workspaceID ? "\(s.id) (this)" : String(s.id)
        case "user": s.user
        case "database": s.database
        case "client": s.client
        case "state": s.state
        case "time": s.seconds.map { $0 < 60 ? String(format: "%.1f s", $0) : String(format: "%.0f min", $0 / 60) } ?? ""
        default: s.query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = id == "query" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        field.textColor = s.isIdle ? .secondaryLabelColor : .labelColor
        field.toolTip = id == "query" ? s.query : nil
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - For the dev harness

    var sessions: [ServerSession] { shown }
    var isLoaded: Bool { connection != nil && refreshButton.isEnabled && !all.isEmpty }
    func select(id: Int64) {
        if let i = shown.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }
    func killSelected(terminate: Bool) async throws {
        guard let connection, table.selectedRow >= 0 else { return }
        try await ServerSessions.kill(shown[table.selectedRow].id, terminate: terminate, on: connection)
        await reload()
    }
}
