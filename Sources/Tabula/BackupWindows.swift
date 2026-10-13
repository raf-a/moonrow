import AppCore
import AppKit
import DBKit

/// What the Backup and Restore windows need from the app.
@MainActor
struct ToolWindowEnvironment {
    /// The saved connections Backup and Restore work with (servers only).
    var connections: () -> [ConnectionConfig]
    /// The database password and SSH login for a connection, asking if its mode says so; nil
    /// when the user cancels.
    var login: (ConnectionConfig, NSWindow?) async -> (password: String?, ssh: SSHLogin)?
    var locator: () -> ToolLocator
    /// After a restore: workspaces of that connection reload their lists.
    var onRestored: (UUID) -> Void = { _ in }
    /// Settings ▸ Locations.
    var showLocations: () -> Void = {}
}

/// The parts Backup and Restore share: the connection list on the left, the tool in use, the
/// command line about to run, the log, and Start / Stop.
@MainActor
class ToolWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let environment: ToolWindowEnvironment
    private(set) var configs: [ConnectionConfig] = []
    /// The selected connection's login and a session for reading its databases.
    private(set) var selected: ConnectionConfig?
    private(set) var login: (password: String?, ssh: SSHLogin)?
    private(set) var session: (any DatabaseConnection)?
    var databases: [String] = []
    private(set) var serverMajor: Int?
    private(set) var serverIsMariaDB = false
    private var loadTask: Task<Void, Never>?
    var runTask: Task<Void, Never>?
    /// For the dev harness: when a run ends.
    var onFinish: ((Result<Void, any Error>) -> Void)?

    let connectionList = NSTableView()
    let titleLabel = NSTextField(labelWithString: "")
    let toolLabel = NSTextField(wrappingLabelWithString: "")
    let commandView = NSTextField(wrappingLabelWithString: "")
    let logView = NSTextView()
    let status = NSTextField(labelWithString: "")
    let startButton = NSButton(title: "", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    var revealURLs: [URL] = []

    init(title: String, environment: ToolWindowEnvironment) {
        self.environment = environment
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = title
        window.minSize = NSSize(width: 780, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays out the window around `options` (the right-hand form between the tool line and the
    /// command).
    func build(top: [NSView], options: NSView) {
        guard let window else { return }
        let column = NSTableColumn(identifier: .init("connection"))
        column.title = "Connections"
        connectionList.addTableColumn(column)
        connectionList.headerView = nil
        connectionList.style = .sourceList
        connectionList.rowHeight = 36
        connectionList.dataSource = self
        connectionList.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = connectionList
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: side.topAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        toolLabel.font = .systemFont(ofSize: 11)
        toolLabel.textColor = .secondaryLabelColor
        toolLabel.isSelectable = true
        let locations = NSButton(title: "Locations…", target: self, action: #selector(showLocations(_:)))
        locations.controlSize = .small
        let toolRow = NSStackView(views: [toolLabel, locations])
        toolRow.alignment = .firstBaseline
        toolLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commandView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        commandView.textColor = .secondaryLabelColor
        commandView.isSelectable = true
        commandView.maximumNumberOfLines = 4
        commandView.lineBreakMode = .byCharWrapping
        commandView.cell?.truncatesLastVisibleLine = true
        commandView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let commandLabel = NSTextField(labelWithString: "Command")
        commandLabel.font = .systemFont(ofSize: 11, weight: .medium)

        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        logScroll.setContentHuggingPriority(.init(1), for: .vertical)
        let logLabel = NSTextField(labelWithString: "Log")
        logLabel.font = .systemFont(ofSize: 11, weight: .medium)

        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        startButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopClicked(_:))
        stopButton.isHidden = true
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        revealButton.isHidden = true
        let buttons = NSStackView(views: [status, NSView(), revealButton, stopButton, startButton])

        let views: [NSView] = [titleLabel] + top + [toolRow, options, commandLabel, commandView, logLabel, logScroll, buttons]
        let main = NSStackView(views: views)
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        for v in views where v !== titleLabel {
            v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -40).isActive = true
        }

        let root = NSView()
        for v in [side, main] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: 220),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        window.center()
    }

    // MARK: - Connections

    /// Lists the connections and selects `id` (or keeps the selection).
    func reloadConnections(select id: UUID? = nil) {
        let keep = id ?? selected?.id
        configs = environment.connections()
        connectionList.reloadData()
        if let keep, let i = configs.firstIndex(where: { $0.id == keep }) {
            connectionList.selectRowIndexes([i], byExtendingSelection: false)
            connectionList.scrollRowToVisible(i)
        } else if selected == nil {
            connectionChanged()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === connectionList ? configs.count : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === connectionList else { return nil }
        let c = configs[row]
        let name = NSTextField(labelWithString: c.displayName)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: c.summary)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === connectionList else { return }
        connectionChanged()
    }

    private func connectionChanged() {
        loadTask?.cancel()
        let old = session
        session = nil
        if let old { Task { await old.close() } }
        databases = []
        login = nil
        serverMajor = nil
        serverIsMariaDB = false
        selected = configs[safe: connectionList.selectedRow]
        selectionDidChange()
        guard let config = selected else { return }
        showStatus("Connecting to \(config.displayName)…", error: false)
        loadTask = Task {
            guard let login = await environment.login(config, window) else {
                showStatus("Not connected.", error: false)
                return
            }
            do {
                let session = try await ConnectionFactory.open(config, password: login.password, ssh: login.ssh)
                if Task.isCancelled {
                    await session.close()
                    return
                }
                let list = try await ServerInfo.databases(session)
                let (major, maria) = ServerInfo.version(session)
                guard selected?.id == config.id else {
                    await session.close()
                    return
                }
                self.login = login
                self.session = session
                databases = list
                serverMajor = major
                serverIsMariaDB = maria
                showStatus("", error: false)
                databasesDidLoad()
            } catch {
                if !Task.isCancelled { showStatus("Couldn't connect: \((error as? DatabaseError)?.message ?? error.localizedDescription)", error: true) }
            }
        }
    }

    /// Subclasses refresh their forms.
    func selectionDidChange() {}
    func databasesDidLoad() {}
    func start() {}

    var family: DumpTool.Family? {
        guard let selected else { return nil }
        return selected.driver == .postgres ? .postgres : .mysql
    }

    /// Shows which tool runs, or why none can.
    func show(tool: ToolInfo?, warning: String?, missing: String) {
        if let tool {
            toolLabel.stringValue = "\(tool.tool.rawValue) \(tool.versionString)\(tool.isMariaDB ? " (MariaDB)" : "") — \(tool.path)"
                + (warning.map { "\n" + $0 } ?? "")
            toolLabel.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        } else {
            toolLabel.stringValue = missing
            toolLabel.textColor = .systemRed
        }
    }

    // MARK: - Running

    var isRunning: Bool { runTask != nil }

    func appendLog(_ line: String) {
        let storage = logView.textStorage!
        let atEnd = logView.visibleRect.maxY >= logView.bounds.maxY - 4
        storage.append(NSAttributedString(string: line + "\n", attributes: [
            .font: logView.font ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: line.hasPrefix("$ ") ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]))
        // Keep the log from growing without bound on chatty tools.
        if storage.length > 400_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 300_000)) }
        if atEnd { logView.scrollToEndOfDocument(nil) }
    }

    func began() {
        startButton.isEnabled = false
        stopButton.isHidden = false
        revealButton.isHidden = true
        connectionList.isEnabled = false
        logView.string = ""
    }

    func ended(_ result: Result<Void, any Error>, success: String) {
        runTask = nil
        stopButton.isHidden = true
        connectionList.isEnabled = true
        switch result {
        case .success:
            showStatus(success, error: false)
            revealButton.isHidden = revealURLs.isEmpty
        case .failure(let error):
            if error is CancellationError {
                showStatus("Stopped.", error: false)
            } else {
                showStatus((error as? DatabaseError)?.message.split(separator: "\n").first.map(String.init) ?? error.localizedDescription, error: true)
                appendLog((error as? DatabaseError)?.message ?? error.localizedDescription)
            }
        }
        refresh()
        onFinish?(result)
    }

    func refresh() {}

    func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.toolTip = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func startClicked(_ sender: Any?) { start() }

    @objc private func stopClicked(_ sender: Any?) { runTask?.cancel() }

    @objc private func reveal(_ sender: Any?) {
        if !revealURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealURLs) }
    }

    @objc private func showLocations(_ sender: Any?) { environment.showLocations() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop and close?"
        alert.informativeText = "The tool is still running; closing stops it."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runTask?.cancel()
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        if let session { Task { await session.close() } }
        session = nil
        selected = nil
        connectionList.deselectAll(nil)
    }

    // MARK: - Form helpers

    static func checkbox(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: target, action: action)
    }

    static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [$0.0.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        grid.rowAlignment = .firstBaseline
        return grid
    }
}

