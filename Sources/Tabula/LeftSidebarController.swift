import AppCore
import AppKit

/// The workspace sidebar: Items (tables and views), Queries (saved) and History.
@MainActor
final class LeftSidebarController: NSViewController {
    enum Pane: Int { case items, queries, history }

    let items: SidebarViewController
    let queries: SavedQueriesViewController
    let history: HistoryViewController
    private let picker = NSSegmentedControl()
    private let container = NSView()
    private(set) var pane = Pane.items

    init(items: SidebarViewController, savedQueries: SavedQueries, history: QueryHistory) {
        self.items = items
        self.queries = SavedQueriesViewController(store: savedQueries)
        self.history = HistoryViewController(history: history)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        picker.segmentCount = 3
        for (i, (label, tip)) in [("Items", "Tables and views"), ("Queries", "Saved queries"),
                                  ("History", "Statements run in this connection")].enumerated() {
            picker.setLabel(label, forSegment: i)
            picker.setToolTip(tip, forSegment: i)
            picker.setWidth(0, forSegment: i)
        }
        picker.segmentDistribution = .fillEqually
        picker.controlSize = .small
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(pickerChanged(_:))

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        for v in [picker, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 0),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        for child in [items, queries, history] as [NSViewController] { addChild(child) }
        show(.items)
    }

    func show(_ pane: Pane) {
        self.pane = pane
        picker.selectedSegment = pane.rawValue
        for v in container.subviews { v.removeFromSuperview() }
        let child: NSViewController = switch pane {
        case .items: items
        case .queries: queries
        case .history: history
        }
        container.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.pin(to: container)
    }

    @objc private func pickerChanged(_ sender: NSSegmentedControl) {
        show(Pane(rawValue: sender.selectedSegment) ?? .items)
    }
}

/// A search field over a list; the base for the Queries and History panes.
@MainActor
class SidebarListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let table = NSTableView()
    let search = NSSearchField()
    let empty = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        search.delegate = self
        search.sendsSearchStringImmediately = true
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        let root = NSView()
        for v in [search, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
    func controlTextDidChange(_ obj: Notification) { reloadList() }
    func reloadList() {}
    @objc func doubleClicked(_ sender: Any?) {}

    /// The row a context-menu command applies to: the clicked row, else the selection.
    var targetRow: Int? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return row >= 0 ? row : nil
    }

    func makeLabel(_ font: NSFont, color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = lines
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// Saved queries. Double-click opens one in a tab of its own.
@MainActor
final class SavedQueriesViewController: SidebarListController {
    let store: SavedQueries
    var onOpen: ((SavedQueries.Query) -> Void)?
    var onInsert: ((String) -> Void)?
    /// After a rename (new value) or delete (nil).
    var onChange: ((SavedQueries.Query, SavedQueries.Query?) -> Void)?
    private var shown: [SavedQueries.Query] = []

    init(store: SavedQueries) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        search.placeholderString = "Search queries"
        table.rowHeight = 24
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(open(_:))), ("Insert into Editor", #selector(insert(_:))),
                                ("Rename…", #selector(rename(_:))), ("Show in Finder", #selector(reveal(_:))),
                                ("Delete…", #selector(delete(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        table.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SavedQueries.didChange, object: store)
        reloadList()
    }

    @objc private func storeChanged() { reloadList() }

    override func reloadList() {
        store.reload()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? store.queries : store.queries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        empty.stringValue = store.queries.isEmpty ? "No saved queries.\nIn a query tab, choose Add to Queries… from the Run menu." : "Nothing matches “\(q)”."
        empty.isHidden = !shown.isEmpty
    }

    override func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("Query")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Saved query")
            image.contentTintColor = .secondaryLabelColor
            let text = makeLabel(.systemFont(ofSize: NSFont.systemFontSize))
            for v in [image, text] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.textField = text
            return c
        }()
        cell.textField?.stringValue = shown[row].name
        cell.toolTip = "Modified \(shown[row].modified.formatted(date: .abbreviated, time: .shortened))"
        return cell
    }

    override func doubleClicked(_ sender: Any?) {
        if table.clickedRow >= 0 { onOpen?(shown[table.clickedRow]) }
    }

    @objc private func open(_ sender: Any?) {
        if let row = targetRow { onOpen?(shown[row]) }
    }

    @objc private func insert(_ sender: Any?) {
        guard let row = targetRow, let text = try? store.text(of: shown[row]) else { return NSSound.beep() }
        onInsert?(text)
    }

    @objc private func reveal(_ sender: Any?) {
        if let row = targetRow { NSWorkspace.shared.activateFileViewerSelecting([shown[row].url]) }
    }

    @objc private func rename(_ sender: Any?) {
        guard let row = targetRow, let window = view.window else { return }
        let query = shown[row]
        let alert = NSAlert()
        alert.messageText = "Rename “\(query.name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = query.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let renamed = try self.store.rename(query, to: field.stringValue)
                self.onChange?(query, renamed)
            } catch {
                self.show(error)
            }
        }
    }

    @objc private func delete(_ sender: Any?) {
        guard let row = targetRow, let window = view.window else { return }
        let query = shown[row]
        let alert = NSAlert()
        alert.messageText = "Delete “\(query.name)”?"
        alert.informativeText = "The file is moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try FileManager.default.trashItem(at: query.url, resultingItemURL: nil)
                self.store.reload()
                NotificationCenter.default.post(name: SavedQueries.didChange, object: self.store)
                self.onChange?(query, nil)
            } catch {
                self.show(error)
            }
        }
    }

    private func show(_ error: any Error) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "\(error)"
            alert.beginSheetModal(for: window)
        }
    }
}

