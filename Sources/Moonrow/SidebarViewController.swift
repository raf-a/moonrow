import AppCore
import AppKit
import DBKit

/// The connection's tables, views, functions and procedures, grouped by kind, with a filter
/// field on top and, for servers with several schemas or databases, a switcher at the bottom.
/// Staged new objects and clones are listed in green until the commit creates them.
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
        didSet {
            newButton.isEnabled = onNewTable != nil
        }
    }
    /// New ▸ View, Materialized View, Function, Procedure.
    var onNewDefinition: ((DefinitionKind) -> Void)?
    /// Which kinds the database has.
    var supportsDefinition: (DefinitionKind) -> Bool = { _ in false }
    var onClone: ((DatabaseObject) -> Void)?
    var onRefreshMaterializedView: ((DatabaseObject) -> Void)?
    var onShowDiagram: (() -> Void)?
    var onSearchInDatabase: (() -> Void)?
    var onRename: ((DatabaseObject) -> Void)?
    var onRenameNewTable: ((UUID) -> Void)?
    var onTruncate: ((DatabaseObject) -> Void)?
    /// Delete… from the context menu: the dialog with options.
    var onDelete: ((DatabaseObject) -> Void)?
    /// ⌫ or ⌘⌫: marks the items for deletion at once and removes staged new objects and clones.
    var onMarkForDeletion: ((Deletion) -> Void)?
    var onCopyScript: ((DatabaseObject, Script) -> Void)?
    var onExport: ((DatabaseObject) -> Void)?
    /// Export Tables… with the selected tables and views ticked.
    var onExportTables: (() -> Void)?
    /// Nil on read-only connections.
    var onImport: ((DatabaseObject, ImportFormat) -> Void)?
    /// After the object list (re)loads.
    var onObjectsLoaded: (([DatabaseObject]) -> Void)?
    /// Once, after the next list loads (tabs following what a commit created).
    var afterNextLoad: (([DatabaseObject]) -> Void)?
    /// What's staged for an item, drawn on its row.
    var markFor: ((DatabaseObject) -> StagedChanges.Mark?)?
    /// Staged new tables, listed with the tables until they're created.
    var stagedNewTables: () -> [(id: UUID, name: String)] = { [] }
    /// Staged new views and routines, listed in their sections until they're created.
    var stagedNewDefinitions: () -> [(id: UUID, kind: DefinitionKind, name: String)] = { [] }
    /// Names of staged clones, listed with the tables.
    var stagedClones: () -> [String] = { [] }
    var onOpenNewDefinition: ((UUID) -> Void)?
    /// The name a staged rename gives an item.
    var stagedNameFor: ((TableRef) -> String?)?
    var onOpenNewTable: ((UUID) -> Void)?
    /// Set while the selection follows the open tab, so it doesn't open anything.
    /// Selection that follows the selected tab, which opens nothing.
    private let quiet = QuietSelection()
    /// Selected (without opening) once the next list has loaded: Quick Open's choice in another schema.
    var revealAfterReload: TableRef?
    /// A schema to switch to once the schemas have loaded (restoring a session).
    var schemaToRestore: String?
    /// A MySQL connection without a database listed nothing; the workspace opens ⌘K over it.
    var onNoDatabase: (() -> Void)?

    private let connection: any DatabaseConnection
    private let outline = SidebarOutline()
    private let filter: NSSearchField = SidebarSearchField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let schemaPopup = NSPopUpButton()
    private let schemaBar = NSStackView()
    /// A round + that opens the New menu: glass on macOS 26, the system's round button before.
    private let newButton = NSButton()
    /// The + button's menu; internal for the harness.
    lazy var newMenu = makeNewMenu(standalone: true)
    /// The schema (Postgres) or database (MySQL) whose items are listed; nil for SQLite, or a
    /// MySQL connection without a default database.
    private(set) var schema: String?
    /// The schemas (Postgres) or databases (MySQL) the workspace can list.
    private(set) var schemaList: [String] = []
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
        /// Set for a staged new view or routine.
        let newDefinitionID: UUID?
        /// A table that a staged clone creates.
        let isClone: Bool
        /// An overloaded routine shows its arguments.
        var showsSignature = false

        init(_ object: DatabaseObject, newTableID: UUID? = nil, newDefinitionID: UUID? = nil, isClone: Bool = false) {
            self.object = object
            self.newTableID = newTableID
            self.newDefinitionID = newDefinitionID
            self.isClone = isClone
        }

        /// Exists only as staged so far.
        var isStaged: Bool { newTableID != nil || newDefinitionID != nil || isClone }
    }

    /// What ⌫ marks or removes.
    struct Deletion {
        var objects: [DatabaseObject] = []
        var newTables: [UUID] = []
        var newDefinitions: [UUID] = []
        var clones: [String] = []
        var isEmpty: Bool { objects.isEmpty && newTables.isEmpty && newDefinitions.isEmpty && clones.isEmpty }
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Structure", action: #selector(openStructure(_:)), keyEquivalent: "").target = self
        menu.delegate = self
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        new.submenu = makeNewMenu()
        menu.addItem(new)
        menu.addItem(withTitle: "Rename…", action: #selector(renameItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clone…", action: #selector(cloneItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Materialized View", action: #selector(refreshItem(_:)), keyEquivalent: "").target = self
        // The shortcuts shown are the keys the list handles (⌘⌫ marks without the dialog).
        let truncate = menu.addItem(withTitle: "Truncate…", action: #selector(truncateItem(_:)), keyEquivalent: "\u{8}")
        truncate.keyEquivalentModifierMask = .option
        truncate.target = self
        menu.addItem(withTitle: "Delete…", action: #selector(deleteItem(_:)), keyEquivalent: "\u{8}").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Export…", action: #selector(exportItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Export Tables…", action: #selector(exportTablesItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Import CSV…", action: #selector(importCSVItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Import JSON…", action: #selector(importJSONItem(_:)), keyEquivalent: "").target = self
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Diagram", action: #selector(showDiagramItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search in Database…", action: #selector(searchItem(_:)), keyEquivalent: "").target = self
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
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        newButton.imagePosition = .imageOnly
        if #available(macOS 26.0, *) {
            newButton.bezelStyle = .glass
            newButton.borderShape = .circle
            newButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
            newButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        } else {
            newButton.bezelStyle = .circular
        }
        newButton.controlSize = .large
        newButton.toolTip = "New table, view, function or procedure"
        newButton.target = self
        newButton.action = #selector(showNewMenu(_:))
        newButton.setContentHuggingPriority(.required, for: .horizontal)
        schemaBar.addArrangedSubview(newButton)
        schemaBar.addArrangedSubview(schemaPopup)
        schemaBar.spacing = 8
        schemaBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
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
    /// The listed object called `name`, if any (the harnesses open it).
    func object(named name: String) -> DatabaseObject? {
        objects.first { $0.ref.name == name }
    }

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
        reveal(row: ref.flatMap { r in rowOfItem { !$0.isStaged && $0.object.ref == r && $0.object.kind.isRelation } })
    }

    /// Selects a routine's item (or nothing) without opening it.
    func reveal(_ object: DatabaseObject?) {
        reveal(row: object.flatMap { o in rowOfItem { !$0.isStaged && $0.object == o } })
    }

    /// Selects these items without opening them (after an undo, say).
    func reveal(_ refs: [TableRef]) {
        let rows = refs.compactMap { r in rowOfItem { !$0.isStaged && $0.object.ref == r } }
        quiet.select(IndexSet(rows), in: outline)
        view.window?.makeFirstResponder(outline)
    }

    func reveal(newTable id: UUID) {
        reveal(row: rowOfItem { $0.newTableID == id })
    }

    func reveal(newDefinition id: UUID) {
        reveal(row: rowOfItem { $0.newDefinitionID == id })
    }

    private func reveal(row: Int?) {
        quiet.select(row, in: outline)
    }

    /// The item a context-menu command applies to: the clicked row, else the selection.
    private var targetItem: Item? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? Item
    }

    private var targetObject: DatabaseObject? {
        guard let item = targetItem, !item.isStaged else { return nil }
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
        } else if let id = item.newDefinitionID {
            onOpenNewDefinition?(id)
        } else if !item.isClone, Self.opens(item.object) {
            // A clone opens once the commit has created it.
            onOpen?(item.object, intent)
        }
    }

    /// Differentiate without colour was switched: the state letters show or hide.
    @objc private func displayOptionsChanged() {
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: [0])
    }

    /// Redraws staged marks and the staged new tables.
    func stagedChangesChanged() {
        guard isViewLoaded else { return }
        rebuild()
    }

    /// Tables and views open in a grid, routines in a definition tab.
    static func opensInGrid(_ object: DatabaseObject) -> Bool { object.kind.isRelation }

    static func opens(_ object: DatabaseObject) -> Bool { object.kind.isRelation || object.kind.isRoutine }

    /// The schemas (Postgres) or databases (MySQL) the workspace lists; empty for SQLite.
    var schemaNames: [String] { schemaList }

    var showsSchemaSwitcher: Bool { !schemaPopup.isHidden }

    /// Only Postgres has the switcher at the bottom: MySQL's databases are ⌘K's, and SQLite has
    /// one namespace.
    private var hasSchemaSwitcher: Bool { connection.dialect.lexer == .postgres }

    /// Lists another schema (or MySQL database), as if picked from the switcher. False if there
    /// is no such schema.
    @discardableResult
    func switchSchema(to name: String) -> Bool {
        guard schemaList.contains(name) else { return false }
        if schemaPopup.item(withTitle: name) != nil { schemaPopup.selectItem(withTitle: name) }
        choose(name)
        return true
    }

    /// Lists the schemas again, then the current one's items: after the connection moved to
    /// another database, or a database was created or dropped.
    func reloadSchemas() {
        schemasLoaded = false
        reload()
    }

    @objc private func schemaChosen(_ sender: Any?) {
        guard let chosen = schemaPopup.titleOfSelectedItem else { return }
        choose(chosen)
    }

    private func choose(_ chosen: String) {
        guard chosen != schema else { return }
        // A listing still on its way would put back the schema it read before the switch.
        loadTask?.cancel()
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
        if let object = targetObject, Self.opens(object) { onOpen?(object, .newTab) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.isEnabled = targetObject.map(Self.opens) ?? false
    }

    /// The + button's menu, above it (the button sits at the window's bottom edge).
    @objc private func showNewMenu(_ sender: NSButton) {
        let above = sender.isFlipped ? sender.bounds.minY - 4 : sender.bounds.maxY + 4
        // Validation hides the kinds the database lacks; it has to run before the menu is measured.
        newMenu.update()
        let height = newMenu.size.height
        let origin = sender.isFlipped ? above - height : above + height
        newMenu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: origin), in: sender)
    }

    /// New ▸ Table…, View, Materialized View, Function, Procedure.
    /// `standalone` is the + button's menu, whose items say "New …" as there is no New ▸ above them.
    private func makeNewMenu(standalone: Bool = false) -> NSMenu {
        let menu = NSMenu(title: "New")
        menu.addItem(withTitle: standalone ? "New Table" : "Table…", action: #selector(newTable(_:)), keyEquivalent: "")
            .target = self
        for kind in [DefinitionKind.view, .materializedView, .function, .procedure] {
            let title = standalone ? "New \(kind.title.capitalized)" : kind.title.capitalized
            let item = menu.addItem(withTitle: title, action: #selector(newDefinitionItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
        }
        return menu
    }

    @objc private func newDefinitionItem(_ sender: NSMenuItem) {
        guard let kind = (sender.representedObject as? String).flatMap(DefinitionKind.init(rawValue:)) else { return }
        onNewDefinition?(kind)
    }

    /// "Delete Table", "Delete Function", "Delete Items".
    private func deleteTitle(_ deletion: Deletion) -> String {
        let count = deletion.objects.count + deletion.newTables.count + deletion.newDefinitions.count + deletion.clones.count
        if count > 1 { return "Delete Items" }
        if let o = deletion.objects.first {
            return "Delete " + (DefinitionKind(o.kind)?.title.capitalized ?? "Table")
        }
        if let id = deletion.newDefinitions.first, let d = stagedNewDefinitions().first(where: { $0.id == id }) {
            return "Delete " + d.kind.title.capitalized
        }
        return "Delete Table"
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let kind = targetObject?.kind
        switch item.action {
        case #selector(openInNewTab(_:)):
            return targetObject.map(Self.opens) ?? false
        case #selector(openStructure(_:)):
            return targetObject.map(Self.opensInGrid) ?? false
        case #selector(newTable(_:)):
            return onNewTable != nil
        case #selector(newDefinitionItem(_:)):
            guard let kind = (item.representedObject as? String).flatMap(DefinitionKind.init(rawValue:)) else { return false }
            item.isHidden = !supportsDefinition(kind)
            return onNewDefinition != nil && onNewTable != nil && supportsDefinition(kind)
        case #selector(deleteRows(_:)):
            let deletion = deletionTargets
            if item.menu?.title == "Edit" { item.title = deleteTitle(deletion) }
            return onMarkForDeletion != nil && !deletion.isEmpty
        case #selector(truncateTable(_:)):
            return onNewTable != nil && kind == .table
        case #selector(renameItem(_:)):
            return targetItem?.newTableID != nil || kind?.isRelation == true
        case #selector(cloneItem(_:)):
            return kind == .table && onClone != nil
        case #selector(refreshItem(_:)):
            item.isHidden = kind != .materializedView
            return kind == .materializedView && onRefreshMaterializedView != nil
        case #selector(deleteItem(_:)):
            // A staged object goes at once, with no dialog: there's nothing to drop yet.
            let isStaged = targetItem?.isStaged == true
            item.title = isStaged ? "Delete" : "Delete…"
            return (isStaged || kind != nil && kind != .sequence) && onMarkForDeletion != nil
        case #selector(truncateItem(_:)):
            return kind == .table
        case #selector(exportItem(_:)):
            return kind?.isRelation == true
        case #selector(importCSVItem(_:)), #selector(importJSONItem(_:)):
            return kind == .table && onImport != nil
        case #selector(exportTablesItem(_:)):
            return onExportTables != nil
        case #selector(copyScript(_:)):
            guard let kind else { return false }
            if kind.isRoutine { return item.tag <= 1 }
            return item.tag == 2 ? kind == .table : true
        case #selector(showDiagramItem(_:)):
            return onShowDiagram != nil
        case #selector(searchItem(_:)):
            return onSearchInDatabase != nil
        default:
            return true
        }
    }

    @objc private func cloneItem(_ sender: Any?) {
        if let object = targetObject, object.kind == .table { onClone?(object) }
    }

    @objc private func refreshItem(_ sender: Any?) {
        if let object = targetObject, object.kind == .materializedView { onRefreshMaterializedView?(object) }
    }

    @objc private func showDiagramItem(_ sender: Any?) { onShowDiagram?() }
    @objc private func searchItem(_ sender: Any?) { onSearchInDatabase?() }

    /// The selected items ⌫ applies to: existing objects to mark, staged ones to remove.
    private var deletionTargets: Deletion { Self.deletion(of: targetItems) }

    private static func deletion(of items: [Item]) -> Deletion {
        var d = Deletion()
        for item in items {
            if let id = item.newTableID { d.newTables.append(id) }
            else if let id = item.newDefinitionID { d.newDefinitions.append(id) }
            else if item.isClone { d.clones.append(item.object.ref.name) }
            else if item.object.kind != .sequence { d.objects.append(item.object) }
        }
        return d
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

    /// ⌫ or ⌘⌫ (Edit ▸ Delete): marks the selected tables, views and routines for deletion at
    /// once, with no dialog, and removes selected new objects and clones.
    @objc func deleteRows(_ sender: Any?) {
        let deletion = deletionTargets
        guard let onMarkForDeletion, !deletion.isEmpty else { return NSSound.beep() }
        onMarkForDeletion(deletion)
    }

    /// Delete…: the drop dialog for an existing object; a new object or clone is removed.
    @objc private func deleteItem(_ sender: Any?) {
        guard let item = targetItem else { return }
        if item.isStaged {
            onMarkForDeletion?(Self.deletion(of: [item]))
        } else {
            onDelete?(item.object)
        }
    }

    @objc private func exportItem(_ sender: Any?) {
        if let object = targetObject { onExport?(object) }
    }

    @objc private func importCSVItem(_ sender: Any?) {
        if let object = targetObject { onImport?(object, .csv) }
    }

    @objc private func importJSONItem(_ sender: Any?) {
        if let object = targetObject { onImport?(object, .json) }
    }

    @objc private func exportTablesItem(_ sender: Any?) { onExportTables?() }

    /// The selected tables, views and routines (not staged ones).
    var selectedObjects: [DatabaseObject] {
        targetItems.filter { !$0.isStaged }.map(\.object)
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

    /// What has the focus when the window opens: the list, not the filter.
    var initialFirstResponder: NSView { outline }

    func reload() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                if !schemasLoaded {
                    try await loadSchemas()
                    // A newer listing replaced this one; it takes the schema to restore.
                    guard !Task.isCancelled else { return }
                    if let wanted = schemaToRestore {
                        schemaToRestore = nil
                        if wanted != schema, switchSchema(to: wanted) { return }
                    }
                }
                // MySQL without a default database: nothing to list until one is chosen with ⌘K.
                if schema == nil, !schemaList.isEmpty {
                    self.objects = []
                    rebuild()
                    showMessage("No database is open.")
                    onObjectsLoaded?([])
                    onNoDatabase?()
                    return
                }
                let objects = try await connection.objects(schema: schema)
                guard !Task.isCancelled else { return }
                self.objects = objects
                rebuild()
                onObjectsLoaded?(objects)
                if let after = afterNextLoad {
                    afterNextLoad = nil
                    after(objects)
                }
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
        // The current schema can be one the list leaves out (a system one).
        schemaList = schemas + (current.map { schemas.contains($0) ? [] : [$0] } ?? [])
        schemaPopup.isHidden = schemaList.isEmpty || !hasSchemaSwitcher
        schemaPopup.removeAllItems()
        schemaPopup.addItems(withTitles: schemaList)
        if let current { schemaPopup.selectItem(withTitle: current) } else { schemaPopup.select(nil) }
    }

    private func rebuild() {
        let selectedItems = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces)
        func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }
        let matching = objects.filter { matches($0.ref.name) }
        var staged = stagedNewTables().filter { matches($0.name) }
            .map { Item(DatabaseObject(TableRef(schema: schema, $0.name), kind: .table), newTableID: $0.id) }
        staged += stagedClones().filter(matches).map { Item(DatabaseObject(TableRef(schema: schema, $0), kind: .table), isClone: true) }
        staged += stagedNewDefinitions().filter { matches($0.name) }.compactMap { d in
            d.kind.objectKind.map { Item(DatabaseObject(TableRef(schema: schema, d.name), kind: $0), newDefinitionID: d.id) }
        }
        // Overloads are told apart by their arguments.
        let routineNames = matching.filter(\.kind.isRoutine).map { "\($0.kind.rawValue) \($0.ref.name)" }
        let overloaded = Set(Dictionary(grouping: routineNames) { $0 }.filter { $0.value.count > 1 }.keys)

        let sections: [(ObjectKind, String)] = [
            (.table, "Tables"), (.view, "Views"), (.materializedView, "Materialized Views"), (.function, "Functions"),
            (.procedure, "Procedures"),
        ]
        groups = sections.compactMap { kind, title in
            var items = matching.filter { $0.kind == kind }.map { object in
                let item = Item(object)
                item.showsSignature = overloaded.contains("\(object.kind.rawValue) \(object.ref.name)")
                return item
            }
            items += staged.filter { $0.object.kind == kind }
            return items.isEmpty ? nil : Group(title: title, items: items)
        }
        outline.reloadData()
        for g in groups { outline.expandItem(g) }

        let rows = selectedItems.compactMap { selected in
            rowOfItem { item in
                if let id = selected.newTableID { return item.newTableID == id }
                if let id = selected.newDefinitionID { return item.newDefinitionID == id }
                if selected.isClone { return item.isClone && item.object == selected.object }
                return !item.isStaged && item.object == selected.object
            }
        }
        if !rows.isEmpty { quiet.select(IndexSet(rows), in: outline, scroll: false) }
        if objects.isEmpty && staged.isEmpty {
            showMessage(schema.map { "“\($0)” has no tables yet." } ?? "This database has no tables yet.")
        } else if groups.isEmpty {
            showMessage("No Results")
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

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { GreySelectionRowView() }

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
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        let (symbol, tint): (String, NSColor) = switch item.object.kind {
        case .table: ("tablecells", .systemBlue)
        case .function, .sequence: ("function", .systemOrange)
        case .procedure: ("curlybraces", .systemOrange)
        case .materializedView: ("square.stack.3d.up", .systemPurple)
        case .view: ("eye", .systemPurple)
        }
        // Staged changes colour the name, never the icon: new objects in green, edited, renamed
        // and truncated ones in orange, dropped ones struck out in red, until the workspace
        // commits or discards them.
        let mark = item.isStaged ? nil : markFor?(item.object)
        var state: StagedState?
        var tip: String?
        if item.isStaged {
            state = .new
            let what = item.isClone ? "Clone" : "New \(DefinitionKind(item.object.kind)?.title ?? "table")"
            tip = "\(what), created when you commit (⌘S)"
        } else if let mark {
            switch mark {
            case .edited:
                state = .edited
                tip = "Staged changes"
            case .truncated:
                state = .edited
                tip = "Truncate staged"
            case .dropped:
                state = .dropped
                tip = "Delete staged"
            }
        }
        // A staged rename shows the new name; overloads show their arguments.
        var name = !item.isStaged && item.object.kind.isRelation ? stagedNameFor?(item.object.ref) ?? item.object.ref.name : item.object.ref.name
        if name != item.object.ref.name {
            tip = "Rename staged (was \(item.object.ref.name))"
            if state == nil { state = .edited }
        }
        if item.showsSignature { name = item.object.displayName }
        if item.object.kind.isRoutine, !item.isStaged, tip == nil { tip = item.object.displayName }
        cell.show(name, symbol: symbol, tint: tint, accessibilityDescription: item.object.kind.rawValue,
                  font: Self.itemFont(outlineView.effectiveRowSizeStyle), state: state)
        cell.toolTip = tip
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? Item)?.object.ref.name
    }

    /// The source list's font for its row size (Settings ▸ Appearance ▸ Sidebar icon size).
    private static func itemFont(_ size: NSTableView.RowSizeStyle) -> NSFont {
        .systemFont(ofSize: size == .small ? 11 : size == .large ? 15 : 13)
    }

    /// Selecting an item opens it, so arrow keys browse tables one after another. Selecting
    /// several opens nothing.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !quiet.isActive, outline.selectedRowIndexes.count == 1,
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
