import AppCore
import AppKit

/// The workspace sidebar: Items (tables and views), Queries (saved), History and Search (in
/// database).
@MainActor
final class LeftSidebarController: NSViewController {
    enum Pane: Int { case items, queries, history, search }

    let items: SidebarViewController
    let queries: SavedQueriesViewController
    let history: HistoryViewController
    let search = SearchInDatabaseViewController()
    private let picker = NavigatorBar(tabs: [
        .init(symbol: "cylinder", name: "Items", tip: "Items: tables and views"),
        .init(symbol: "doc.text", name: "Queries", tip: "Queries: saved queries"),
        .init(symbol: "clock", name: "History", tip: "History: statements run in this connection"),
        .init(symbol: "magnifyingglass", name: "Search", tip: "Search in Database: a text in every table"),
    ])
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
        picker.onSelect = { [weak self] index in self?.show(Pane(rawValue: index) ?? .items) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        for v in [picker, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // The capsule takes the place of the selected workspace tab's glass, 2 points inside the
            // tab strip, so the two line up.
            picker.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 2),
            picker.heightAnchor.constraint(equalToConstant: TabStrip.height - 5),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        for child in [items, queries, history, search] as [NSViewController] { addChild(child) }
        show(.items)
    }

    func show(_ pane: Pane) {
        self.pane = pane
        picker.selectedIndex = pane.rawValue
        for v in container.subviews { v.removeFromSuperview() }
        let child: NSViewController = switch pane {
        case .items: items
        case .queries: queries
        case .history: history
        case .search: search
        }
        container.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.pin(to: container)
    }

}

/// The sidebar's pane picker, as in Xcode's navigators: outline symbols on a capsule (glass on
/// macOS 26), the selected one on a grey pill that fills its slot and slides to it.
@MainActor
private final class NavigatorBar: NSView {
    struct Tab { let symbol, name, tip: String }

    var onSelect: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet { if selectedIndex != oldValue { update(animated: window != nil) } }
    }
    private let buttons: [NSButton]
    private let track = Track()

    init(tabs: [Tab]) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        buttons = tabs.map { tab in
            let button = NSButton()
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.name)?
                .withSymbolConfiguration(config)
            button.contentTintColor = .labelColor
            button.toolTip = tab.tip
            button.setAccessibilityLabel(tab.name)
            button.setAccessibilityRole(.radioButton)
            return button
        }
        super.init(frame: .zero)
        let stack = NSStackView(views: buttons)
        stack.distribution = .fillEqually
        stack.spacing = 0
        track.count = buttons.count
        track.highlight.wantsLayer = true
        track.addSubview(track.highlight)
        track.addSubview(stack)
        stack.pin(to: track)
        let capsule = GlassCapsule(track, padding: 2)
        addSubview(capsule)
        capsule.pin(to: self)
        for (i, button) in buttons.enumerated() {
            button.tag = i
            button.target = self
            button.action = #selector(clicked(_:))
            button.heightAnchor.constraint(equalToConstant: TabStrip.height - 9).isActive = true
        }
        update(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked(_ sender: NSButton) {
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    private func update(animated: Bool) {
        for (i, button) in buttons.enumerated() { button.state = i == selectedIndex ? .on : .off }
        track.selected = selectedIndex
        let target = track.highlightFrame
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            track.highlight.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            track.highlight.animator().frame = target
        }
    }

    /// The row of tabs, with the highlight behind them.
    private final class Track: NSView {
        let highlight = Highlight()
        var count = 1
        var selected = 0

        /// The selected tab's whole slot.
        var highlightFrame: NSRect {
            let slot = bounds.width / CGFloat(max(count, 1))
            return NSRect(x: slot * CGFloat(selected), y: 0, width: slot, height: bounds.height)
        }

        override func layout() {
            super.layout()
            highlight.frame = highlightFrame
        }
    }

    private final class Highlight: NSView {
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            // Set here so the colour follows the appearance.
            layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
        }
    }
}

