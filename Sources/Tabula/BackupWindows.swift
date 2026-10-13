import AppCore
import AppKit
import DBKit

/// What the Backup and Restore windows need from the app.
@MainActor
struct ToolWindowEnvironment {
    /// The saved connections; the windows list the ones the tools work with.
    var store: ConnectionStore
    /// The database password and SSH login for a connection, asking if its mode says so; nil
    /// when the user cancels.
    var login: (ConnectionConfig, NSWindow?) async -> (password: String?, ssh: SSHLogin)?
    var locator: () -> ToolLocator
    /// After a restore or a new database: workspaces of that connection reload their lists.
    var onRestored: (UUID) -> Void = { _ in }
    /// Settings ▸ Locations.
    var showLocations: () -> Void = {}
}

/// The parts Backup and Restore share: the saved connections and the selected one's databases
/// side by side, each under a search field; a column of options on the right; the tool in use
/// and the buttons along the bottom. A run shows its log in a sheet.
@MainActor
class ToolWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSTokenFieldDelegate {
    let environment: ToolWindowEnvironment
    let connections: ConnectionList
    /// The selected connection's login and a session for reading its databases.
    private(set) var selected: ConnectionConfig?
    private(set) var login: (password: String?, ssh: SSHLogin)?
    private(set) var session: (any DatabaseConnection)?
    /// Every database on the selected connection's server.
    private(set) var databases: [String] = []
    /// Those the search leaves.
    private var shownDatabases: [String] = []
    private(set) var serverMajor: Int?
    private(set) var serverIsMariaDB = false
    private var loadTask: Task<Void, Never>?
    /// The database to select when the list loads (File ▸ Backup… from a workspace).
    var preferredDatabase: String?
    private(set) var runSheet: ToolRunSheet?
    var runTask: Task<Void, Never>?
    /// For the dev harness: when a run ends.
    var onFinish: ((Result<Void, any Error>) -> Void)?

    let connectionSearch = NSSearchField()
    let databaseSearch = NSSearchField()
    let databaseTable = NSTableView()
    private let databaseNote = NSTextField(wrappingLabelWithString: "")
    let toolLabel = NSTextField(wrappingLabelWithString: "")
    private let locationsButton = NSButton(title: "Locations…", target: nil, action: nil)

    // The options column: popups above, then the tool's flags as tokens.
    let addOptionMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let tokenField = NSTokenField()
    let optionsNote = NSTextField(wrappingLabelWithString: "")