// MARK: - Backup

/// File ▸ Backup… (and the welcome window): one or more databases of a saved connection, each
/// to its own file, with pg_dump or mysqldump.
@MainActor
final class BackupWindowController: ToolWindowController {
    private var chosen = Set<String>()
    private var options = BackupOptions()
    private var pattern = FileNamePattern.backup
    private var tool: ToolInfo?
    /// The database to tick when the list loads (File ▸ Backup… from a workspace).
    var preferredDatabase: String?

    private let databaseTable = NSTableView()
    private let formatPopup = NSPopUpButton()
    private let contentPopup = NSPopUpButton()
    private let gzipBox = NSButton(checkboxWithTitle: "Compress with gzip", target: nil, action: nil)
    private let noOwnerBox = NSButton(checkboxWithTitle: "No owner", target: nil, action: nil)
    private let noPrivilegesBox = NSButton(checkboxWithTitle: "No privileges", target: nil, action: nil)
    private let cleanBox = NSButton(checkboxWithTitle: "DROP before CREATE", target: nil, action: nil)
    private let createBox = NSButton(checkboxWithTitle: "CREATE DATABASE", target: nil, action: nil)
    private let singleTransactionBox = NSButton(checkboxWithTitle: "Single transaction", target: nil, action: nil)
    private let routinesBox = NSButton(checkboxWithTitle: "Routines", target: nil, action: nil)
    private let triggersBox = NSButton(checkboxWithTitle: "Triggers", target: nil, action: nil)
    private let eventsBox = NSButton(checkboxWithTitle: "Events", target: nil, action: nil)
    private let dropTableBox = NSButton(checkboxWithTitle: "DROP TABLE", target: nil, action: nil)
    private let otherField = NSTextField()
    private let patternField = NSTextField()
    private let patternMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let namesLabel = NSTextField(labelWithString: "")
    private var postgresRow: NSView!
    private var mysqlRow: NSView!