/// Statements run from query tabs, newest first. Double-click puts one in the editor.
@MainActor
final class HistoryViewController: SidebarListController {
    let history: QueryHistory
    var onInsert: ((String) -> Void)?
    var onOpenInNewTab: ((String) -> Void)?
    private var shown: [QueryHistory.Entry] = []

    init(history: QueryHistory) {
        self.history = history
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        search.placeholderString = "Search history"
        table.rowHeight = 58
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        let menu = NSMenu()
        for (title, action) in [("Insert into Editor", #selector(insert(_:))), ("Open in New Tab", #selector(openInNewTab(_:))),
                                ("Copy", #selector(copy(_:))), ("Delete", #selector(delete(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History…", action: #selector(clear(_:)), keyEquivalent: "").target = self
        table.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: QueryHistory.didChange, object: history)
        reloadList()
    }

    @objc private func historyChanged() { reloadList() }

    override func reloadList() {
        shown = history.search(search.stringValue)
        table.reloadData()
        empty.stringValue = history.entries.isEmpty ? "Statements you run appear here." : "Nothing matches."
        empty.isHidden = !shown.isEmpty
    }

    override func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("History")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell ?? HistoryCell(self)
        cell.show(shown[row])
        return cell
    }

    override func doubleClicked(_ sender: Any?) {
        if table.clickedRow >= 0 { onInsert?(shown[table.clickedRow].sql) }
    }

    @objc private func insert(_ sender: Any?) {
        if let row = targetRow { onInsert?(shown[row].sql) }
    }

    @objc private func openInNewTab(_ sender: Any?) {
        if let row = targetRow { onOpenInNewTab?(shown[row].sql) }
    }

    @objc func copy(_ sender: Any?) {
        guard let row = targetRow else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown[row].sql, forType: .string)
    }

    @objc private func delete(_ sender: Any?) {
        guard let row = targetRow else { return }
        try? history.remove(shown[row])
    }

    @objc private func clear(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear this connection's query history?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { try? self?.history.clear() }
        }
    }

    private final class HistoryCell: NSTableCellView {
        private let when: NSTextField
        private let sql: NSTextField
        private let status = NSImageView()

        init(_ owner: SidebarListController) {
            when = owner.makeLabel(.systemFont(ofSize: 10), color: .secondaryLabelColor)
            sql = owner.makeLabel(.monospacedSystemFont(ofSize: 11, weight: .regular), lines: 2)
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier("History")
            status.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            for v in [status, when, sql] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                status.centerYAnchor.constraint(equalTo: when.centerYAnchor),
                when.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 4),
                when.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                when.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                sql.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                sql.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                sql.topAnchor.constraint(equalTo: when.bottomAnchor, constant: 2),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func show(_ entry: QueryHistory.Entry) {
            var meta = entry.date.formatted(date: .abbreviated, time: .standard)
            if let ms = entry.ms { meta += " · \(ms) ms" }
            if !entry.ok { meta += " · failed" }
            when.stringValue = meta
            status.image = NSImage(systemSymbolName: entry.ok ? "checkmark.circle" : "xmark.circle", accessibilityDescription: entry.ok ? "Succeeded" : "Failed")
            status.contentTintColor = entry.ok ? .systemGreen : .systemRed
            // Collapse whitespace so two lines show as much of the statement as possible.
            sql.stringValue = entry.sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            toolTip = entry.sql
        }
    }
}
