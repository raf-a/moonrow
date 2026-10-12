import AppCore
import AppKit
import DBKit
import SQLScript

/// A floating search list over a window, like Spotlight: type to filter, ↑ ↓ to move, Return
/// (or a double-click) to choose, Esc or a click elsewhere to close. Quick Open (⌘P) and Open
/// Database (⌘K) use it.
@MainActor
final class PickerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Row {
        var title: String
        var detail: String
        var symbol: String
        var tint: NSColor = .secondaryLabelColor
    }

    /// The rows for what's typed, best first.
    var rowsFor: (String) -> [Row] = { _ in [] }
    /// The chosen row's index in the list shown.
    var onChoose: ((Int) -> Void)?
    var onClose: (() -> Void)?

    let panel: NSPanel
    let field = NSSearchField()
    let table = NSTableView()
    private let note = NSTextField(labelWithString: "")
    private(set) var rows: [Row] = []

    init(placeholder: String) {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.delegate = self

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        (field.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        for v in [field, scroll, note] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -4),
            note.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            note.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -14),
            note.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
        panel.contentView = background
    }

    /// Shows the panel near the top of `window`, over its content.
    func show(over window: NSWindow) {
        let size = panel.frame.size
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 70))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        refresh()
    }

    var isVisible: Bool { panel.isVisible }

    /// Filters again (after the field changes or more items arrive), keeping the first row selected.
    func refresh() {
        rows = rowsFor(field.stringValue)
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    /// A line under the list (loading, nothing found, …).
    func setNote(_ text: String) { note.stringValue = text }

    /// `restoreKey` gives the window under it the keyboard back (Esc, Return); a click
    /// elsewhere leaves the key window to whatever was clicked.
    func close(restoreKey: Bool = false) {
        guard panel.isVisible || panel.parent != nil else { return }
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreKey { parent?.makeKey() }
        onClose?()
    }

    func choose() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        close(restoreKey: true)
        onChoose?(row)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        choose()
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), rows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: 10)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -10)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close(restoreKey: true)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PickerCell.identifier, owner: nil) as? PickerCell ?? PickerCell()
        cell.show(rows[row])
        return cell
    }
}

/// A borderless-looking panel that still takes key status, so its field can be typed in.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PickerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, title, NSView(), detail])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addSubview(row)
        row.pin(to: self)
        textField = title
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: PickerPanel.Row) {
        title.stringValue = row.title
        detail.stringValue = row.detail
        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        icon.contentTintColor = row.tint
    }
}

// MARK: - Quick Open and Open Database

extension WorkspaceWindowController {
    /// ⌘P: every table, view, materialized view and function in every schema, and the saved
    /// queries. Return opens the choice in a regular tab; a function is shown in the sidebar.
    @objc func quickOpen(_ sender: Any?) {
        guard let window else { return }
        picker?.close()
        let panel = PickerPanel(placeholder: "Open a table, view, function or saved query")
        var shown: [QuickOpen.Item] = []
        panel.rowsFor = { [weak self] query in
            guard let self else { return [] }
            shown = QuickOpen.rank(self.quickOpenItems + self.savedQueryItems, query: query,
                                   currentSchema: self.sidebar.schema, recent: self.quickOpenRecent)
            return shown.map { item in
                let (symbol, tint): (String, NSColor) = switch item.kind {
                case .table: ("tablecells", .systemBlue)
                case .view, .materializedView: ("eye", .systemPurple)
                case .function: ("function", .systemOrange)
                case .savedQuery: ("terminal", .secondaryLabelColor)
                }
                let detail = item.kind == .savedQuery ? "Saved query" : item.schema ?? ""
                return PickerPanel.Row(title: item.name, detail: detail, symbol: symbol, tint: tint)
            }
        }
        panel.onChoose = { [weak self] i in
            guard let self, shown.indices.contains(i) else { return }
            self.quickOpenChose(shown[i])
        }
        panel.onClose = { [weak self, weak panel] in if self?.picker === panel { self?.picker = nil } }
        picker = panel
        panel.show(over: window)
        loadQuickOpenItems(into: panel)
    }