    init(environment: ToolWindowEnvironment) {
        super.init(title: "Backup", environment: environment)
        startButton.title = "Back Up…"
        pattern = UserDefaults.standard.string(forKey: "Backup.pattern") ?? FileNamePattern.backup

        let column = NSTableColumn(identifier: .init("db"))
        databaseTable.addTableColumn(column)
        databaseTable.headerView = nil
        databaseTable.rowSizeStyle = .small
        databaseTable.usesAlternatingRowBackgroundColors = true
        databaseTable.dataSource = self
        databaseTable.delegate = self
        let dbScroll = NSScrollView()
        dbScroll.documentView = databaseTable
        dbScroll.hasVerticalScroller = true
        dbScroll.borderType = .bezelBorder
        dbScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let dbLabel = NSTextField(labelWithString: "Databases")
        dbLabel.font = .systemFont(ofSize: 11, weight: .medium)

        formatPopup.addItems(withTitles: BackupOptions.PostgresFormat.allCases.map(\.title))
        contentPopup.addItems(withTitles: BackupOptions.Content.allCases.map(\.title))
        for c in [formatPopup, contentPopup] as [NSControl] + [gzipBox, noOwnerBox, noPrivilegesBox, cleanBox, createBox, singleTransactionBox,
                                                           routinesBox, triggersBox, eventsBox, dropTableBox] {
            c.target = self
            c.action = #selector(optionChanged(_:))
        }
        otherField.placeholderString = "More options for the tool, e.g. --exclude-table=logs"
        otherField.target = self
        otherField.action = #selector(optionChanged(_:))
        otherField.delegate = self
        patternField.delegate = self
        patternField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        patternMenu.addItem(withTitle: "Insert")
        patternMenu.controlSize = .small
        for token in FileNamePattern.tokens where token.placeholder != "{table}" {
            let item = patternMenu.menu!.addItem(withTitle: "\(token.title)  \(token.placeholder)", action: #selector(insertToken(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token.placeholder
        }
        namesLabel.font = .systemFont(ofSize: 11)
        namesLabel.textColor = .secondaryLabelColor
        namesLabel.lineBreakMode = .byTruncatingTail

        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 12
            return s
        }
        postgresRow = row(noOwnerBox, noPrivilegesBox, cleanBox, createBox)
        mysqlRow = row(singleTransactionBox, routinesBox, triggersBox, eventsBox, dropTableBox, createBox)
        let optionsStack = NSStackView(views: [postgresRow, mysqlRow])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        let form = Self.grid([
            ("Format", formatPopup),
            ("Content", row(contentPopup, gzipBox)),
            ("Include", optionsStack),
            ("Other options", otherField),
            ("File name", row(patternField, patternMenu)),
            ("", namesLabel),
        ])
        build(top: [dbLabel, dbScroll], options: form)
        loadOptions()
    }

