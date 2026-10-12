import AppCore
import AppKit
import DBKit

/// The connection's tables, views and functions, grouped by kind, with a filter field on top
/// and, for servers with several schemas or databases, a switcher at the bottom.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation
{
    /// SQL the context menu's "Copy Script As" writes.
    enum Script { case create, drop, truncate, select }

    /// A single click or arrow key previews (`.preview`), a double-click opens a regular tab,
    /// "Open in New Tab" always adds one.
    var onOpen: ((DatabaseObject, TabPlacement.Intent) -> Void)?
    var onOpenStructure: ((DatabaseObject) -> Void)?
    var onNewTable: (() -> Void)? {
        didSet { newTableButton.isEnabled = onNewTable != nil }
    }
    var onRename: ((DatabaseObject) -> Void)?
    var onRenameNewTable: ((UUID) -> Void)?
    var onTruncate: ((DatabaseObject) -> Void)?
    /// Delete… from the context menu: the dialog with options.
    var onDelete: ((DatabaseObject) -> Void)?
    /// ⌫ or ⌘⌫: marks the items for deletion at once and removes staged new tables.
    var onMarkForDeletion: ((_ objects: [DatabaseObject], _ newTables: [UUID]) -> Void)?
    var onCopyScript: ((DatabaseObject, Script) -> Void)?
    var onExport: ((DatabaseObject) -> Void)?
    /// Nil on read-only connections.
    var onImportCSV: ((DatabaseObject) -> Void)?
    /// After the object list (re)loads.
    var onObjectsLoaded: (([DatabaseObject]) -> Void)?
    /// What's staged for a table, drawn on its row.
    var markFor: ((TableRef) -> StagedChanges.Mark?)?
    /// Staged new tables, listed with the tables until they're created.
    var stagedNewTables: () -> [(id: UUID, name: String)] = { [] }
    /// The name a staged rename gives an item.
    var stagedNameFor: ((TableRef) -> String?)?
    var onOpenNewTable: ((UUID) -> Void)?
    /// Set while the selection follows the open tab, so it doesn't open anything.
    private var isRevealing = false
    /// Selected (without opening) once the next list has loaded: Quick Open's choice in another schema.
    var revealAfterReload: TableRef?
    /// A schema to switch to once the schemas have loaded (restoring a session).
    var schemaToRestore: String?

    private let connection: any DatabaseConnection
    private let outline = SidebarOutline()
    private let filter = NSSearchField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let schemaPopup = NSPopUpButton()
    private let schemaBar = NSStackView()
    private let newTableButton = NSButton()
    /// The schema (Postgres) or database (MySQL) whose items are listed; nil for SQLite, or a
    /// MySQL connection without a default database.
    private(set) var schema: String?
    private var schemasLoaded = false
    private var objects: [DatabaseObject] = []
    private var groups: [Group] = []
    private var loadTask: Task<Void, Never>?

    /// Outline items must be objects with stable identity.
    final class Group {
        let title: String
        let items: [Item]
        init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    final class Item {
        let object: DatabaseObject
        /// Set for a staged new table.
        let newTableID: UUID?
        init(_ object: DatabaseObject, newTableID: UUID? = nil) {
            self.object = object
            self.newTableID = newTableID
        }
    }

    init(connection: any DatabaseConnection) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.autosaveExpandedItems = false
        outline.allowsMultipleSelection = true
        outline.onDeleteKey = { [weak self] in self?.deleteRows(nil) }
        outline.onTruncateKey = { [weak self] in self?.truncateTable(nil) }
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Structure", action: #selector(openStructure(_:)), keyEquivalent: "").target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Table…", action: #selector(newTable(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rename…", action: #selector(renameItem(_:)), keyEquivalent: "").target = self
        // The shortcuts shown are the keys the list handles (⌘⌫ marks without the dialog).
        let truncate = menu.addItem(withTitle: "Truncate…", action: #selector(truncateItem(_:)), keyEquivalent: "\u{8}")
        truncate.keyEquivalentModifierMask = .option
        truncate.target = self
        menu.addItem(withTitle: "Delete…", action: #selector(deleteItem(_:)), keyEquivalent: "\u{8}").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Export…", action: #selector(exportItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Import CSV…", action: #selector(importCSVItem(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "").target = self
        let scripts = NSMenuItem(title: "Copy Script As", action: nil, keyEquivalent: "")
        scripts.submenu = NSMenu()
        for (title, tag) in [("CREATE", 0), ("DROP", 1), ("TRUNCATE", 2), ("SELECT", 3)] {
            let item = scripts.submenu!.addItem(withTitle: title, action: #selector(copyScript(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        menu.addItem(scripts)
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true

        schemaPopup.controlSize = .small
        schemaPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        schemaPopup.target = self
        schemaPopup.action = #selector(schemaChosen(_:))
        schemaPopup.toolTip = "Schema"
        newTableButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New table")
        newTableButton.bezelStyle = .accessoryBarAction
        newTableButton.controlSize = .small
        newTableButton.target = self
        newTableButton.action = #selector(newTable(_:))
        newTableButton.toolTip = "New table"
        schemaBar.addArrangedSubview(newTableButton)
        schemaBar.addArrangedSubview(schemaPopup)
        schemaBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        schemaPopup.isHidden = true
        schemaPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        for v in [filter, scroll, message, schemaBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: schemaBar.topAnchor),
            schemaBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            schemaBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            schemaBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
    }

    /// Selects (and so opens) the item with this name. False if the list has no such item yet.
    @discardableResult
    func select(named name: String) -> Bool {
        select { $0.ref.name == name }
    }

    /// Selects (and so opens) the first item matching `predicate`.
    @discardableResult
    func select(where predicate: (DatabaseObject) -> Bool) -> Bool {
        for g in groups {
            if let item = g.items.first(where: { predicate($0.object) }) {
                outline.selectRowIndexes([outline.row(forItem: item)], byExtendingSelection: false)
                return true
            }
        }
        return false
    }

    /// Selects the item for `ref` (or nothing) without opening it, so the list follows the
    /// selected tab.
    func reveal(_ ref: TableRef?) {
        reveal(row: ref.flatMap { r in rowOfItem { $0.newTableID == nil && $0.object.ref == r } })
    }

    /// Selects these items without opening them (after an undo, say).
    func reveal(_ refs: [TableRef]) {
        let rows = refs.compactMap { r in rowOfItem { $0.newTableID == nil && $0.object.ref == r } }
        isRevealing = true
        defer { isRevealing = false }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
        view.window?.makeFirstResponder(outline)
    }

    func reveal(newTable id: UUID) {
        reveal(row: rowOfItem { $0.newTableID == id })
    }

    private func reveal(row: Int?) {
        isRevealing = true
        defer { isRevealing = false }
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
    }

    /// The item a context-menu command applies to: the clicked row, else the selection.
    private var targetItem: Item? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? Item
    }

    private var targetObject: DatabaseObject? {
        guard let item = targetItem, item.newTableID == nil else { return nil }
        return item.object
    }

    /// The items a key command applies to: the selection, or the clicked row when it's outside it.
    private var targetItems: [Item] {
        let clicked = outline.clickedRow
        let rows = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) ? [clicked] : outline.selectedRowIndexes
        return rows.compactMap { outline.item(atRow: $0) as? Item }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
        open(item, intent: .regular)
    }

    private func open(_ item: Item, intent: TabPlacement.Intent) {
        if let id = item.newTableID {
            onOpenNewTable?(id)
            return
        }
        if Self.opensInGrid(item.object) { onOpen?(item.object, intent) }
    }

    /// Redraws staged marks and the staged new tables.
    func stagedChangesChanged() {
        guard isViewLoaded else { return }
        rebuild()
    }

    /// Tables and views open in a grid; functions are listed only (their editor comes later).
    static func opensInGrid(_ object: DatabaseObject) -> Bool {
        [.table, .view, .materializedView].contains(object.kind)
    }

    /// The schemas (Postgres) or databases (MySQL) the switcher offers; empty for SQLite.
    var schemaNames: [String] { schemaPopup.isHidden ? [] : schemaPopup.itemTitles }

    /// Lists another schema, as if picked from the switcher. False if there is no such schema.
    @discardableResult
    func switchSchema(to name: String) -> Bool {
        guard schemaPopup.item(withTitle: name) != nil else { return false }
        schemaPopup.selectItem(withTitle: name)
        schemaChosen(nil)
        return true
    }

    @objc private func schemaChosen(_ sender: Any?) {
        guard let chosen = schemaPopup.titleOfSelectedItem, chosen != schema else { return }
        schema = chosen
        Task {
            // Unqualified names in query tabs follow the switch too.
            if let sql = connection.dialect.useSchema(chosen) {
                do {
                    _ = try await connection.execute(sql)
                } catch {
                    showMessage("Couldn't switch to \(chosen):\n\(error)")
                }
            }
            reload()
        }
    }

    @objc private func openInNewTab(_ sender: Any?) {
        if let object = targetObject, Self.opensInGrid(object) { onOpen?(object, .newTab) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.isEnabled = targetObject.map(Self.opensInGrid) ?? false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let kind = targetObject?.kind
        switch item.action {
        case #selector(openInNewTab(_:)), #selector(openStructure(_:)):
            return targetObject.map(Self.opensInGrid) ?? false
        case #selector(newTable(_:)):
            return onNewTable != nil
        case #selector(deleteRows(_:)):
            let items = targetItems.filter { $0.newTableID != nil || $0.object.kind != .function }
            let kinds = Set(items.map { $0.object.kind == .table ? "Table" : "View" })
            if item.menu?.title == "Edit" { item.title = items.count > 1 ? "Delete Items" : "Delete \(kinds.first ?? "Table")" }
            return onMarkForDeletion != nil && !items.isEmpty
        case #selector(truncateTable(_:)):
            return onNewTable != nil && kind == .table
        case #selector(renameItem(_:)):
            return targetItem?.newTableID != nil || kind != nil && kind != .function
        case #selector(deleteItem(_:)):
            return kind != nil && kind != .function
        case #selector(truncateItem(_:)):
            return kind == .table
        case #selector(exportItem(_:)):
            return kind == .table || kind == .view || kind == .materializedView
        case #selector(importCSVItem(_:)):
            return kind == .table && onImportCSV != nil
        case #selector(copyScript(_:)):
            guard let kind else { return false }
            return item.tag == 2 ? kind == .table : true
        default:
            return true
        }
    }

    @objc private func openStructure(_ sender: Any?) {
        if let object = targetObject, Self.opensInGrid(object) { onOpenStructure?(object) }
    }

    @objc private func newTable(_ sender: Any?) { onNewTable?() }

    @objc private func renameItem(_ sender: Any?) {
        if let id = targetItem?.newTableID {
            onRenameNewTable?(id)
        } else if let object = targetObject {
            onRename?(object)
        }
    }

    @objc private func truncateItem(_ sender: Any?) {
        if let object = targetObject { onTruncate?(object) }
    }

    /// ⌥⌫ (Edit ▸ Truncate Table…): the truncate dialog for the selected table.
    @objc func truncateTable(_ sender: Any?) {
        guard let object = targetObject, object.kind == .table else { return NSSound.beep() }
        onTruncate?(object)
    }

    /// ⌫ or ⌘⌫ (Edit ▸ Delete): marks the selected tables and views for deletion at once, with
    /// no dialog, and removes selected new tables. Functions are left alone.
    @objc func deleteRows(_ sender: Any?) {
        let items = targetItems
        let objects = items.filter { $0.newTableID == nil && $0.object.kind != .function }.map(\.object)
        let newTables = items.compactMap(\.newTableID)
        guard let onMarkForDeletion, !objects.isEmpty || !newTables.isEmpty else { return NSSound.beep() }
        onMarkForDeletion(objects, newTables)
    }

    @objc private func deleteItem(_ sender: Any?) {
        if let object = targetObject { onDelete?(object) }
    }

    @objc private func exportItem(_ sender: Any?) {
        if let object = targetObject { onExport?(object) }
    }

    @objc private func importCSVItem(_ sender: Any?) {
        if let object = targetObject { onImportCSV?(object) }
    }

    @objc private func copyScript(_ sender: NSMenuItem) {
        guard let object = targetObject else { return }
        let script: Script = switch sender.tag {
        case 0: .create
        case 1: .drop
        case 2: .truncate
        default: .select
        }
        onCopyScript?(object, script)
    }

    @objc private func copyName(_ sender: Any?) {
        guard let object = targetObject else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(object.ref.name, forType: .string)
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filter)
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                if !schemasLoaded {
                    try await loadSchemas()
                    if let wanted = schemaToRestore {
                        schemaToRestore = nil
                        if wanted != schema, switchSchema(to: wanted) { return }
                    }
                }
                // MySQL without a default database: nothing to list until one is chosen.
                if schema == nil, !schemaPopup.isHidden {
                    self.objects = []
                    rebuild()
                    showMessage("Choose a database below.")
                    onObjectsLoaded?([])
                    return
                }
                let objects = try await connection.objects(schema: schema)
                guard !Task.isCancelled else { return }
                self.objects = objects
                rebuild()
                onObjectsLoaded?(objects)
                if let ref = revealAfterReload {
                    revealAfterReload = nil
                    reveal([ref])
                }
            } catch {
                guard !Task.isCancelled else { return }
                objects = []
                rebuild()
                showMessage("Couldn't list items:\n\(error)")
            }
        }
    }

    private func loadSchemas() async throws {
        let schemas = try await connection.schemas()
        let current = try await connection.currentSchema()
        guard !Task.isCancelled else { return }
        schemasLoaded = true
        schema = current
        schemaPopup.isHidden = schemas.isEmpty
        schemaPopup.removeAllItems()
        schemaPopup.addItems(withTitles: schemas)
        // The current schema can be one the list leaves out (a system one).
        if let current, !schemas.contains(current) { schemaPopup.addItem(withTitle: current) }
        if let current { schemaPopup.selectItem(withTitle: current) } else { schemaPopup.select(nil) }
    }

    private func rebuild() {
        let selectedItems = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? objects : objects.filter { $0.ref.name.localizedCaseInsensitiveContains(query) }
        let newTables = stagedNewTables()
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { Item(DatabaseObject(TableRef(schema: schema, $0.name), kind: .table), newTableID: $0.id) }

        let sections: [(ObjectKind, String)] = [
            (.table, "Tables"), (.view, "Views"), (.materializedView, "Materialized Views"), (.function, "Functions"),
        ]
        groups = sections.compactMap { kind, title in
            var items = matching.filter { $0.kind == kind }.map { Item($0) }
            if kind == .table { items += newTables }
            return items.isEmpty ? nil : Group(title: title, items: items)
        }
        outline.reloadData()
        for g in groups { outline.expandItem(g) }

        let rows = selectedItems.compactMap { selected in
            rowOfItem { item in
                if let id = selected.newTableID { return item.newTableID == id }
                return item.newTableID == nil && item.object == selected.object
            }
        }
        if !rows.isEmpty {
            isRevealing = true
            outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            isRevealing = false
        }
        if objects.isEmpty && newTables.isEmpty {
            showMessage(schema.map { "“\($0)” has no tables yet." } ?? "This database has no tables yet.")
        } else if groups.isEmpty {
            showMessage("Nothing matches “\(query)”.")
        } else {
            message.isHidden = true
        }
    }

    private func showMessage(_ text: String) {
        message.stringValue = text
        message.isHidden = false
    }

    private func rowOfItem(_ predicate: (Item) -> Bool) -> Int? {
        for g in groups {
            if let item = g.items.first(where: predicate) {
                let row = outline.row(forItem: item)
                return row >= 0 ? row : nil
            }
        }
        return nil
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Down arrow from the filter moves into the list; Return opens the first match.
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            if outline.selectedRow < 0, let first = groups.first?.items.first {
                outline.selectRowIndexes([outline.row(forItem: first)], byExtendingSelection: false)
            }
            view.window?.makeFirstResponder(outline)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            filter.stringValue = ""
            rebuild()
            return true
        }
        return false
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        return (item as? Group)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        return (item as! Group).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Group }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Item }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? Group {
            let id = NSUserInterfaceItemIdentifier("Header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let f = NSTextField(labelWithString: "")
                c.addSubview(f)
                f.translatesAutoresizingMaskIntoConstraints = false
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2).isActive = true
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor).isActive = true
                c.textField = f
                return c
            }()
            cell.textField?.stringValue = "\(group.title)  \(group.items.count)"
            return cell
        }
        guard let item = item as? Item else { return nil }
        let id = NSUserInterfaceItemIdentifier("Item")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            for v in [image, text] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.imageView = image
            c.textField = text
            return c
        }()
        var (symbol, tint): (String, NSColor) = switch item.object.kind {
        case .table: ("tablecells", .systemBlue)
        case .function, .sequence: ("function", .systemOrange)
        default: ("eye", .systemPurple)
        }
        // Staged changes: edited and truncated tables in orange, dropped ones struck out in
        // red, new ones in green, until the workspace commits or discards them.
        let mark = item.newTableID == nil ? markFor?(item.object.ref) : nil
        var attributes: [NSAttributedString.Key: Any] = [:]
        var tip: String?
        if item.newTableID != nil {
            (symbol, tint) = ("plus.rectangle", .systemGreen)
            attributes[.foregroundColor] = NSColor.systemGreen
            tip = "New table, created when you commit (⌘S)"
        } else if let mark {
            switch mark {
            case .edited:
                attributes[.foregroundColor] = NSColor.systemOrange
                tip = "Staged changes"
            case .truncated:
                attributes[.foregroundColor] = NSColor.systemOrange
                symbol = "tablecells.badge.ellipsis"
                tip = "Truncate staged"
            case .dropped:
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                tip = "Delete staged"
            }
            tint = attributes[.foregroundColor] as? NSColor ?? tint
        }
        // A staged rename shows the new name.
        let name = item.newTableID == nil ? stagedNameFor?(item.object.ref) ?? item.object.ref.name : item.object.ref.name
        if name != item.object.ref.name { tip = "Rename staged (was \(item.object.ref.name))" }
        cell.textField?.attributedStringValue = NSAttributedString(string: name, attributes: attributes)
        cell.toolTip = tip
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.object.kind.rawValue)
            ?? NSImage(systemSymbolName: "tablecells", accessibilityDescription: item.object.kind.rawValue)
        cell.imageView?.contentTintColor = tint
        return cell
    }

    /// Selecting an item opens it, so arrow keys browse tables one after another. Selecting
    /// several opens nothing.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, outline.selectedRowIndexes.count == 1,
              let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        open(item, intent: .preview)
    }
}

/// The items list. ⌫ and ⌦ mark the selection for deletion; ⌥⌫ truncates.
final class SidebarOutline: NSOutlineView {
    var onDeleteKey: (() -> Void)?
    var onTruncateKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (51, []), (117, []): onDeleteKey?()
        case (51, .option): onTruncateKey?()
        default: super.keyDown(with: event)
        }
    }
}