    init(title: String, autosave: String, environment: ToolWindowEnvironment) {
        self.environment = environment
        connections = ConnectionList(store: environment.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = title
        window.minSize = NSSize(width: 700, height: 400)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        connections.emptyText = "No saved PostgreSQL, MySQL or MariaDB connections."
        connections.include = { [.postgres, .mysql, .mariadb].contains($0.driver) }
        connections.onSelectionChange = { [weak self] in self?.connectionSelectionChanged() }
        window.setFrameAutosaveName(autosave)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the window out: `header` above the lists (Backup's file name), `options` at the top
    /// of the right-hand column, `buttons` at the bottom right.
    func build(header: NSView?, options: [NSView], buttons: [NSButton]) {
        guard let window else { return }
        connectionSearch.placeholderString = "Search connections"
        connectionSearch.delegate = self
        databaseSearch.placeholderString = "Search databases"
        databaseSearch.delegate = self

        let connectionScroll = connections.scrollView
        connectionScroll.borderType = .bezelBorder
        connectionScroll.drawsBackground = true
        connectionScroll.backgroundColor = .controlBackgroundColor
        connections.outline.style = .plain
        connections.outline.rowSizeStyle = .default

        let column = NSTableColumn(identifier: .init("database"))
        databaseTable.addTableColumn(column)
        databaseTable.headerView = nil
        databaseTable.rowHeight = 22
        databaseTable.style = .plain
        databaseTable.dataSource = self
        databaseTable.delegate = self
        let databaseScroll = NSScrollView()
        databaseScroll.documentView = databaseTable
        databaseScroll.hasVerticalScroller = true
        databaseScroll.borderType = .bezelBorder
        databaseNote.alignment = .center
        databaseNote.textColor = .secondaryLabelColor
        databaseNote.font = .systemFont(ofSize: 12)
        databaseNote.translatesAutoresizingMaskIntoConstraints = false
        databaseScroll.addSubview(databaseNote)
        NSLayoutConstraint.activate([
            databaseNote.centerXAnchor.constraint(equalTo: databaseScroll.centerXAnchor),
            databaseNote.centerYAnchor.constraint(equalTo: databaseScroll.centerYAnchor),
            databaseNote.widthAnchor.constraint(lessThanOrEqualTo: databaseScroll.widthAnchor, constant: -30),
        ])

        func pane(_ search: NSSearchField, _ list: NSView) -> NSView {
            let stack = NSStackView(views: [search, list])
            stack.orientation = .vertical
            stack.spacing = 8
            for v in [search, list] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            list.setContentHuggingPriority(.init(1), for: .vertical)
            return stack
        }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(pane(connectionSearch, connectionScroll))
        split.addArrangedSubview(pane(databaseSearch, databaseScroll))
        split.setHoldingPriority(.init(251), forSubviewAt: 0)

        addOptionMenu.addItem(withTitle: "Add Option")
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        tokenField.placeholderString = "Options"
        tokenField.delegate = self
        tokenField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        (tokenField.cell as? NSTokenFieldCell)?.wraps = true
        (tokenField.cell as? NSTokenFieldCell)?.isScrollable = false
        tokenField.setContentHuggingPriority(.init(1), for: .vertical)
        optionsNote.font = .systemFont(ofSize: 11)
        optionsNote.textColor = .systemRed
        optionsNote.isHidden = true
        let side = NSStackView(views: options + [addOptionMenu, tokenField, optionsNote])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        side.setHuggingPriority(.init(1), for: .vertical)
        for v in side.arrangedSubviews { v.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true }
        side.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let middle = NSStackView(views: [split, side])
        middle.alignment = .top
        middle.distribution = .fill
        middle.spacing = 12
        split.setContentHuggingPriority(.init(1), for: .horizontal)
        split.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        split.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        side.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        middle.setHuggingPriority(.init(1), for: .vertical)

        toolLabel.font = .systemFont(ofSize: 11)
        toolLabel.textColor = .secondaryLabelColor
        toolLabel.maximumNumberOfLines = 2
        toolLabel.lineBreakMode = .byTruncatingTail
        toolLabel.cell?.truncatesLastVisibleLine = true
        toolLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationsButton.target = self
        locationsButton.action = #selector(showLocations(_:))
        locationsButton.controlSize = .small
        locationsButton.isHidden = true
        let bottom = NSStackView(views: [toolLabel, locationsButton, NSView()] + buttons)
        bottom.alignment = .centerY
        bottom.spacing = 8

        let main = NSStackView(views: (header.map { [$0] } ?? []) + [middle, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for v in main.arrangedSubviews { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -40).isActive = true }
        window.contentView = main
        window.initialFirstResponder = connections.outline
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        DispatchQueue.main.async { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
    }

    // MARK: - Connections

    /// Selects connection `id` (or keeps the selection).
    func reloadConnections(select id: UUID? = nil) {
        connections.reload(select: id)
    }

    private func connectionSelectionChanged() {
        let config = connections.selectedConnection
        guard config?.id != selected?.id || (config != nil && session == nil && loadTask == nil) else { return }
        loadTask?.cancel()
        loadTask = nil
        let old = session
        session = nil
        if let old { Task { await old.close() } }
        databases = []
        login = nil
        serverMajor = nil
        serverIsMariaDB = false
        selected = config
        reloadDatabases()
        selectionDidChange()
        guard let config else { return }
        showDatabaseNote("Connecting to \(config.displayName)…")
        loadTask = Task {
            defer { if selected?.id == config.id { loadTask = nil } }
            guard let login = await environment.login(config, window) else {
                if selected?.id == config.id { showDatabaseNote("Not connected.") }
                return
            }
            do {
                let session = try await ConnectionFactory.open(config, password: login.password, ssh: login.ssh)
                guard !Task.isCancelled, selected?.id == config.id else {
                    await session.close()
                    return
                }
                let list = try await ServerInfo.databases(session)
                let (major, maria) = ServerInfo.version(session)
                guard !Task.isCancelled, selected?.id == config.id else {
                    await session.close()
                    return
                }
                self.login = login
                self.session = session
                databases = list
                serverMajor = major
                serverIsMariaDB = maria
                let wanted = preferredDatabase ?? (config.database.isEmpty ? nil : config.database)
                preferredDatabase = nil
                reloadDatabases(select: wanted)
                databasesDidLoad()
            } catch {
                if !Task.isCancelled, selected?.id == config.id {
                    showDatabaseNote("Couldn't connect: \((error as? DatabaseError)?.message ?? error.localizedDescription)", error: true)
                }
            }
        }
    }

    /// Subclasses refresh their forms.
    func selectionDidChange() {}
    func databasesDidLoad() {}
    func refresh() {}
    func start() {}

    var family: DumpTool.Family? {
        guard let selected else { return nil }
        return selected.driver == .postgres ? .postgres : .mysql
    }

    // MARK: - Databases

    var selectedDatabase: String? { shownDatabases[safe: databaseTable.selectedRow] }

    /// Selects a database by name. For the dev harness too.
    func select(database name: String) {
        if !shownDatabases.contains(name) { databaseSearch.stringValue = "" }
        reloadDatabases(select: name)
    }

    /// Adds a database the window just created and selects it.
    func added(database name: String) {
        if !databases.contains(name) {
            databases.append(name)
            databases.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        select(database: name)
    }

    private func reloadDatabases(select name: String? = nil) {
        let keep = name ?? selectedDatabase
        let query = databaseSearch.stringValue.trimmingCharacters(in: .whitespaces)
        shownDatabases = query.isEmpty ? databases : databases.filter { $0.localizedCaseInsensitiveContains(query) }
        databaseTable.reloadData()
        if let keep, let row = shownDatabases.firstIndex(of: keep) {
            databaseTable.selectRowIndexes([row], byExtendingSelection: false)
            databaseTable.scrollRowToVisible(row)
        } else {
            databaseTable.deselectAll(nil)
        }
        if selected == nil {
            showDatabaseNote("")
        } else if session != nil {
            showDatabaseNote(shownDatabases.isEmpty ? (query.isEmpty ? "No databases." : "Nothing matches “\(query)”.") : "")
        }
        refresh()
    }

    private func showDatabaseNote(_ text: String, error: Bool = false) {
        databaseNote.stringValue = text
        databaseNote.textColor = error ? .systemRed : .secondaryLabelColor
        databaseNote.isHidden = text.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownDatabases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: DatabaseCell.identifier, owner: nil) as? DatabaseCell ?? DatabaseCell()
        cell.textField?.stringValue = shownDatabases[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === connectionSearch {
            connections.query = connectionSearch.stringValue
        } else if obj.object as? NSSearchField === databaseSearch {
            reloadDatabases()
        } else if obj.object as? NSTokenField === tokenField {
            tokensChanged(normalize: false)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTokenField === tokenField { tokensChanged(normalize: true) }
    }

    // MARK: - Options as tokens

    /// The flags Add Option offers.
    func fillOptionMenu(_ flags: [String]) {
        while addOptionMenu.numberOfItems > 1 { addOptionMenu.removeItem(at: 1) }
        for flag in flags {
            let item = addOptionMenu.menu!.addItem(withTitle: flag, action: #selector(addOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = flag
        }
        addOptionMenu.isEnabled = !flags.isEmpty
    }

    @objc private func addOption(_ sender: NSMenuItem) {
        guard let flag = sender.representedObject as? String else { return }
        var tokens = currentTokens
        if !tokens.contains(flag) { tokens.append(flag) }
        tokenField.objectValue = tokens
        tokensChanged(normalize: true)
    }

    var currentTokens: [String] {
        ((tokenField.objectValue as? [Any]) ?? []).map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The tokens changed: subclasses read them into their options (throwing on a bad quote),
    /// and `normalize` shows them again as the options give them.
    func tokensChanged(normalize: Bool) {
        do {
            try apply(tokens: currentTokens)
            optionsNote.isHidden = true
            if normalize { tokenField.objectValue = tokens() }
        } catch {
            optionsNote.stringValue = (error as? DatabaseError)?.message ?? error.localizedDescription
            optionsNote.isHidden = false
        }
        refresh()
    }

    var tokensAreValid: Bool { optionsNote.isHidden }

    func apply(tokens: [String]) throws {}
    func tokens() -> [String] { [] }

    // MARK: - Tool

    /// Shows which tool runs, or why none can.
    func show(tool: ToolInfo?, warning: String?, missing: String) {
        if let tool {
            toolLabel.stringValue = "\(tool.tool.rawValue) \(tool.versionString)\(tool.isMariaDB ? " (MariaDB)" : "")" + (warning.map { " — " + $0 } ?? "")
            toolLabel.toolTip = tool.path + (warning.map { "\n" + $0 } ?? "")
            toolLabel.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        } else {
            toolLabel.stringValue = missing
            toolLabel.toolTip = missing
            toolLabel.textColor = .systemRed
        }
        offerLocations(tool == nil || warning != nil)
    }

    /// Settings ▸ Locations is offered when a tool is missing or not the right one.
    func offerLocations(_ shown: Bool) { locationsButton.isHidden = !shown }

    func clearTool() {
        toolLabel.stringValue = ""
        toolLabel.toolTip = nil
        locationsButton.isHidden = true
    }

    // MARK: - Running

    var isRunning: Bool { runTask != nil }

    /// Shows the log sheet and runs `body` with a way to log to it; `success` is the sheet's last
    /// line when it works, `reveal` a file to offer in the Finder.
    func run(title: String, success: @escaping () -> String, reveal: URL? = nil,
             _ body: @escaping (@escaping @Sendable (String) -> Void) async throws -> Void) {
        guard let window, !isRunning else { return }
        let sheet = ToolRunSheet(title: title)
        runSheet = sheet
        sheet.onStop = { [weak self] in self?.runTask?.cancel() }
        sheet.onDone = { [weak self, weak window] in
            if let s = self?.runSheet?.sheet { window?.endSheet(s) }
            self?.runSheet = nil
        }
        window.beginSheet(sheet.sheet)
        refresh()
        runTask = Task {
            let result: Result<Void, any Error>
            do {
                try await body { line in Task { @MainActor in sheet.append(line) } }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // Lines the tool printed last are still on their way to the main actor.
            await Task.yield()
            runTask = nil
            sheet.finish(result, success: success(), reveal: reveal)
            refresh()
            onFinish?(result)
        }
    }

    @objc private func showLocations(_ sender: Any?) { environment.showLocations() }

    @objc func startClicked(_ sender: Any?) { start() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop and close?"
        alert.informativeText = "The tool is still running; closing stops it."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: runSheet?.sheet ?? sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runTask?.cancel()
            self?.runSheet?.onDone()
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        if let session { Task { await session.close() } }
        session = nil
        selected = nil
        databases = []
        connections.outline.deselectAll(nil)
    }

    static func popup(_ titles: [String], _ target: AnyObject, _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = target
        p.action = action
        return p
    }
}

/// A database in the list: a cylinder and its name.
private final class DatabaseCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ToolDatabaseCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let glyph = NSImageView(image: NSImage(systemSymbolName: "cylinder", accessibilityDescription: nil)!)
        glyph.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        glyph.contentTintColor = .controlAccentColor
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [glyph, name])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
        addSubview(row)
        row.pin(to: self)
        textField = name
        imageView = glyph
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The sheet a run shows: what's running, the command and every line the tool prints, and Stop;
/// then how it ended, with Done (and Show in Finder after a backup).
@MainActor
final class ToolRunSheet: NSObject {
    let sheet: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let logView = NSTextView()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var reveal: URL?
    var onStop: () -> Void = {}
    var onDone: () -> Void = {}
    private(set) var finished = false

    init(title: String) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        sheet.minSize = NSSize(width: 460, height: 260)
        super.init()
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        revealButton.target = self
        revealButton.action = #selector(showInFinder(_:))
        revealButton.isHidden = true
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.isHidden = true

        let top = NSStackView(views: [titleLabel, spinner])
        top.spacing = 8
        let buttons = NSStackView(views: [NSView(), revealButton, stopButton, doneButton])
        let main = NSStackView(views: [top, scroll, buttons])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for v in [scroll, buttons] { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -36).isActive = true }
        sheet.contentView = main
    }

    func append(_ line: String, color: NSColor? = nil) {
        let storage = logView.textStorage!
        let atEnd = logView.visibleRect.maxY >= logView.bounds.maxY - 4
        storage.append(NSAttributedString(string: line + "\n", attributes: [
            .font: logView.font ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: color ?? (line.hasPrefix("$ ") ? NSColor.labelColor : NSColor.secondaryLabelColor),
        ]))
        // Keep the log from growing without bound on chatty tools.
        if storage.length > 400_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 300_000)) }
        if atEnd { logView.scrollToEndOfDocument(nil) }
    }

    func finish(_ result: Result<Void, any Error>, success: String, reveal: URL?) {
        finished = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        stopButton.isHidden = true
        doneButton.isHidden = false
        doneButton.keyEquivalent = "\r"
        switch result {
        case .success:
            append(success, color: .labelColor)
            self.reveal = reveal
            revealButton.isHidden = reveal == nil
        case .failure(let error) where error is CancellationError:
            append("Stopped.", color: .labelColor)
        case .failure(let error):
            append((error as? DatabaseError)?.message ?? error.localizedDescription, color: .systemRed)
        }
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func stop(_ sender: Any?) {
        stopButton.isEnabled = false
        onStop()
    }

    @objc private func showInFinder(_ sender: Any?) {
        if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
    }

    @objc private func done(_ sender: Any?) { onDone() }
}

// MARK: - Backup

/// File ▸ Backup… (and the welcome window): one database of a saved connection to a file, with
/// pg_dump or mysqldump.
@MainActor
final class BackupWindowController: ToolWindowController {
    private var options = BackupOptions()
    private var tool: ToolInfo?

    let fileName = FileNamePatternRow(pattern: UserDefaults.standard.string(forKey: "Backup.pattern") ?? FileNamePattern.backup,
                                      defaultPattern: FileNamePattern.backup,
                                      tokens: FileNamePattern.tokens.filter { $0.placeholder != "{table}" })
    private var formatPopup: NSPopUpButton!
    private var contentPopup: NSPopUpButton!
    private let gzipBox = NSButton(checkboxWithTitle: "Compress with gzip", target: nil, action: nil)
    private let startButton = NSButton(title: "Back Up…", target: nil, action: nil)

    init(environment: ToolWindowEnvironment) {
        super.init(title: "Back Up Database", autosave: "BackupWindow", environment: environment)
        fileName.preview = { [weak self] in self?.fileName(for: $0) ?? $0 }
        fileName.onChange = { [weak self] in if let p = self?.fileName.pattern { UserDefaults.standard.set(p, forKey: "Backup.pattern") } }
        let header = NSStackView(views: [NSTextField(labelWithString: "File name:"), fileName])
        header.alignment = .firstBaseline
        header.spacing = 8

        formatPopup = Self.popup(BackupOptions.PostgresFormat.allCases.map(\.title), self, #selector(optionChanged(_:)))
        contentPopup = Self.popup(BackupOptions.Content.allCases.map(\.title), self, #selector(optionChanged(_:)))
        gzipBox.target = self
        gzipBox.action = #selector(optionChanged(_:))
        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        startButton.keyEquivalent = "\r"
        build(header: header, options: [formatPopup, contentPopup, gzipBox], buttons: [startButton])
        loadOptions()
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
        fillOptionMenu(family.map(ToolFlags.backupMenu) ?? [])
        showOptions()
    }

    /// Puts the options into the controls.
    private func showOptions() {
        formatPopup.selectItem(at: BackupOptions.PostgresFormat.allCases.firstIndex(of: options.postgresFormat) ?? 0)
        contentPopup.selectItem(at: BackupOptions.Content.allCases.firstIndex(of: options.content) ?? 0)
        gzipBox.state = options.gzip ? .on : .off
        tokenField.objectValue = tokens()
        optionsNote.isHidden = true
        refresh()
    }

    override func tokens() -> [String] { family.map(options.tokens) ?? [] }

    override func apply(tokens: [String]) throws {
        guard let family else { return }
        let before = (options.postgresFormat, options.content)
        try options.setTokens(tokens, family)
        // A format or content typed as a token moves to its popup.
        if before != (options.postgresFormat, options.content) { showOptions() }
    }

    private func saveOptions() {
        if let key = optionsKey, let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: key) }
    }

    @objc private func optionChanged(_ sender: Any?) {
        options.postgresFormat = BackupOptions.PostgresFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
        options.content = BackupOptions.Content.allCases[max(0, contentPopup.indexOfSelectedItem)]
        options.gzip = gzipBox.state == .on
        refresh()
    }

    /// The name a pattern gives the selected database (placeholder names before one is chosen).
    private func fileName(for pattern: String) -> String {
        let database = selectedDatabase ?? "database"
        let name = FileNamePattern(pattern).render(.init(database: database, connection: selected?.displayName ?? "connection",
                                                         tag: selected?.tag?.rawValue ?? ""), fallback: database)
        let ext = options.fileExtension(family ?? .postgres)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    override func selectionDidChange() { loadOptions() }

    override func databasesDidLoad() { refresh() }

    private var job: BackupJob? {
        guard let selected, let tool, let login, let database = selectedDatabase else { return nil }
        return BackupJob(config: selected, password: login.password, ssh: login.ssh, database: database, options: options,
                         tool: tool, serverIsMariaDB: serverIsMariaDB)
    }

    override func refresh() {
        fileName.refresh()
        guard let family else {
            clearTool()
            startButton.isEnabled = false
            return
        }
        let isPostgres = family == .postgres
        formatPopup.isHidden = !isPostgres
        // pg_dump compresses its archives itself; gzip is for scripts.
        gzipBox.isEnabled = !isPostgres || options.postgresFormat == .plain
        if login != nil {
            let (found, warning) = environment.locator().choose(isPostgres ? .backupPostgres : .backupMySQL, serverMajor: serverMajor,
                                                                mariaDBServer: serverIsMariaDB)
            tool = found
            show(tool: found, warning: warning, missing: isPostgres
                ? "pg_dump wasn't found on PATH, in the usual install folders or in the folder set in Settings ▸ Locations."
                : "mysqldump wasn't found on PATH, in the usual install folders or in the folder set in Settings ▸ Locations.")
        } else {
            tool = nil
            clearTool()
        }
        startButton.isEnabled = !isRunning && job != nil && tokensAreValid
    }

    // MARK: Running

    override func start() {
        guard let window, let job, tokensAreValid else { return }
        saveOptions()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.fileName(FileNamePattern(fileName.pattern))
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Back Up"
        panel.message = "Back up \(job.database) on \(job.config.displayName)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // The panel's sheet is still closing; the log sheet goes up after it.
            DispatchQueue.main.async { self?.run(to: url) }
        }
    }

    /// Backs up the selected database to `file`. The dev harness calls this directly.
    func run(to file: URL) {
        guard let job, tokensAreValid, !isRunning else { return }
        saveOptions()
        run(title: "Backing up \(job.database) on \(job.config.displayName)",
            success: { "Backed up \(job.database) to \(file.lastPathComponent)." }, reveal: file) { log in
            try await job.run(to: file, log: log)
        }
    }
}

// MARK: - Restore

/// File ▸ Restore… (and the welcome window): a backup file into a database of a saved
/// connection, with pg_restore, psql or mysql. The database is chosen (or created) first, the
/// file when it starts.
@MainActor
final class RestoreWindowController: ToolWindowController {
    private var options = RestoreOptions()
    private var contentPopup: NSPopUpButton!
    private let contentNote = NSTextField(wrappingLabelWithString: "For pg_dump archives.")
    private let newButton = NSButton(title: "New Database…", target: nil, action: nil)
    private let startButton = NSButton(title: "Restore…", target: nil, action: nil)
    /// The sheet asking for a new database's name, for the dev harness.
    private(set) var newDatabaseSheet: NewDatabaseSheet?

    init(environment: ToolWindowEnvironment) {
        super.init(title: "Restore Database", autosave: "RestoreWindow", environment: environment)
        contentPopup = Self.popup(BackupOptions.Content.allCases.map(\.title), self, #selector(optionChanged(_:)))
        contentNote.font = .systemFont(ofSize: 11)
        contentNote.textColor = .secondaryLabelColor
        newButton.target = self
        newButton.action = #selector(newDatabase(_:))
        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        startButton.keyEquivalent = "\r"
        build(header: nil, options: [contentPopup, contentNote], buttons: [newButton, startButton])
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
        fillOptionMenu(family.map(ToolFlags.restoreMenu) ?? [])
        showOptions()
    }

    private func showOptions() {
        contentPopup.selectItem(at: BackupOptions.Content.allCases.firstIndex(of: options.content) ?? 0)
        tokenField.objectValue = tokens()
        optionsNote.isHidden = true
        refresh()
    }

    override func tokens() -> [String] { family.map(options.tokens) ?? [] }

    override func apply(tokens: [String]) throws {
        guard let family else { return }
        let before = options.content
        try options.setTokens(tokens, family)
        if before != options.content { showOptions() }
    }

    @objc private func optionChanged(_ sender: Any?) {
        options.content = BackupOptions.Content.allCases[max(0, contentPopup.indexOfSelectedItem)]
        refresh()
    }

    override func selectionDidChange() { loadOptions() }

    override func databasesDidLoad() { refresh() }

    override func refresh() {
        guard let selected, let family else {
            clearTool()
            newButton.isEnabled = false
            startButton.isEnabled = false
            return
        }
        // Content picks parts of an archive; scripts run whole.
        contentPopup.isHidden = family != .postgres
        contentNote.isHidden = family != .postgres
        if selected.readOnly {
            show(tool: nil, warning: nil, missing: "\(selected.displayName) is read-only; nothing can be restored into it.")
        } else if login != nil {
            // pg_restore takes archives, psql scripts; either may be missing.
            let roles: [(ToolLocator.Role, String)] = family == .postgres
                ? [(.restorePostgresArchive, "pg_restore"), (.restorePostgresScript, "psql")] : [(.restoreMySQL, "mysql")]
            let found = roles.map { role, name in (name, environment.locator().choose(role, serverMajor: serverMajor, mariaDBServer: serverIsMariaDB)) }
            let tools = found.compactMap(\.1.0)
            let missing = found.filter { $0.1.0 == nil }.map(\.0)
            let warnings = found.compactMap(\.1.1) + missing.map { "\($0) wasn't found on PATH, in the usual install folders or in the folder set in Settings ▸ Locations." }
            toolLabel.stringValue = (tools.map { "\($0.tool.rawValue) \($0.versionString)" } + warnings).joined(separator: " — ")
            toolLabel.toolTip = (tools.map(\.path) + warnings).joined(separator: "\n")
            toolLabel.textColor = tools.isEmpty ? .systemRed : warnings.isEmpty ? .secondaryLabelColor : .systemOrange
            offerLocations(!warnings.isEmpty)
        } else {
            clearTool()
        }
        let ready = !isRunning && session != nil && !selected.readOnly
        newButton.isEnabled = ready
        startButton.isEnabled = ready && selectedDatabase != nil && tokensAreValid
    }

    // MARK: New database

    @objc private func newDatabase(_ sender: Any?) {
        guard let window, session != nil else { return }
        let sheet = NewDatabaseSheet(existing: databases) { [weak self] name in
            guard let self else { return false }
            return await self.createDatabase(name)
        }
        newDatabaseSheet = sheet
        window.beginSheet(sheet.sheet) { [weak self] _ in self?.newDatabaseSheet = nil }
    }

    /// Creates a database on the selected connection, as safe mode allows, and selects it.
    /// False when it wasn't created (the sheet stays open). For the dev harness too.
    @discardableResult
    func createDatabase(_ name: String) async -> Bool {
        guard let window, let selected, let session, !selected.readOnly else { return false }
        let sql = ServerInfo.createDatabase(name, dialect: session.dialect)
        let level = selected.safeMode
        if level.requirement(for: [sql], dialect: session.dialect.lexer) != .none {
            let prompt = SafetyPrompt(
                title: "Create the database \(name) on \(selected.displayName)?", message: level.detail, sql: sql + ";",
                credential: level.requiresPassword ? SafetyCredential(password: login?.password, connectionName: selected.displayName) : nil,
                connectionName: selected.displayName, confirm: "Create")
            guard await prompt.run(on: newDatabaseSheet?.sheet ?? window) else { return false }
        }
        do {
            _ = try await session.execute(SQLStatement(sql))
        } catch {
            newDatabaseSheet?.show(error: (error as? DatabaseError)?.message ?? error.localizedDescription)
            return false
        }
        added(database: name)
        environment.onRestored(selected.id)
        return true
    }

    // MARK: Running

    override func start() {
        guard let window, selectedDatabase != nil, tokensAreValid else { return }
        if let key = optionsKey, let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: key) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Restore"
        panel.message = "Choose a backup: a pg_dump archive or directory, or a SQL script (plain or .gz)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { self?.confirm(url) }
        }
    }

    /// The job for `file` into the selected database, or why there's none.
    func job(for file: URL) -> Result<RestoreJob, DatabaseError> {
        guard let selected, let login, let database = selectedDatabase else { return .failure(DatabaseError("No database is selected.")) }
        let kind: BackupFileKind
        do {
            kind = try BackupFileKind.detect(file)
        } catch {
            return .failure(error as? DatabaseError ?? DatabaseError(error.localizedDescription))
        }
        guard let role = RestoreJob.role(for: kind, driver: selected.driver) else {
            return .failure(DatabaseError("A \(kind.title) can't be restored into \(selected.driver.displayName)."))
        }
        let name = role == .restorePostgresArchive ? "pg_restore" : role == .restorePostgresScript ? "psql" : "mysql"
        guard let tool = environment.locator().choose(role, serverMajor: serverMajor, mariaDBServer: serverIsMariaDB).0 else {
            return .failure(DatabaseError("\(name) wasn't found on PATH, in the usual install folders or in the folder set in Settings ▸ Locations."))
        }
        return .success(RestoreJob(config: selected, password: login.password, ssh: login.ssh, database: database, file: file, kind: kind,
                                   options: options, tool: tool))
    }

    /// Asks before restoring `file`, showing the command.
    private func confirm(_ file: URL) {
        guard let window, let selected else { return }
        let job: RestoreJob
        switch self.job(for: file) {
        case .success(let j): job = j
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "\(file.lastPathComponent) can't be restored"
            alert.informativeText = error.message
            alert.beginSheetModal(for: window)
            return
        }
        let level = selected.safeMode
        let prompt = SafetyPrompt(
            title: "Restore \(file.lastPathComponent) into \(job.database) on \(selected.displayName)?",
            message: "Everything in the backup (\(job.kind.title)) runs against the database\(options.clean ? ", dropping its objects first" : "")."
                + (level.requiresPassword ? " Safe mode asks for the password." : ""),
            sql: (try? job.previewCommand()) ?? "",
            credential: level.requiresPassword ? SafetyCredential(password: login?.password, connectionName: selected.displayName) : nil,
            connectionName: selected.displayName, confirm: "Restore")
        Task {
            guard await prompt.run(on: window) else { return }
            run(job)
        }
    }

    /// Restores without asking. The dev harness calls this directly.
    func run(_ job: RestoreJob) {
        let id = job.config.id
        run(title: "Restoring \(job.file.lastPathComponent) into \(job.database) on \(job.config.displayName)",
            success: { "Restored \(job.file.lastPathComponent) into \(job.database)." }) { [weak self] log in
            defer { Task { @MainActor in self?.environment.onRestored(id) } }
            try await job.run(log: log)
        }
    }
}

/// Asks for a new database's name. `create` makes it; the sheet closes when that works.
@MainActor
final class NewDatabaseSheet: NSObject, NSTextFieldDelegate {
    let sheet: NSWindow
    let nameField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let existing: [String]
    private let create: (String) async -> Bool

    init(existing: [String], create: @escaping (String) async -> Bool) {
        self.existing = existing
        self.create = create
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        let title = NSTextField(labelWithString: "New Database")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.placeholderString = "Name"
        nameField.delegate = self
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(createClicked(_:))
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false
        let row = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField])
        row.alignment = .firstBaseline
        let buttons = NSStackView(views: [NSView(), cancel, createButton])
        let main = NSStackView(views: [title, row, errorLabel, buttons])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for v in [row, errorLabel, buttons] { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -36).isActive = true }
        sheet.contentView = main
        sheet.initialFirstResponder = nameField
    }

    func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
    }

    private var name: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    func controlTextDidChange(_ obj: Notification) {
        let taken = existing.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        errorLabel.stringValue = taken ? "A database named \(name) exists already." : ""
        errorLabel.isHidden = !taken
        createButton.isEnabled = !name.isEmpty && !taken
    }

    @objc private func createClicked(_ sender: Any?) {
        let name = name
        createButton.isEnabled = false
        Task {
            if await create(name) {
                sheet.sheetParent?.endSheet(sheet)
            } else {
                createButton.isEnabled = true
            }
        }
    }

    @objc private func cancel(_ sender: Any?) { sheet.sheetParent?.endSheet(sheet) }
}