    // MARK: Lists

    override func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === databaseTable ? databases.count : super.numberOfRows(in: tableView)
    }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === databaseTable else { return super.tableView(tableView, viewFor: tableColumn, row: row) }
        let name = databases[row]
        let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(databaseToggled(_:)))
        box.state = chosen.contains(name) ? .on : .off
        box.tag = row
        return box
    }

    override func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === databaseTable { return }
        super.tableViewSelectionDidChange(notification)
    }

    @objc private func databaseToggled(_ sender: NSButton) {
        guard databases.indices.contains(sender.tag) else { return }
        if sender.state == .on { chosen.insert(databases[sender.tag]) } else { chosen.remove(databases[sender.tag]) }
        refresh()
    }

    /// Ticks exactly these databases. For the dev harness.
    func choose(_ names: Set<String>) {
        chosen = names.intersection(databases)
        databaseTable.reloadData()
        refresh()
    }

    // MARK: Options

    private var optionsKey: String? { selected.map { "Backup.options.\($0.id.uuidString)" } }

    private func loadOptions() {
        if let key = optionsKey, let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(BackupOptions.self, from: data) {
            options = saved
        } else {
            options = BackupOptions()
        }
        formatPopup.selectItem(at: BackupOptions.PostgresFormat.allCases.firstIndex(of: options.postgresFormat) ?? 0)
        contentPopup.selectItem(at: BackupOptions.Content.allCases.firstIndex(of: options.content) ?? 0)
        gzipBox.state = options.gzip ? .on : .off
        noOwnerBox.state = options.noOwner ? .on : .off
        noPrivilegesBox.state = options.noPrivileges ? .on : .off
        cleanBox.state = options.clean ? .on : .off
        createBox.state = options.createDatabase ? .on : .off
        singleTransactionBox.state = options.singleTransaction ? .on : .off
        routinesBox.state = options.routines ? .on : .off
        triggersBox.state = options.triggers ? .on : .off
        eventsBox.state = options.events ? .on : .off
        dropTableBox.state = options.addDropTable ? .on : .off
        otherField.stringValue = options.otherArguments
        patternField.stringValue = pattern
        refresh()
    }

    private func readOptions() {
        options.postgresFormat = BackupOptions.PostgresFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
        options.content = BackupOptions.Content.allCases[max(0, contentPopup.indexOfSelectedItem)]
        options.gzip = gzipBox.state == .on
        options.noOwner = noOwnerBox.state == .on
        options.noPrivileges = noPrivilegesBox.state == .on
        options.clean = cleanBox.state == .on
        options.createDatabase = createBox.state == .on
        options.singleTransaction = singleTransactionBox.state == .on
        options.routines = routinesBox.state == .on
        options.triggers = triggersBox.state == .on
        options.events = eventsBox.state == .on
        options.addDropTable = dropTableBox.state == .on
        options.otherArguments = otherField.stringValue
        let typed = patternField.stringValue.trimmingCharacters(in: .whitespaces)
        pattern = typed.isEmpty ? FileNamePattern.backup : typed
    }

    private func saveOptions() {
        if let key = optionsKey, let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: key) }
        UserDefaults.standard.set(pattern, forKey: "Backup.pattern")
    }

    @objc private func optionChanged(_ sender: Any?) {
        readOptions()
        refresh()
    }

    @objc private func insertToken(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        if let editor = patternField.currentEditor() { editor.insertText(token) } else { patternField.stringValue += token }
        optionChanged(nil)
    }

    override func selectionDidChange() {
        chosen = []
        databaseTable.reloadData()
        loadOptions()
    }

    override func databasesDidLoad() {
        if let wanted = preferredDatabase, databases.contains(wanted) {
            chosen = [wanted]
            preferredDatabase = nil
        } else if let db = selected?.database, databases.contains(db) {
            chosen = [db]
        }
        databaseTable.reloadData()
        refresh()
    }

    private var job: BackupJob? {
        guard let selected, let tool, let login else { return nil }
        let names = databases.filter(chosen.contains)
        return BackupJob(config: selected, password: login.password, ssh: login.ssh, databases: names, options: options,
                         tool: tool, serverIsMariaDB: serverIsMariaDB, pattern: FileNamePattern(pattern))
    }

    override func refresh() {
        guard let selected, let family else {
            titleLabel.stringValue = "Back Up"
            toolLabel.stringValue = ""
            commandView.stringValue = ""
            namesLabel.stringValue = ""
            startButton.isEnabled = false
            return
        }
        titleLabel.stringValue = "Back Up \(selected.displayName)"
        let isPostgres = family == .postgres
        formatPopup.isEnabled = isPostgres
        postgresRow.isHidden = !isPostgres
        mysqlRow.isHidden = isPostgres
        gzipBox.isEnabled = !isPostgres || options.postgresFormat == .plain
        cleanBox.isEnabled = options.content != .dataOnly
        let role: ToolLocator.Role = isPostgres ? .backupPostgres : .backupMySQL
        let (found, warning) = environment.locator().choose(role, serverMajor: serverMajor, mariaDBServer: serverIsMariaDB)
        tool = found
        show(tool: found, warning: warning, missing: isPostgres
            ? "pg_dump wasn't found on PATH, in the usual install folders (Homebrew, Postgres.app) or in the folder set in Settings ▸ Locations."
            : "mysqldump wasn't found on PATH, in the usual install folders (Homebrew, MySQL's installer) or in the folder set in Settings ▸ Locations.")
        if let job, !job.databases.isEmpty {
            let names = job.fileNames()
            namesLabel.stringValue = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
            commandView.stringValue = (try? job.previewCommand(folder: URL(filePath: "…"))) ?? ""
        } else {
            namesLabel.stringValue = ""
            commandView.stringValue = login == nil ? "" : "No database is ticked."
        }
        startButton.isEnabled = !isRunning && job.map { !$0.databases.isEmpty } == true
    }

    // MARK: Running

    override func start() {
        guard let window, let job, !job.databases.isEmpty else { return }
        readOptions()
        saveOptions()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose the folder for the backup\(job.databases.count == 1 ? "" : "s")."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.run(into: url)
        }
    }

    /// Backs up the ticked databases into `folder`. The dev harness calls this directly.
    func run(into folder: URL) {
        readOptions()
        guard let job, !job.databases.isEmpty, !isRunning else { return }
        saveOptions()
        began()
        revealURLs = []
        showStatus("Backing up…", error: false)
        let names = job.databases
        runTask = Task {
            let result: Result<Void, any Error>
            do {
                let files = try await job.run(into: folder, log: { line in
                    Task { @MainActor in self.appendLog(line) }
                }, started: { i in
                    Task { @MainActor in self.showStatus("Backing up \(names[i]) (\(i + 1) of \(names.count))…", error: false) }
                })
                revealURLs = files
                result = .success(())
            } catch {
                result = .failure(error)
            }
            let count = revealURLs.count
            ended(result, success: "Backed up \(count) database\(count == 1 ? "" : "s") to \(folder.lastPathComponent).")
        }
    }
}

