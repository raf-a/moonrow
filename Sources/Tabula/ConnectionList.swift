import AppCore
import AppKit

/// The saved connections as an outline, shared by the welcome window and Open Connection so
/// both look and behave alike: groups (folders, by name, collapsible, the collapse kept with the
/// group) and then the connections in no group, one `ConnectionCell` each. Searching matches
/// names, hosts and tags; groups without a match hide and the others expand.
@MainActor
final class ConnectionList: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Outline items need stable identity: a group (with its shown connections) or a connection.
    final class Node {
        let group: ConnectionGroup?
        let connection: ConnectionConfig?
        let children: [Node]

        init(group: ConnectionGroup, children: [Node]) {
            self.group = group
            self.connection = nil
            self.children = children
        }

        init(connection: ConnectionConfig) {
            self.group = nil
            self.connection = connection
            self.children = []
        }

        /// The group's or the connection's id.
        var id: UUID? { connection?.id ?? group?.id }
    }

    let outline = KeyOutlineView()
    let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let store: ConnectionStore
    private(set) var nodes: [Node] = []
    /// Set while the outline is rebuilt, so expanding doesn't save collapse state.
    private var isReloading = false
    private static let dragType = NSPasteboard.PasteboardType("app.tabula.connection-id")

    /// What's typed in the search field.
    var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    /// Files dragged connections into a group (nil: out of any group). Set, the list accepts drags.
    var onMove: (([UUID], UUID?) -> Bool)? {
        didSet {
            if onMove != nil { outline.registerForDraggedTypes([Self.dragType]) } else { outline.unregisterDraggedTypes() }
        }
    }
    var onSelectionChange: (() -> Void)?
    /// Shown when no connection is saved.
    var emptyText = "No saved connections."

    init(store: ConnectionStore) {
        self.store = store
        super.init()
        let column = NSTableColumn(identifier: .init("connection"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        scrollView.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -60),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: ConnectionStore.didChange, object: store)
        reload()
    }

    /// Whether a connection matches the search: its name, host (or file) and tag.
    static func matches(_ c: ConnectionConfig, _ query: String) -> Bool {
        query.isEmpty || c.displayName.localizedCaseInsensitiveContains(query)
            || c.summary.localizedCaseInsensitiveContains(query)
            || (c.tag?.title.localizedCaseInsensitiveContains(query) ?? false)
    }

    @objc private func storeChanged() { reload() }

    /// Rebuilds the rows, keeping the selection (else `select`, else the first connection).
    func reload(select id: UUID? = nil) {
        let selected = id ?? selectedNode?.id
        let query = query.trimmingCharacters(in: .whitespaces)
        func shown(_ list: [ConnectionConfig]) -> [Node] {
            list.filter { Self.matches($0, query) }.map(Node.init(connection:))
        }
        let groups = store.groups.map { Node(group: $0, children: shown(store.connections(in: $0.id))) }
            .filter { query.isEmpty || !$0.children.isEmpty }
        nodes = groups + shown(store.connections(in: nil))

        isReloading = true
        outline.reloadData()
        for node in groups where !query.isEmpty || !(node.group?.isCollapsed ?? false) {
            outline.expandItem(node)
        }
        isReloading = false

        let row = selected.flatMap { id in rowOfNode { $0.id == id } } ?? rowOfNode { $0.connection != nil }
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        emptyLabel.stringValue = store.connections.isEmpty && store.groups.isEmpty ? emptyText : "Nothing matches “\(query)”."
        emptyLabel.isHidden = !nodes.isEmpty
        onSelectionChange?()
    }

    private func rowOfNode(_ predicate: (Node) -> Bool) -> Int? {
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, predicate(node) { return row }
        }
        return nil
    }

    var selectedNode: Node? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Node : nil
    }

    var selectedConnection: ConnectionConfig? { selectedNode?.connection }

    /// The right-clicked row if there is one, else the selection.
    var clickedNode: Node? {
        if outline.clickedRow >= 0 { return outline.item(atRow: outline.clickedRow) as? Node }
        return selectedNode
    }

    /// Rows as shown: `[Group]` or the connection's name.
    var shownRows: [String] {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Node }.map {
            $0.group.map { "[\($0.name)]" } ?? $0.connection?.displayName ?? "?"
        }
    }

    /// Connection names shown, in order.
    var shownConnections: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.connection?.displayName }
    }

    func toggle(_ node: Node) {
        outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.group != nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.group != nil ? 26 : 44
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let group = node.group {
            let cell = outlineView.makeView(withIdentifier: GroupCell.identifier, owner: nil) as? GroupCell ?? GroupCell()
            cell.show(group, count: node.children.count)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: ConnectionCell.identifier, owner: nil) as? ConnectionCell
            ?? ConnectionCell()
        if let c = node.connection { cell.show(c) }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { onSelectionChange?() }

    func outlineViewItemDidExpand(_ notification: Notification) { collapseChanged(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { collapseChanged(notification, collapsed: true) }

    /// Collapsing is remembered with the group, except while searching (which expands all).
    private func collapseChanged(_ notification: Notification, collapsed: Bool) {
        guard !isReloading, query.isEmpty, let group = (notification.userInfo?["NSObject"] as? Node)?.group else { return }
        try? store.setGroup(group.id, collapsed: collapsed)
    }

    // MARK: - Dragging into groups

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard onMove != nil, let c = (item as? Node)?.connection else { return nil }
        let p = NSPasteboardItem()
        p.setString(c.id.uuidString, forType: Self.dragType)
        return p
    }

    /// A drop on a group (or on a connection in it) files the connection there; a drop between
    /// top-level rows takes it out of any group.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard onMove != nil, info.draggingSource as? NSOutlineView === outline else { return [] }
        if let node = item as? Node {
            let group = node.group ?? (outlineView.parent(forItem: node) as? Node)?.group
            guard let group else { return [] }
            outlineView.setDropItem(nodes.first { $0.group?.id == group.id }, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let ids = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: Self.dragType).flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty, let onMove else { return false }
        return onMove(ids, (item as? Node)?.group?.id)
    }
}

/// A group row: a folder, its name and how many connections it holds.
final class GroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupCell")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Group")
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        glyph.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [glyph, title, NSView(), count])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6)
        addSubview(row)
        row.pin(to: self)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ group: ConnectionGroup, count n: Int) {
        title.stringValue = group.name
        count.stringValue = "\(n)"
    }
}