    /// Better matches first, then alphabetically; everything when nothing is typed.
    private static func rankNames(_ names: [String], query: String) -> [String] {
        guard !query.isEmpty else { return names }
        var matched: [(name: String, tier: Int)] = []
        for name in names {
            if let tier = SQLCompletion.matchTier(name, query: query) { matched.append((name, tier)) }
        }
        matched.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return matched.map(\.name)
    }

    private var savedQueryItems: [QuickOpen.Item] {
        QuickOpen.items(objects: [], savedQueries: environment.savedQueries.queries)
    }

    /// Lists every schema's objects (the shared session, one statement at a time). What was
    /// listed last time shows until then; the current schema's come from the sidebar at once.
    private func loadQuickOpenItems(into panel: PickerPanel) {
        if quickOpenItems.isEmpty {
            quickOpenItems = QuickOpen.items(objects: environment.catalog.objects, savedQueries: [])
            panel.refresh()
        }
        panel.setNote("Listing every schema…")
        let connection = connection
        Task { [weak self, weak panel] in
            do {
                let schemas = try await connection.schemas()
                var objects: [DatabaseObject] = []
                for schema in schemas.isEmpty ? [nil] : schemas.map(Optional.some) {
                    objects += try await connection.objects(schema: schema)
                }
                guard let self else { return }
                self.quickOpenItems = QuickOpen.items(objects: objects, savedQueries: [])
                panel?.setNote(schemas.count > 1 ? "\(schemas.count) schemas" : "")
            } catch {
                panel?.setNote("Couldn't list every schema: \(error)")
            }
            panel?.refresh()
        }
    }

    private func quickOpenChose(_ item: QuickOpen.Item) {
        quickOpenRecent.removeAll { $0 == item }
        quickOpenRecent.insert(item, at: 0)
        if quickOpenRecent.count > 20 { quickOpenRecent.removeLast() }
        if let url = item.savedQuery {
            guard let query = environment.savedQueries.queries.first(where: { $0.url == url }) else { return NSSound.beep() }
            return openSavedQuery(query)
        }
        guard let object = item.object else { return }
        if SidebarViewController.opensInGrid(object) {
            return open(object, intent: .regular)
        }
        // Functions don't open yet: the sidebar shows them, in their schema.
        leftSidebar.show(.items)
        if object.ref.schema != sidebar.schema, let schema = object.ref.schema {
            sidebar.revealAfterReload = object.ref
            sidebar.switchSchema(to: schema)
        } else {
            sidebar.reveal([object.ref])
        }
    }

    /// ⌘K: the server's databases (MySQL, MariaDB) or schemas (Postgres); choosing one switches
    /// the workspace to it, as the sidebar's switcher does.
    @objc func openDatabase(_ sender: Any?) {
        guard let window, !sidebar.schemaNames.isEmpty else { return NSSound.beep() }
        picker?.close()
        let isMySQL = connection.dialect.lexer == .mysql
        let panel = PickerPanel(placeholder: isMySQL ? "Open a database" : "Open a schema")
        var shown: [String] = []
        panel.rowsFor = { [weak self] query in
            guard let self else { return [] }
            shown = Self.rankNames(self.sidebar.schemaNames, query: query)
            return shown.map { name in
                PickerPanel.Row(title: name, detail: name == self.sidebar.schema ? "Current" : "",
                                symbol: isMySQL ? "cylinder" : "folder", tint: .systemTeal)
            }
        }
        panel.onChoose = { [weak self] i in
            guard let self, shown.indices.contains(i) else { return }
            self.leftSidebar.show(.items)
            self.sidebar.switchSchema(to: shown[i])
        }
        panel.onClose = { [weak self, weak panel] in if self?.picker === panel { self?.picker = nil } }
        picker = panel
        panel.show(over: window)
    }
}
