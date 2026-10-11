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

    var onOpen: ((DatabaseObject) -> Void)?
    var onOpenInNewTab: ((DatabaseObject) -> Void)?
    var onOpenStructure: ((DatabaseObject) -> Void)?
    var onNewTable: (() -> Void)?
    var onRename: ((DatabaseObject) -> Void)?
    var onTruncate: ((DatabaseObject) -> Void)?
    var onDelete: ((DatabaseObject) -> Void)?
    var onCopyScript: ((DatabaseObject, Script) -> Void)?
    var onExport: ((DatabaseObject) -> Void)?
    /// Nil on read-only connections.
    var onImportCSV: ((DatabaseObject) -> Void)?
    /// After the object list (re)loads.
    var onObjectsLoaded: (([DatabaseObject]) -> Void)?
    /// Set while the selection follows the open tab, so it doesn't open anything.
    private var isRevealing = false

    private let connection: any DatabaseConnection
    private let outline = NSOutlineView()
    private let filter = NSSearchField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let schemaPopup = NSPopUpButton()
    private let schemaBar = NSStackView()
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
        init(_ object: DatabaseObject) { self.object = object }
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
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Structure", action: #selector(openStructure(_:)), keyEquivalent: "").target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Table…", action: #selector(newTable(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rename…", action: #selector(renameItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Truncate…", action: #selector(truncateItem(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete…", action: #selector(deleteItem(_:)), keyEquivalent: "").target = self
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
        schemaBar.addArrangedSubview(schemaPopup)
        schemaBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        schemaBar.isHidden = true
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
        isRevealing = true
        defer { isRevealing = false }
        let row = ref.flatMap { r in rowOf { $0.ref == r } }
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
    }

    /// The item a context-menu command applies to: the clicked row, else the selection.
    private var targetObject: DatabaseObject? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? Item)?.object
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0, let object = (outline.item(atRow: outline.clickedRow) as? Item)?.object,
              Self.opensInGrid(object) else { return }
        onOpen?(object)
    }

    /// Tables and views open in a grid; functions are listed only (their editor comes later).
    static func opensInGrid(_ object: DatabaseObject) -> Bool {
        [.table, .view, .materializedView].contains(object.kind)
    }

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
        if let object = targetObject, Self.opensInGrid(object) { onOpenInNewTab?(object) }
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
        case #selector(renameItem(_:)), #selector(deleteItem(_:)):
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
        if let object = targetObject { onRename?(object) }
    }

    @objc private func truncateItem(_ sender: Any?) {
        if let object = targetObject { onTruncate?(object) }
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
                }
                // MySQL without a default database: nothing to list until one is chosen.
                if schema == nil, !schemaBar.isHidden {
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
        schemaBar.isHidden = schemas.isEmpty
        schemaPopup.removeAllItems()
        schemaPopup.addItems(withTitles: schemas)
        // The current schema can be one the list leaves out (a system one).
        if let current, !schemas.contains(current) { schemaPopup.addItem(withTitle: current) }
        if let current { schemaPopup.selectItem(withTitle: current) } else { schemaPopup.select(nil) }
    }

    private func rebuild() {
        let selected = (outline.item(atRow: outline.selectedRow) as? Item)?.object
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? objects : objects.filter { $0.ref.name.localizedCaseInsensitiveContains(query) }

        let sections: [(ObjectKind, String)] = [
            (.table, "Tables"), (.view, "Views"), (.materializedView, "Materialized Views"), (.function, "Functions"),
        ]
        groups = sections.compactMap { kind, title in
            let items = matching.filter { $0.kind == kind }.map(Item.init)
            return items.isEmpty ? nil : Group(title: title, items: items)
        }
        outline.reloadData()
        for g in groups { outline.expandItem(g) }

        if let selected, let row = rowOf({ $0 == selected }) {
            isRevealing = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            isRevealing = false
        }
        if objects.isEmpty {
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

    private func rowOf(_ predicate: (DatabaseObject) -> Bool) -> Int? {
        for g in groups {
            if let item = g.items.first(where: { predicate($0.object) }) {
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
        cell.textField?.stringValue = item.object.ref.name
        let (symbol, tint): (String, NSColor) = switch item.object.kind {
        case .table: ("tablecells", .systemBlue)
        case .function, .sequence: ("function", .systemOrange)
        default: ("eye", .systemPurple)
        }
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.object.kind.rawValue)
        cell.imageView?.contentTintColor = tint
        return cell
    }

    /// Selecting an item opens it, so arrow keys browse tables one after another.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, let item = outline.item(atRow: outline.selectedRow) as? Item,
              Self.opensInGrid(item.object) else { return }
        onOpen?(item.object)
    }
}