/// A search field over a list; the base for the Queries and History panes.
@MainActor
class SidebarListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    lazy var table: NSTableView = makeTable()
    let search: NSSearchField = SidebarSearchField()
    let empty = NSTextField(wrappingLabelWithString: "")

    /// The list view; the Queries pane uses an outline.
    func makeTable() -> NSTableView { NSTableView() }

    override func loadView() {
        search.delegate = self
        search.sendsSearchStringImmediately = true
        // Every keystroke filters (the action fires as the text changes).
        search.target = self
        search.action = #selector(searchChanged(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        if let outline = table as? NSOutlineView { outline.outlineTableColumn = outline.tableColumns.first }
        table.headerView = nil
        table.style = .sourceList
        if !(table is NSOutlineView) {
            table.dataSource = self
            table.delegate = self
        }
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
    @objc private func searchChanged(_ sender: Any?) { reloadList() }
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

/// Saved queries, in folders (one level) then those in no folder. Double-click opens one in a
/// tab of its own; dragging a query onto a folder (or the empty area) files it there.
@MainActor
final class SavedQueriesViewController: SidebarListController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let store: SavedQueries
    var onOpen: ((SavedQueries.Query) -> Void)?
    var onInsert: ((String) -> Void)?
    /// After a rename or move (new value) or delete (nil).
    var onChange: ((SavedQueries.Query, SavedQueries.Query?) -> Void)?

    /// A row: a folder, or a query. Kept per path so the outline remembers what's expanded.
    final class Node: NSObject {
        let folder: String?
        var query: SavedQueries.Query?
        init(folder: String?, query: SavedQueries.Query?) {
            self.folder = folder
            self.query = query
        }
    }
    private var roots: [Node] = []
    private var folderChildren: [String: [Node]] = [:]
    private var nodes: [String: Node] = [:]
    private var collapsed = Set<String>()
    private static let dragType = NSPasteboard.PasteboardType("app.moonrow.saved-query")
    var outline: NSOutlineView { table as! NSOutlineView }

    init(store: SavedQueries) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeTable() -> NSTableView { NSOutlineView() }

    override func loadView() {
        super.loadView()
        search.placeholderString = "Search queries"
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        outline.indentationPerLevel = 12
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SavedQueries.didChange, object: store)
        reloadList()
    }

    @objc private func storeChanged() { reloadList() }

    private func node(folder: String?, query: SavedQueries.Query?) -> Node {
        let key = query.map { "q:" + $0.path } ?? "f:" + (folder ?? "")
        if let n = nodes[key] {
            n.query = query
            return n
        }
        let n = Node(folder: folder, query: query)
        nodes[key] = n
        return n
    }

    override func reloadList() {
        store.reload()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        func matches(_ query: SavedQueries.Query) -> Bool { q.isEmpty || query.name.localizedCaseInsensitiveContains(q) }
        folderChildren = [:]
        var folderNodes: [Node] = []
        for folder in store.folders {
            let inside = store.queries(in: folder).filter(matches).map { node(folder: folder, query: $0) }
            // While searching, folders without a match hide.
            if !q.isEmpty && inside.isEmpty && !folder.localizedCaseInsensitiveContains(q) { continue }
            folderChildren[folder] = inside
            folderNodes.append(node(folder: folder, query: nil))
        }
        roots = folderNodes + store.queries(in: "").filter(matches).map { node(folder: nil, query: $0) }
        outline.reloadData()
        for n in folderNodes where !q.isEmpty || !collapsed.contains(n.folder!) { outline.expandItem(n) }
        empty.stringValue = store.queries.isEmpty && store.folders.isEmpty
            ? "No saved queries.\nIn a query tab, choose Add to Queries… from the Run menu." : "Nothing matches “\(q)”."
        empty.isHidden = !roots.isEmpty
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? Node else { return roots.count }
        return n.query == nil ? folderChildren[n.folder ?? ""]?.count ?? 0 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? Node else { return roots[index] }
        return folderChildren[n.folder ?? ""]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.query == nil
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? Node, let f = n.folder, search.stringValue.isEmpty { collapsed.insert(f) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? Node, let f = n.folder { collapsed.remove(f) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("Query")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            image.contentTintColor = .secondaryLabelColor
            let text = makeLabel(.systemFont(ofSize: NSFont.systemFontSize))
            for v in [image, text] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.textField = text
            c.imageView = image
            return c
        }()
        if let query = n.query {
            cell.textField?.stringValue = query.name
            cell.imageView?.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Saved query")
            cell.toolTip = "Modified \(query.modified.formatted(date: .abbreviated, time: .shortened))"
        } else {
            let count = store.queries(in: n.folder!).count
            cell.textField?.stringValue = n.folder!
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            cell.toolTip = "\(count) quer\(count == 1 ? "y" : "ies")"
        }
        return cell
    }

    private func item(at row: Int) -> Node? { row >= 0 ? outline.item(atRow: row) as? Node : nil }
    private var target: Node? { item(at: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) }

    /// The folder of the selected row, for Add to Queries.
    var selectedFolder: String? {
        guard let n = item(at: outline.selectedRow) else { return nil }
        return n.query?.folder ?? n.folder
    }

    override func doubleClicked(_ sender: Any?) {
        guard let n = item(at: outline.clickedRow) else { return }
        if let query = n.query { onOpen?(query) }
        else if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        if let query = target?.query {
            _ = add("Open", #selector(open(_:)))
            _ = add("Insert into Editor", #selector(insert(_:)))
            _ = add("Rename…", #selector(rename(_:)))
            let move = menu.addItem(withTitle: "Move to", action: nil, keyEquivalent: "")
            move.submenu = NSMenu(title: "Move to")
            for (title, folder) in [("No Folder", "")] + store.folders.map({ ($0, $0) }) {
                let item = move.submenu!.addItem(withTitle: title, action: #selector(moveToFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                item.state = folder == query.folder ? .on : .off
                item.isEnabled = folder != query.folder
            }
            _ = add("Show in Finder", #selector(reveal(_:)))
            _ = add("Delete…", #selector(delete(_:)))
            menu.addItem(.separator())
        } else if target?.folder != nil {
            _ = add("Rename Folder…", #selector(renameFolder(_:)))
            _ = add("Delete Folder…", #selector(deleteFolder(_:)))
            menu.addItem(.separator())
        }
        _ = add("New Folder…", #selector(newFolder(_:)))
    }

    @objc private func open(_ sender: Any?) {
        if let query = target?.query { onOpen?(query) }
    }

    @objc private func insert(_ sender: Any?) {
        guard let query = target?.query, let text = try? store.text(of: query) else { return NSSound.beep() }
        onInsert?(text)
    }

    @objc private func reveal(_ sender: Any?) {
        if let query = target?.query { NSWorkspace.shared.activateFileViewerSelecting([query.url]) }
    }

    @objc private func rename(_ sender: Any?) {
        guard let query = target?.query else { return }
        ask("Rename “\(query.name)”", value: query.name, button: "Rename") { [weak self] name in
            guard let self else { return }
            let renamed = try self.store.rename(query, to: name)
            self.onChange?(query, renamed)
        }
    }

    @objc private func moveToFolder(_ sender: NSMenuItem) {
        guard let query = target?.query, let folder = sender.representedObject as? String else { return }
        move(query, to: folder)
    }

    /// Files a query in a folder ("" for none), as the menu or a drag does.
    func move(_ query: SavedQueries.Query, to folder: String) {
        do {
            let moved = try store.move(query, to: folder)
            onChange?(query, moved)
        } catch {
            show(error)
        }
    }

    @objc private func delete(_ sender: Any?) {
        guard let query = target?.query, let window = view.window else { return }
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

    @objc func newFolder(_ sender: Any?) {
        ask("New Folder", value: "", button: "Create") { [weak self] name in
            guard let self else { return }
            let folder = try self.store.addFolder(name)
            self.collapsed.remove(folder)
        }
    }

    @objc private func renameFolder(_ sender: Any?) {
        guard let folder = target?.folder, target?.query == nil else { return }
        let before = store.queries(in: folder)
        ask("Rename Folder “\(folder)”", value: folder, button: "Rename") { [weak self] name in
            guard let self else { return }
            let new = try self.store.renameFolder(folder, to: name)
            for q in before { self.onChange?(q, self.store.query(named: q.name, in: new)) }
        }
    }

    @objc private func deleteFolder(_ sender: Any?) {
        guard let folder = target?.folder, target?.query == nil, let window = view.window else { return }
        let inside = store.queries(in: folder)
        let alert = NSAlert()
        alert.messageText = "Delete the folder “\(folder)”?"
        alert.informativeText = inside.isEmpty ? "The folder is empty." : "It and its \(inside.count) quer\(inside.count == 1 ? "y" : "ies") are moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.store.deleteFolder(folder)
                for q in inside { self.onChange?(q, nil) }
            } catch {
                self.show(error)
            }
        }
    }

    private func ask(_ title: String, value: String, button: String, _ apply: @escaping (String) throws -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try apply(field.stringValue) } catch { self?.show(error) }
        }
    }

    // MARK: - Drag to file

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let query = (item as? Node)?.query else { return nil }
        let p = NSPasteboardItem()
        p.setString(query.path, forType: Self.dragType)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        // Onto a folder (or a query inside it) files it there; anywhere else, out of folders.
        if let n = item as? Node, n.query == nil {
            outlineView.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else if let n = item as? Node, let folder = n.query?.folder, !folder.isEmpty {
            outlineView.setDropItem(nodes["f:" + folder], dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let path = info.draggingPasteboard.string(forType: Self.dragType), let query = store.query(path: path) else { return false }
        let folder = (item as? Node)?.folder ?? ""
        guard folder != query.folder else { return false }
        move(query, to: folder)
        return true
    }

    private func show(_ error: any Error) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "\(error)"
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - For the dev harness

    var shownRows: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let n = outline.item(atRow: row) as? Node else { return nil }
            return n.query.map { ($0.folder.isEmpty ? "" : "  ") + $0.name } ?? "[\(n.folder!)]"
        }
    }
}

/// Statements run from query tabs, newest first. Double-click puts one in the editor.
@MainActor
final class HistoryViewController: SidebarListController {
    let history: QueryHistory
    var onInsert: ((String) -> Void)?
    var onOpenInNewTab: ((String) -> Void)?
    /// Date headings, each followed by its entries.
    private enum Row { case heading(String), entry(QueryHistory.Entry) }
    private var rows: [Row] = []

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
        let found = history.search(search.stringValue)
        rows = QueryHistory.grouped(found).flatMap { [Row.heading($0.title)] + $0.entries.map(Row.entry) }
        table.reloadData()
        empty.stringValue = history.entries.isEmpty ? "Statements you run appear here." : "Nothing matches."
        empty.isHidden = !found.isEmpty
    }

    private func entry(_ row: Int?) -> QueryHistory.Entry? {
        guard let row, rows.indices.contains(row), case .entry(let e) = rows[row] else { return nil }
        return e
    }

    override func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    override func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title):
            let label = makeLabel(.systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
            label.stringValue = title
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .entry(let e):
            let id = NSUserInterfaceItemIdentifier("History")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell ?? HistoryCell(self)
            cell.show(e)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = rows[row] { return 22 }
        return 58
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(row) != nil }

    override func doubleClicked(_ sender: Any?) {
        if let e = entry(table.clickedRow) { onInsert?(e.sql) }
    }

    @objc private func insert(_ sender: Any?) {
        if let e = entry(targetRow) { onInsert?(e.sql) }
    }

    @objc private func openInNewTab(_ sender: Any?) {
        if let e = entry(targetRow) { onOpenInNewTab?(e.sql) }
    }

    @objc func copy(_ sender: Any?) {
        guard let e = entry(targetRow) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.sql, forType: .string)
    }

    @objc private func delete(_ sender: Any?) {
        guard let e = entry(targetRow) else { return }
        try? history.remove(e)
    }

    /// For the dev harness: headings in brackets, entries as their SQL.
    var shownRows: [String] {
        rows.map { row in
            switch row {
            case .heading(let t): "[\(t)]"
            case .entry(let e): e.sql
            }
        }
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