/// A saved connection in a list: a server or file glyph in the connection's colour, the name
/// over a one-line summary, and the tag.
final class ConnectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let tagLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for f in [title, detail] {
            f.lineBreakMode = .byTruncatingMiddle
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        glyph.image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        glyph.contentTintColor = .controlAccentColor
        // One width for every glyph, so the names line up.
        glyph.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        tagLabel.font = .systemFont(ofSize: 9, weight: .bold)
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)
        tagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [glyph, text, NSView(), tagLabel])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        addSubview(row)
        row.pin(to: self)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: ConnectionConfig) {
        title.stringValue = c.displayName
        detail.stringValue = c.summary
        toolTip = c.driver.isServer ? c.summary : c.expandedFilePath
        glyph.image = NSImage(
            systemSymbolName: c.driver.isServer ? "server.rack" : "cylinder.split.1x2", accessibilityDescription: c.driver.displayName)
        // The connection's colour marks it; uncoloured ones keep the accent colour.
        glyph.contentTintColor = c.markColor ?? .controlAccentColor
        tagLabel.stringValue = c.tag?.title.uppercased() ?? ""
        tagLabel.textColor = c.markColor ?? .secondaryLabelColor
        tagLabel.isHidden = c.tag == nil
    }
}

/// An outline that reports Return and Delete instead of beeping.
final class KeyOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, [36, 76].contains(event.keyCode), let onReturn {  // Return, keypad Enter
            onReturn()
        } else if plain, [51, 117].contains(event.keyCode), let onDelete {  // Delete, Forward Delete
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}
