import AppCore
import AppKit

/// The saved connections as an outline, shared by the welcome window and Open Connection so
/// both look and behave alike: groups (folders, by name, collapsible, the collapse kept with the
/// group) and then the connections in no group, one `ConnectionCell` each.
/// Searching matches names, hosts and tags; groups without a match hide and the others expand.
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
    /// How far in from the list's sides AppKit draws a row's selection (the inset style; measured
    /// on macOS 26, not exposed). A search field above the list is inset as much, so its edges
    /// line up with the selection's.
    static let selectionInset: CGFloat = 11
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let store: ConnectionStore
    private(set) var nodes: [Node] = []
    /// Set while the outline is rebuilt, so expanding doesn't save collapse state.
    private var isReloading = false
    private static let dragType = NSPasteboard.PasteboardType("app.moonrow.connection-id")

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
    /// Limits the list to some connections (Backup and Restore: servers they can work with);
    /// groups left without any then hide.
    var include: ((ConnectionConfig) -> Bool)? {
        didSet { reload() }
    }
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
        // Groups read as headings with their own chevron. The cells indent a group's connections
        // themselves: AppKit's indentation would move the top level off the selection's edge too.
        outline.indentationPerLevel = 0
        outline.hidesDisclosureTriangles = true
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
    static func matches(_ c: ConnectionConfig, tag: ConnectionTag?, _ query: String) -> Bool {
        query.isEmpty || c.displayName.localizedCaseInsensitiveContains(query)
            || c.summary.localizedCaseInsensitiveContains(query)
            || (tag?.name.localizedCaseInsensitiveContains(query) ?? false)
    }

    @objc private func storeChanged() { reload() }

    /// Rebuilds the rows, keeping the selection (else `select`, else the first connection).
    func reload(select id: UUID? = nil) {
        let selected = id ?? selectedNode?.id
        let query = query.trimmingCharacters(in: .whitespaces)
        func shown(_ list: [ConnectionConfig]) -> [Node] {
            list.filter { Self.matches($0, tag: store.tag(of: $0), query) && include?($0) != false }.map(Node.init(connection:))
        }
        let groups = store.groups.map { Node(group: $0, children: shown(store.connections(in: $0.id))) }
            .filter { (query.isEmpty && include == nil) || !$0.children.isEmpty }
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
            // From the top, so a heading above the selection stays in sight when it fits.
            outline.scrollRowToVisible(0)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        emptyLabel.stringValue = query.isEmpty ? emptyText : "No Results"
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
        (item as? Node)?.group != nil ? 28 : 44
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let group = node.group {
            let cell = outlineView.makeView(withIdentifier: GroupCell.identifier, owner: nil) as? GroupCell ?? GroupCell()
            cell.show(group, count: node.children.count, expanded: outlineView.isItemExpanded(node))
            cell.onToggle = { [weak self] in self?.toggle(node) }
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: ConnectionCell.identifier, owner: nil) as? ConnectionCell
            ?? ConnectionCell()
        if let c = node.connection { cell.show(c, tag: store.tag(of: c), inGroup: outlineView.parent(forItem: node) != nil) }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { onSelectionChange?() }

    func outlineViewItemDidExpand(_ notification: Notification) { collapseChanged(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { collapseChanged(notification, collapsed: true) }

    /// Collapsing is remembered with the group, except while searching (which expands all).
    private func collapseChanged(_ notification: Notification, collapsed: Bool) {
        if let node = notification.userInfo?["NSObject"] as? Node {
            let row = outline.row(forItem: node)
            if row >= 0 { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupCell)?.expanded = !collapsed }
        }
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

/// A group row: a section heading in the sidebar style, its name in small bold secondary text
/// and a chevron at the end that opens and closes it.
final class GroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupCell")
    private let title = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    var onToggle: (() -> Void)?
    var expanded = true {
        didSet {
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                    accessibilityDescription: expanded ? "Collapse" : "Expand")
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        chevron.isBordered = false
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.target = self
        chevron.action = #selector(toggle)
        expanded = true
        for v in [title, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            // As far from the selection's trailing edge as a connection's icon is from the leading
            // one (the button pads its symbol by a point).
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    func show(_ group: ConnectionGroup, count n: Int, expanded: Bool) {
        title.stringValue = group.name
        self.expanded = expanded
        setAccessibilityLabel("\(group.name), \(n) connection\(n == 1 ? "" : "s")")
    }
}

/// A saved connection in a list, as System Settings draws its rows: an icon (the database's logo
/// on its brand colour), the name with its tag after it, and under them the host or the file's
/// name. The rest (user, port, database, SSH, read-only, safe mode) is in the tooltip.
final class ConnectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")
    private let icon = ConnectionIcon()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let tagCapsule = TagCapsule()
    private let row = NSStackView()
    /// How far a group's connections sit in from the heading.
    static let groupIndent: CGFloat = 14

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for f in [title, detail] {
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // The tag sits right after the name; the name gives way first.
        let nameRow = NSStackView()
        nameRow.setViews([title, tagCapsule], in: .leading)
        nameRow.spacing = 6
        let text = NSStackView(views: [nameRow, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        nameRow.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true
        // Name and host stay together in the middle of the row, with or without a tag.
        for v in [nameRow, text] {
            v.setHuggingPriority(.required, for: .vertical)
        }
        row.setViews([icon, text], in: .leading)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6)
        addSubview(row)
        row.pin(to: self)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: ConnectionConfig, tag: ConnectionTag?, inGroup: Bool) {
        row.edgeInsets.left = 2 + (inGroup ? Self.groupIndent : 0)
        title.stringValue = c.displayName
        detail.stringValue = c.place
        toolTip = c.summary
        icon.show(c)
        tagCapsule.show(tag)
    }

    /// On the selected row the secondary line follows the selection's text colour.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            detail.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            tagCapsule.isEmphasized = backgroundStyle == .emphasized
            icon.isEmphasized = backgroundStyle == .emphasized
        }
    }
}

/// A connection's icon, as System Settings draws its panes': the database's logo in white on a
/// rounded square in its brand colour (`DriverLogos.swift`).
final class ConnectionIcon: NSView {
    static let size: CGFloat = 26
    private let logo = NSImageView()
    private var fill = NSColor.systemGray
    /// On the selected row a thin white edge keeps the square apart from the selection's colour.
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .white
        addSubview(logo)
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 16),
            logo.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: ConnectionConfig) {
        fill = c.driver.brandColor
        logo.image = c.driver.logo
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.backgroundColor = fill.cgColor
        layer.borderWidth = isEmphasized ? 1 : 0
        layer.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
    }
}

/// An outline that reports Return and Delete instead of beeping.
final class KeyOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    /// For rows that draw their own chevron (`GroupCell`).
    var hidesDisclosureTriangles = false

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        hidesDisclosureTriangles ? .zero : super.frameOfOutlineCell(atRow: row)
    }

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