extension BackupWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { optionChanged(nil) }
}

// MARK: - Restore

/// File ▸ Restore… (and the welcome window): a backup file into a database of a saved
/// connection, existing or created first, with pg_restore, psql or mysql.
@MainActor
final class RestoreWindowController: ToolWindowController {
    private var options = RestoreOptions()
    private(set) var file: URL?
    private var kind: BackupFileKind?
    private var tool: ToolInfo?
    var preferredDatabase: String?

    private let fileLabel = NSTextField(labelWithString: "No file chosen")
    private let kindLabel = NSTextField(labelWithString: "")
    private let existingRadio = NSButton(radioButtonWithTitle: "Existing database", target: nil, action: nil)
    private let newRadio = NSButton(radioButtonWithTitle: "New database", target: nil, action: nil)
    private let databasePopup = NSPopUpButton()
    private let newNameField = NSTextField()
    private let contentPopup = NSPopUpButton()
    private let cleanBox = NSButton(checkboxWithTitle: "Drop objects first", target: nil, action: nil)
    private let noOwnerBox = NSButton(checkboxWithTitle: "No owner", target: nil, action: nil)
    private let noPrivilegesBox = NSButton(checkboxWithTitle: "No privileges", target: nil, action: nil)
    private let singleTransactionBox = NSButton(checkboxWithTitle: "Single transaction", target: nil, action: nil)
    private let stopBox = NSButton(checkboxWithTitle: "Stop at the first error", target: nil, action: nil)
    private let otherField = NSTextField()
    private var postgresRow: NSView!

