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
        .init(symbol: "cylinder", name: "Items", tip: "Tables and Views"),
        .init(symbol: "doc.text", name: "Queries", tip: "Saved Queries"),
        .init(symbol: "clock", name: "History", tip: "Query History"),
        .init(symbol: "magnifyingglass", name: "Search", tip: "Search in Database"),
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
            // As tall as the workspace's tabs, in line with them.
            picker.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            picker.heightAnchor.constraint(equalToConstant: TabStrip.height - 1),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 4),
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
            button.heightAnchor.constraint(equalToConstant: TabStrip.height - 5).isActive = true
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
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GreySelectionRowView() }
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

/// Saved queries, in folders (one level) then those in no folder. A click opens one in the pane's
/// preview tab, as tables open; double-click or Return opens it in a tab of its own. Dragging a
/// query onto a folder (or the empty area) files it there.
/// Renaming happens in the row; Delete moves to the Trash. The pane has its own undo.
@MainActor
final class SavedQueriesViewController: SidebarListController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSMenuItemValidation
{
    /// Replaced when the connection's queries folder changes.
    var store: SavedQueries {
        didSet {
            guard store !== oldValue, isViewLoaded else { return }
            NotificationCenter.default.removeObserver(self, name: SavedQueries.didChange, object: oldValue)
            NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SavedQueries.didChange, object: store)
            // Steps in the old folder no longer apply.
            paneUndoManager.removeAllActions()
            reloadList()
        }
    }
    var onOpen: ((SavedQueries.Query, TabPlacement.Intent) -> Void)?
    var onInsert: ((String) -> Void)?
    /// After a rename or move (new value) or a move to the Trash (nil).
    var onChange: ((SavedQueries.Query, SavedQueries.Query?) -> Void)?
    /// Undo and redo while the pane has the focus (the window asks for it).
    let paneUndoManager = UndoManager()

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
    /// The row whose name is being edited, and whether Esc cancelled it.
    private var renaming: (node: Node, field: NSTextField, cancelled: Bool)?
    private static let dragType = NSPasteboard.PasteboardType("app.moonrow.saved-query")
    var outline: KeyOutlineView { table as! KeyOutlineView }

    init(store: SavedQueries) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeTable() -> NSTableView { KeyOutlineView() }

    override func loadView() {
        super.loadView()
        search.placeholderString = "Search queries"
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        outline.indentationPerLevel = 12
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.onDelete = { [weak self] in self?.moveToTrash(nil) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SavedQueries.didChange, object: store)
        reloadList()
    }

    @objc private func storeChanged() {
        // A row being renamed keeps its field until the rename ends.
        guard renaming == nil else { return }
        reloadList()
    }

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
        let selected = item(at: outline.selectedRow).map(key)
        folderChildren = [:]
        var folderNodes: [Node] = []
        for folder in store.folders {
            let inside = store.queries(in: folder).filter { store.matches($0, q) }.map { node(folder: folder, query: $0) }
            // While searching, folders without a match hide.
            if !q.isEmpty && inside.isEmpty && !folder.localizedCaseInsensitiveContains(q) { continue }
            folderChildren[folder] = inside
            folderNodes.append(node(folder: folder, query: nil))
        }
        roots = folderNodes + store.queries(in: "").filter { store.matches($0, q) }.map { node(folder: nil, query: $0) }
        outline.reloadData()
        for n in folderNodes where !q.isEmpty || !collapsed.contains(n.folder!) { outline.expandItem(n) }
        if let selected, let n = nodes[selected] { select(n) }
        empty.stringValue = store.queries.isEmpty && store.folders.isEmpty ? "No Saved Queries" : "No Results"
        empty.isHidden = !roots.isEmpty
    }

    private func key(_ n: Node) -> String { n.query.map { "q:" + $0.path } ?? "f:" + (n.folder ?? "") }

    /// Selects the saved query the selected tab shows, its folder expanded, or nothing for any
    /// other tab. Opens nothing.
    func reveal(_ query: SavedQueries.Query?) {
        guard isViewLoaded, renaming == nil else { return }
        if let query, !query.folder.isEmpty, let folder = nodes["f:" + query.folder], !outline.isItemExpanded(folder) {
            outline.expandItem(folder)
        }
        let row = query.flatMap { nodes["q:" + $0.path] }.map { outline.row(forItem: $0) }
        quiet.select(row.flatMap { $0 >= 0 ? $0 : nil }, in: outline)
    }

    /// Selection from code (a reload, a rename, an undo, the selected tab) opens nothing.
    private let quiet = QuietSelection()

    private func select(_ n: Node) {
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        quiet.select(row, in: outline)
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

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { GreySelectionRowView() }

    /// Selecting a query opens it in the preview tab, so arrow keys browse queries one after another.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !quiet.isActive, renaming == nil, let query = item(at: outline.selectedRow)?.query else { return }
        onOpen?(query, .preview)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let n = item as? Node else { return nil }
        return n.query?.name ?? n.folder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("Query")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        if let query = n.query {
            cell.show(query.name, symbol: "doc.text", tint: .secondaryLabelColor, accessibilityDescription: "Saved query")
            cell.toolTip = "Modified \(query.modified.formatted(date: .abbreviated, time: .shortened))"
        } else {
            let count = store.queries(in: n.folder!).count
            cell.show(n.folder!, symbol: "folder", tint: .secondaryLabelColor, accessibilityDescription: "Folder")
            cell.toolTip = count == 1 ? "1 query" : "\(count.formatted()) queries"
        }
        return cell
    }

    private func item(at row: Int) -> Node? { row >= 0 ? outline.item(atRow: row) as? Node : nil }
    private var target: Node? { item(at: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) }

    /// The folder of the selected row, where the save panel starts.
    var selectedFolder: String? {
        guard let n = item(at: outline.selectedRow) else { return nil }
        return n.query?.folder ?? n.folder
    }

    override func doubleClicked(_ sender: Any?) {
        guard let n = item(at: outline.clickedRow) else { return }
        if let query = n.query { onOpen?(query, .regular) } else { toggle(n) }
    }

    private func openSelected() {
        guard let n = item(at: outline.selectedRow) else { return NSSound.beep() }
        if let query = n.query { onOpen?(query, .regular) } else { toggle(n) }
    }

    private func toggle(_ n: Node) {
        if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if let query = target?.query {
            add("Open", #selector(open(_:)))
            add("Insert into Editor", #selector(insert(_:)))
            menu.addItem(.separator())
            add("Rename", #selector(rename(_:)))
            if !store.folders.isEmpty {
                let move = menu.addItem(withTitle: "Move to", action: nil, keyEquivalent: "")
                move.submenu = NSMenu(title: "Move to")
                for (title, folder) in [("No Folder", "")] + store.folders.map({ ($0, $0) }) {
                    let item = move.submenu!.addItem(withTitle: title, action: #selector(moveToFolder(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = folder
                    item.state = folder == query.folder ? .on : .off
                }
            }
            add("Show in Finder", #selector(showInFinder(_:)))
            menu.addItem(.separator())
            add("Move to Trash", #selector(moveToTrash(_:)))
            menu.addItem(.separator())
        } else if target?.folder != nil {
            add("Rename", #selector(rename(_:)))
            add("Show in Finder", #selector(showInFinder(_:)))
            menu.addItem(.separator())
            add("Move to Trash", #selector(moveToTrash(_:)))
            menu.addItem(.separator())
        }
        add("New Folder", #selector(newFolder(_:)))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(moveToFolder(_:)):
            return (item.representedObject as? String) != target?.query?.folder
        case #selector(deleteRows(_:)):
            // Edit ▸ Delete (⌘⌫) while the pane has the focus.
            if item.menu?.title == "Edit" { item.title = "Move to Trash" }
            return target != nil
        default:
            return true
        }
    }

    @objc private func open(_ sender: Any?) {
        if let query = target?.query { onOpen?(query, .regular) }
    }

    @objc private func insert(_ sender: Any?) {
        guard let query = target?.query, let text = try? store.text(of: query) else { return NSSound.beep() }
        onInsert?(text)
    }

    @objc private func showInFinder(_ sender: Any?) {
        guard let n = target else { return }
        let url = n.query?.url ?? store.url(ofFolder: n.folder ?? "")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func moveToFolder(_ sender: NSMenuItem) {
        guard let query = target?.query, let folder = sender.representedObject as? String else { return }
        move(query, to: folder)
    }

    /// Edit ▸ Delete (⌘⌫).
    @objc func deleteRows(_ sender: Any?) { moveToTrash(sender) }

    // MARK: - Changes, each undoable

    /// Files a query in a folder ("" for none), as the menu or a drag does.
    func move(_ query: SavedQueries.Query, to folder: String) {
        attempt("Couldn’t move “\(query.name)”") {
            let moved = try store.move(query, to: folder)
            onChange?(query, moved)
            registerUndo("Move Query") { $0.move(moved, to: query.folder) }
            if let n = nodes["q:" + moved.path] { select(n) }
        }
    }

    private func rename(_ query: SavedQueries.Query, to name: String) {
        attempt("Couldn’t rename “\(query.name)”") {
            let renamed = try store.rename(query, to: name)
            guard renamed.url != query.url || renamed.name != query.name else { return }
            onChange?(query, renamed)
            registerUndo("Rename Query") { $0.rename(renamed, to: query.name) }
        }
    }

    private func renameFolder(_ folder: String, to name: String) {
        let before = store.queries(in: folder)
        attempt("Couldn’t rename “\(folder)”") {
            let new = try store.renameFolder(folder, to: name)
            guard new != folder else { return }
            if collapsed.remove(folder) != nil { collapsed.insert(new) }
            for q in before { onChange?(q, store.query(named: q.name, in: new)) }
            registerUndo("Rename Folder") { $0.renameFolder(new, to: folder) }
        }
    }

    @objc private func moveToTrash(_ sender: Any?) {
        guard let n = target else { return NSSound.beep() }
        if let query = n.query {
            attempt("Couldn’t move “\(query.name)” to the Trash") {
                guard let trashed = try store.delete(query) else { return }
                onChange?(query, nil)
                registerUndo("Move to Trash") { $0.putBack(trashed, to: query.url) }
            }
        } else if let folder = n.folder {
            let inside = store.queries(in: folder)
            let original = store.url(ofFolder: folder)
            attempt("Couldn’t move “\(folder)” to the Trash") {
                guard let trashed = try store.deleteFolder(folder) else { return }
                for q in inside { onChange?(q, nil) }
                registerUndo("Move to Trash") { $0.putBack(trashed, to: original) }
            }
        }
    }

    /// Undoes a move to the Trash; redo moves it there again.
    private func putBack(_ trashed: URL, to original: URL) {
        attempt("Couldn’t put back “\(original.deletingPathExtension().lastPathComponent)”") {
            try store.putBack(trashed, to: original)
            let place = store.location(of: original)
            let n = place.map { nodes["q:" + ($0.folder.isEmpty ? $0.name : $0.folder + "/" + $0.name)] } ?? nodes["f:" + original.lastPathComponent]
            if let n { select(n) }
            registerUndo("Move to Trash") { pane in
                if let n { pane.select(n) }
                pane.moveToTrash(nil)
            }
        }
    }

    /// A folder named "New Folder" (or "New Folder 2"…) whose name is then edited in its row.
    @objc func newFolder(_ sender: Any?) {
        var name = "New Folder"
        var number = 2
        while store.folders.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New Folder \(number)"
            number += 1
        }
        attempt("Couldn’t create the folder") {
            let folder = try store.addFolder(name)
            collapsed.remove(folder)
            search.stringValue = ""
            reloadList()
            registerUndo("New Folder") { _ = try? $0.store.deleteFolder(folder) }
            if let n = nodes["f:" + folder] { beginRename(n) }
        }
    }

    private func registerUndo(_ name: String, _ action: @escaping @MainActor (SavedQueriesViewController) -> Void) {
        paneUndoManager.registerUndo(withTarget: self) { pane in MainActor.assumeIsolated { action(pane) } }
        paneUndoManager.setActionName(name)
    }

    private func attempt(_ title: String, _ body: () throws -> Void) {
        do { try body() } catch { show(error, title: title) }
    }

    // MARK: - Renaming in the row

    @objc private func rename(_ sender: Any?) {
        if let n = target { beginRename(n) }
    }

    private func beginRename(_ n: Node) {
        let row = outline.row(forItem: n)
        guard row >= 0, let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell)?.label
        else { return NSSound.beep() }
        select(n)
        field.isEditable = true
        field.delegate = self
        renaming = (n, field, false)
        view.window?.makeFirstResponder(field)
    }

    @objc func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let r = renaming, control === r.field, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renaming?.cancelled = true
        view.window?.makeFirstResponder(outline)
        return true
    }

    @objc func controlTextDidEndEditing(_ obj: Notification) {
        guard let r = renaming, obj.object as? NSTextField === r.field else { return }
        renaming = nil
        r.field.isEditable = false
        let name = r.field.stringValue
        let old = r.node.query?.name ?? r.node.folder ?? ""
        r.field.stringValue = old
        if view.window?.firstResponder == nil || view.window?.firstResponder === view.window { view.window?.makeFirstResponder(outline) }
        if !r.cancelled, name != old {
            if let query = r.node.query { rename(query, to: name) } else if let folder = r.node.folder { renameFolder(folder, to: name) }
        }
        reloadList()
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

    private func show(_ error: any Error, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
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

    /// Selects the row of `path` ("folder/name" for a query, "[folder]" for a folder).
    func selectRow(_ path: String) -> Bool {
        let key = path.hasPrefix("[") ? "f:" + path.dropFirst().dropLast() : "q:" + path
        guard let n = nodes[key] else { return false }
        select(n)
        return outline.selectedRow >= 0
    }

    /// The path of the selected query, if a query is selected.
    var selectedQueryPath: String? { item(at: outline.selectedRow)?.query?.path }

    /// Selects a query's row as a click does, which opens it.
    func clickRow(_ path: String) -> Bool {
        guard let n = nodes["q:" + path] else { return false }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return false }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        return true
    }

    /// The text field of the row being renamed.
    var renamingField: NSTextField? { renaming?.field }
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
        // A plain table paints its own background; the sidebar's shows through the other panes.
        table.backgroundColor = .clear
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
        empty.stringValue = history.entries.isEmpty ? "No History" : "No Results"
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
            let label = SolidLabel(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
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
        alert.messageText = "Clear this connection’s query history?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { try? self?.history.clear() }
        }
    }

    /// A date heading's label. Drawn without vibrancy: blended with the sidebar, its grey washes
    /// out to barely legible.
    private final class SolidLabel: NSTextField {
        override var allowsVibrancy: Bool { false }
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
            // Under Today and Yesterday the heading has the day already.
            let calendar = Calendar.current
            let recent = calendar.isDateInToday(entry.date) || calendar.isDateInYesterday(entry.date)
            var meta = entry.date.formatted(date: recent ? .omitted : .abbreviated, time: .shortened)
            // Kept in whole milliseconds: 0 was under one.
            if let ms = entry.ms { meta += " · " + (ms == 0 ? "< 1 ms" : DurationText.string(.milliseconds(ms))) }
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