    init(environment: ToolWindowEnvironment) {
        super.init(title: "Restore", environment: environment)
        startButton.title = "Restore…"
        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile(_:)))
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.font = .systemFont(ofSize: 11)
        for c in [existingRadio, newRadio] {
            c.target = self
            c.action = #selector(targetChanged(_:))
        }
        existingRadio.state = .on
        newNameField.placeholderString = "new_database"
        newNameField.delegate = self
        newNameField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        databasePopup.target = self
        databasePopup.action = #selector(optionChanged(_:))
        contentPopup.addItems(withTitles: BackupOptions.Content.allCases.map(\.title))
        for c in [contentPopup] as [NSControl] + [cleanBox, noOwnerBox, noPrivilegesBox, singleTransactionBox, stopBox] {
            c.target = self
            c.action = #selector(optionChanged(_:))
        }
        otherField.placeholderString = "More options for the tool"
        otherField.delegate = self

        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 12
            return s
        }
        postgresRow = row(cleanBox, noOwnerBox, noPrivilegesBox)
        let fileRow = row(choose, fileLabel)
        let form = Self.grid([
            ("Into", row(existingRadio, databasePopup, newRadio, newNameField)),
            ("Content", contentPopup),
            ("Options", NSStackView(views: [postgresRow, row(singleTransactionBox, stopBox)]).vertical()),
            ("Other options", otherField),
        ])
        build(top: [fileRow, kindLabel], options: form)
        loadOptions()
    }

    private var optionsKey: String? { selected.map { "Restore.options.\($0.id.uuidString)" } }

    private func loadOptions() {
        if let key = optionsKey, let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(RestoreOptions.self, from: data) {
            options = saved
        } else {
            options = RestoreOptions()
        }
        contentPopup.selectItem(at: BackupOptions.Content.allCases.firstIndex(of: options.content) ?? 0)
        cleanBox.state = options.clean ? .on : .off
        noOwnerBox.state = options.noOwner ? .on : .off
        noPrivilegesBox.state = options.noPrivileges ? .on : .off
        singleTransactionBox.state = options.singleTransaction ? .on : .off
        stopBox.state = options.stopOnError ? .on : .off
        otherField.stringValue = options.otherArguments
        refresh()
    }

    private func readOptions() {
        options.content = BackupOptions.Content.allCases[max(0, contentPopup.indexOfSelectedItem)]
        options.clean = cleanBox.state == .on
        options.noOwner = noOwnerBox.state == .on
        options.noPrivileges = noPrivilegesBox.state == .on
        options.singleTransaction = singleTransactionBox.state == .on
        options.stopOnError = stopBox.state == .on
        options.otherArguments = otherField.stringValue
    }

    @objc private func optionChanged(_ sender: Any?) {
        readOptions()
        refresh()
    }

    @objc private func targetChanged(_ sender: NSButton) {
        existingRadio.state = sender === existingRadio ? .on : .off
        newRadio.state = sender === newRadio ? .on : .off
        refresh()
    }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.message = "Choose a backup: a pg_dump archive or directory, or a SQL file (plain or .gz)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    /// For the dev harness too.
    func load(_ url: URL) {
        file = url
        fileLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        fileLabel.textColor = .labelColor
        do {
            kind = try BackupFileKind.detect(url)
        } catch {
            kind = nil
            showStatus((error as? DatabaseError)?.message ?? error.localizedDescription, error: true)
        }
        if newNameField.stringValue.isEmpty {
            newNameField.stringValue = String(url.deletingPathExtension().deletingPathExtension().lastPathComponent
                .map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }
        refresh()
    }

    /// Restores into a new database named `name`. For the dev harness.
    func chooseNewDatabase(_ name: String) {
        newRadio.state = .on
        existingRadio.state = .off
        newNameField.stringValue = name
        refresh()
    }

    override func selectionDidChange() {
        databasePopup.removeAllItems()
        loadOptions()
    }

    override func databasesDidLoad() {
        databasePopup.removeAllItems()
        databasePopup.addItems(withTitles: databases)
        if let wanted = preferredDatabase ?? selected?.database, databases.contains(wanted) {
            databasePopup.selectItem(withTitle: wanted)
            preferredDatabase = nil
        }
        refresh()
    }

    private var targetDatabase: String {
        newRadio.state == .on ? newNameField.stringValue.trimmingCharacters(in: .whitespaces) : (databasePopup.titleOfSelectedItem ?? "")
    }

    private var job: RestoreJob? {
        guard let selected, let login, let file, let kind, let tool, !targetDatabase.isEmpty else { return nil }
        return RestoreJob(config: selected, password: login.password, ssh: login.ssh, database: targetDatabase, file: file,
                          kind: kind, options: options, tool: tool)
    }

    override func refresh() {
        guard let selected, let family else {
            titleLabel.stringValue = "Restore"
            toolLabel.stringValue = ""
            commandView.stringValue = ""
            startButton.isEnabled = false
            return
        }
        titleLabel.stringValue = "Restore into \(selected.displayName)"
        databasePopup.isEnabled = existingRadio.state == .on
        newNameField.isEnabled = newRadio.state == .on
        kindLabel.stringValue = kind?.title ?? ""
        tool = nil
        let isArchive = kind?.isPostgresArchive == true
        postgresRow.isHidden = !isArchive
        contentPopup.isEnabled = isArchive
        singleTransactionBox.isEnabled = family == .postgres
        if let kind {
            if let role = RestoreJob.role(for: kind, driver: selected.driver) {
                let (found, warning) = environment.locator().choose(role, serverMajor: serverMajor, mariaDBServer: serverIsMariaDB)
                tool = found
                let name = role == .restorePostgresArchive ? "pg_restore" : role == .restorePostgresScript ? "psql" : "mysql"
                show(tool: found, warning: warning, missing: "\(name) wasn't found on PATH, in the usual install folders or in the folder set in Settings ▸ Locations.")
            } else {
                show(tool: nil, warning: nil, missing: "A \(kind.title) can't be restored into \(selected.driver.displayName).")
            }
        } else {
            toolLabel.stringValue = ""
        }
        if newRadio.state == .on, databases.contains(where: { $0.caseInsensitiveCompare(targetDatabase) == .orderedSame }) {
            commandView.stringValue = "A database named \(targetDatabase) exists already."
            startButton.isEnabled = false
            return
        }
        commandView.stringValue = (try? job?.previewCommand()) ?? (file == nil ? "No file chosen." : "")
        startButton.isEnabled = !isRunning && job != nil && !selected.readOnly
        if selected.readOnly { commandView.stringValue = "\(selected.displayName) is read-only; nothing can be restored into it." }
    }

    override func start() {
        guard let window, let selected, let job else { return }
        readOptions()
        if let key = optionsKey, let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: key) }
        let creating = newRadio.state == .on
        let what = creating ? "a new database, \(job.database)," : job.database
        let level = selected.safeMode
        let prompt = SafetyPrompt(
            title: "Restore \(job.file.lastPathComponent) into \(what) on \(selected.displayName)?",
            message: "Everything in the backup runs against the database\(options.clean ? ", dropping its objects first" : "")."
                + (level.requiresPassword ? " Safe mode asks for the password." : ""),
            sql: (creating ? ServerInfo.createDatabase(job.database, dialect: session?.dialect ?? PostgresDialect()) + ";\n" : "")
                + ((try? job.previewCommand()) ?? ""),
            credential: level.requiresPassword ? SafetyCredential(password: login?.password, connectionName: selected.displayName) : nil,
            connectionName: selected.displayName, confirm: "Restore")
        Task {
            guard await prompt.run(on: window) else { return }
            run(creatingDatabase: creating)
        }
    }

    /// Restores with the options shown. The dev harness calls this directly (no confirmation).
    func run(creatingDatabase: Bool? = nil) {
        readOptions()
        guard let job, !isRunning else { return }
        let creating = creatingDatabase ?? (newRadio.state == .on)
        let session = session
        began()
        revealURLs = []
        showStatus("Restoring…", error: false)
        let id = selected?.id
        runTask = Task {
            let result: Result<Void, any Error>
            do {
                if creating, let session {
                    let create = ServerInfo.createDatabase(job.database, dialect: session.dialect)
                    appendLog(create + ";")
                    _ = try await session.execute(SQLStatement(create))
                }
                try await job.run { line in Task { @MainActor in self.appendLog(line) } }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            if creating, case .success = result, !databases.contains(job.database) {
                databases.append(job.database)
                databases.sort()
                databasePopup.removeAllItems()
                databasePopup.addItems(withTitles: databases)
                databasePopup.selectItem(withTitle: job.database)
                existingRadio.state = .on
                newRadio.state = .off
            }
            if let id { environment.onRestored(id) }
            ended(result, success: "Restored \(job.file.lastPathComponent) into \(job.database).")
        }
    }
}

extension RestoreWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { optionChanged(nil) }
}

extension NSStackView {
    /// The stack, laid out top to bottom.
    func vertical() -> NSStackView {
        orientation = .vertical
        alignment = .leading
        spacing = 6
        return self
    }
}
