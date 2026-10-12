import AppCore
import AppKit
import DBKit

/// A table's columns and indexes, editable. Changes are staged in a `StructureEditor` and drawn
/// over the loaded structure (new rows green, deleted rows struck out, changed cells yellow).
/// The editor lives in the workspace's `StagedChanges`, so it outlives the tab; the workspace
/// commits (⌘S) or discards (⇧⌘⌫) it with everything else staged.
@MainActor
final class StructureViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuItemValidation, TabulaActions
{
    private enum ColumnField: String, CaseIterable {
        case key, name, type, nullable, defaultValue, extra, foreignKey, comment

        var title: String {
            switch self {
            case .key: "key"
            case .name: "column_name"
            case .type: "data_type"
            case .nullable: "is_nullable"
            case .defaultValue: "default"
            case .extra: "extra"
            case .foreignKey: "foreign_key"
            case .comment: "comment"
            }
        }

        var width: CGFloat {
            switch self {
            case .key, .nullable: 70
            case .name, .type, .defaultValue: 160
            case .extra: 150
            case .foreignKey: 200
            case .comment: 220
            }
        }

        var isText: Bool { [.name, .type, .defaultValue, .comment].contains(self) }
    }

    private enum IndexField: String, CaseIterable {
        case name, columns, unique, method, condition

        var title: String {
            switch self {
            case .name: "index_name"
            case .columns: "columns"
            case .unique: "is_unique"
            case .method: "method"
            case .condition: "condition"
            }
        }

        var width: CGFloat { self == .unique ? 70 : self == .columns ? 240 : 160 }
        var isText: Bool { self != .unique }
    }

    private(set) var table: TableRef
    let connection: any DatabaseConnection
    /// Asks before changes are applied.
    var safety: SafetyGate?
    /// Why the structure can't be changed (a view, a read-only connection), or nil.
    let readOnlyReason: String?
    /// When staged changes appear or go away.
    var onPendingChange: (() -> Void)?
    /// Tables the foreign-key editor offers.
    var knownTables: () -> [TableRef] = { [] }
    /// Shown first in the bottom bar (the Data / Structure switch).
    var leadingAccessory: NSView?

    private(set) var editor: StructureEditor?
    let kind: ObjectKind
    private let changes: StagedChanges
    /// Set for a table that exists only as staged so far.
    let newTableID: UUID?
    var creating: Bool { newTableID != nil }
    private var loadTask: Task<Void, Never>?
    let columnsGrid = DataGrid()
    let indexGrid = DataGrid()
    let nameField = NSTextField()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let changesButton = NSButton(title: "", target: nil, action: nil)
    private let addColumnButton = NSButton(title: "Column", target: nil, action: nil)
    private let addIndexButton = NSButton(title: "Index", target: nil, action: nil)
    private let definitionButton = NSButton(title: "DDL", target: nil, action: nil)
    private var popover: NSPopover?
    /// Rows of `editor.columns` the search leaves visible.
    private var visibleColumns: [Int] = []
    /// The inline edit in progress.
    private var editing: (grid: DataGrid, row: Int, field: String)?
    /// Original columns in the loaded primary key, for highlighting the key cell.
    private var loadedKey: Set<String> = []

    /// Opens an existing table's structure.
    init(connection: any DatabaseConnection, changes: StagedChanges, object: DatabaseObject, readOnlyConnection: Bool) {
        self.connection = connection
        self.changes = changes
        self.table = object.ref
        self.kind = object.kind
        self.newTableID = nil
        self.readOnlyReason = readOnlyConnection ? "The connection is read-only."
            : object.kind == .table ? nil : "Only a table's structure can be changed here."
        super.init(nibName: nil, bundle: nil)
        observeChanges()
    }

    /// A staged new table, created when the workspace commits.
    init(connection: any DatabaseConnection, changes: StagedChanges, newTable id: UUID, schema: String?) {
        self.connection = connection
        self.changes = changes
        self.newTableID = id
        self.editor = changes.newTable(id)
        self.table = TableRef(schema: schema, editor?.name ?? "")
        self.kind = .table
        self.readOnlyReason = nil
        super.init(nibName: nil, bundle: nil)
        observeChanges()
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)
    }

    /// The workspace discarded (or committed) what this editor staged: show the table as loaded
    /// until it reloads.
    @objc private func stagedChangesChanged() {
        guard isViewLoaded, editing == nil, let editor else { return }
        if let newTableID {
            guard let staged = changes.newTable(newTableID) else { return }
            self.editor = staged
            refresh()
        } else if editor.hasChanges, changes.structure(for: table) == nil {
            self.editor = StructureEditor(editor.original)
            refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEditable: Bool { readOnlyReason == nil }
    var hasPendingChanges: Bool { (editor?.hasChanges ?? false) || editing != nil }
    private var dialect: any Dialect { connection.dialect }
    private var hasComments: Bool { !(dialect is SQLiteDialect) }

    // MARK: - Layout

    override func loadView() {
        configure(columnsGrid, fields: ColumnField.allCases.filter { $0 != .comment || hasComments }.map { ($0.rawValue, $0.title, $0.width) })
        configure(indexGrid, fields: IndexField.allCases.filter { $0 != .condition || !(dialect is MySQLDialect) }.map { ($0.rawValue, $0.title, $0.width) })
        columnsGrid.menu = makeColumnMenu()
        indexGrid.menu = makeIndexMenu()

        nameField.placeholderString = "Table name"
        nameField.delegate = self
        nameField.isEditable = isEditable
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        searchField.placeholderString = "Search for column…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.textColor = .secondaryLabelColor
        let top = NSStackView(views: [nameLabel, nameField, NSView(), searchField])
        top.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let indexLabel = NSTextField(labelWithString: "Indexes")
        indexLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        indexLabel.textColor = .secondaryLabelColor
        let indexHeader = NSStackView(views: [indexLabel])
        indexHeader.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        let indexPane = NSStackView(views: [indexHeader, scroll(indexGrid)])
        indexPane.orientation = .vertical
        indexPane.spacing = 0
        for v in indexPane.arrangedSubviews { v.widthAnchor.constraint(equalTo: indexPane.widthAnchor).isActive = true }

        let columnsScroll = scroll(columnsGrid)
        // Columns take what's left; indexes about a third, never less than a few rows.
        let stack = NSStackView(views: [top, separator(), columnsScroll, separator(), indexPane, separator(), makeBottomBar()])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        columnsScroll.setContentHuggingPriority(.init(1), for: .vertical)
        let third = indexPane.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 0.32)
        third.priority = .defaultHigh
        NSLayoutConstraint.activate([third, indexPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 110)])
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    private func configure(_ grid: DataGrid, fields: [(id: String, title: String, width: CGFloat)]) {
        grid.style = .plain
        grid.rowSizeStyle = .custom
        grid.rowHeight = 22
        grid.intercellSpacing = NSSize(width: 1, height: 0)
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.usesAlternatingRowBackgroundColors = true
        grid.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        grid.allowsMultipleSelection = true
        grid.focusRingType = .none
        grid.dataSource = self
        grid.delegate = self
        grid.target = self
        grid.doubleAction = #selector(gridDoubleClicked(_:))
        grid.onEdit = { [weak self, weak grid] in
            guard let self, let grid, grid.selectedRow >= 0, let c = grid.focusedColumnIndex else { return NSSound.beep() }
            self.edit(grid, row: grid.selectedRow, field: grid.tableColumns[c].identifier.rawValue)
        }
        for f in fields {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(f.id))
            column.title = f.title
            column.width = f.width
            column.minWidth = 40
            grid.addTableColumn(column)
        }
    }

    private func scroll(_ grid: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = grid
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        return s
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeBottomBar() -> NSView {
        addColumnButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add column")
        addColumnButton.imagePosition = .imageLeading
        addColumnButton.target = self
        addColumnButton.action = #selector(addRow(_:))
        addColumnButton.toolTip = "Add a column (⌘I)"
        addIndexButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add index")
        addIndexButton.imagePosition = .imageLeading
        addIndexButton.target = self
        addIndexButton.action = #selector(addIndex(_:))
        addIndexButton.toolTip = "Add an index on the selected columns"
        definitionButton.target = self
        definitionButton.action = #selector(showDefinition(_:))
        definitionButton.toolTip = "Show the statements that create this table"
        definitionButton.isEnabled = !creating
        changesButton.target = self
        changesButton.action = #selector(showChanges(_:))
        changesButton.toolTip = "Review the SQL for every staged change (⇧⌘P)"
        changesButton.contentTintColor = .systemOrange
        changesButton.isHidden = true
        for b in [addColumnButton, addIndexButton, definitionButton, changesButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        addColumnButton.isEnabled = isEditable
        addIndexButton.isEnabled = isEditable
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [addColumnButton, addIndexButton, statusLabel, changesButton, definitionButton]
        if let leadingAccessory { views.insert(leadingAccessory, at: 0) }
        let bar = NSStackView(views: views)
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return bar
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if creating {
            refresh()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.nameField)
            }
        } else {
            reload()
        }
    }

    // MARK: - Loading

    func stop() {
        loadTask?.cancel()
    }

    /// Reads the structure again, unless changes to it are staged: those are kept.
    func reload() {
        if let newTableID {
            editor = changes.newTable(newTableID) ?? editor
            return refresh()
        }
        if let staged = changes.structure(for: table) {
            editor = staged
            loadedKey = Set(staged.original.primaryKey)
            return refresh()
        }
        stop()
        abortInlineEdit()
        showStatus("Loading…")
        let table = table
        loadTask = Task {
            do {
                let structure = try await connection.structure(of: table)
                guard !Task.isCancelled else { return }
                editor = StructureEditor(structure)
                loadedKey = Set(structure.primaryKey)
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                showStatus("\(error)", isError: true)
            }
        }
    }

    /// Redraws everything from `editor`.
    private func refresh() {
        guard let editor else { return }
        if nameField.currentEditor() == nil { nameField.stringValue = editor.name }
        let term = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visibleColumns = editor.columns.indices.filter {
            term.isEmpty || editor.columns[$0].value.name.lowercased().contains(term)
        }
        columnsGrid.reloadData()
        indexGrid.reloadData()
        updateBar()
    }

    private func updateBar() {
        guard let editor else { return }
        let live = editor.columns.filter { !$0.isDeleted }.count
        let indexes = editor.indexes.filter { !$0.isDeleted }.count
        if !statusIsError {
            var text = "\(live) \(live == 1 ? "column" : "columns"), \(indexes) \(indexes == 1 ? "index" : "indexes")"
            if let readOnlyReason { text += " · " + readOnlyReason }
            statusLabel.stringValue = text
        }
        let count = editor.exists ? changeCount(editor) : 1
        changesButton.isHidden = !editor.hasChanges
        changesButton.title = creating ? "New table" : "\(count) \(count == 1 ? "change" : "changes")"
        onPendingChange?()
    }

    private func changeCount(_ e: StructureEditor) -> Int {
        let c = e.change
        return c.droppedColumns.count + c.addedColumns.count + c.alteredColumns.count + (c.primaryKeyChanged ? 1 : 0)
            + Set(c.droppedIndexes.map(\.name) + c.createdIndexes.map(\.name)).count
            + c.droppedForeignKeys.count + c.addedForeignKeys.count + (c.renamedTable != nil ? 1 : 0) + (c.commentChanged ? 1 : 0)
    }

    private var statusIsError = false

    private func showStatus(_ text: String, isError: Bool = false) {
        statusIsError = isError
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Grid data

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let editor else { return 0 }
        return tableView === columnsGrid ? visibleColumns.count : editor.indexes.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: GridRowView.identifier, owner: self) as? GridRowView ?? GridRowView()
        guard let editor else { return view }
        let (isNew, isDeleted) = tableView === columnsGrid
            ? (editor.columns[visibleColumns[row]].isNew, editor.columns[visibleColumns[row]].isDeleted)
            : (editor.indexes[row].isNew, editor.indexes[row].isDeleted)
        view.state = isDeleted ? .deleted : isNew ? .inserted : .unchanged
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let editor else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: self) as? GridCell ?? GridCell()
        let id = tableColumn.identifier.rawValue
        let grid = tableView as! DataGrid
        let focused = grid.focusedColumn == tableColumn.identifier && grid.selectedRowIndexes.contains(row)
        if tableView === columnsGrid {
            let r = visibleColumns[row]
            let field = ColumnField(rawValue: id)!
            let (text, edited) = columnCell(editor, row: r, field: field)
            cell.show(text, edited: edited, focused: focused, struckOut: editor.columns[r].isDeleted)
        } else {
            let field = IndexField(rawValue: id)!
            let (text, edited) = indexCell(editor, row: row, field: field)
            cell.show(text, edited: edited, focused: focused, struckOut: editor.indexes[row].isDeleted)
        }
        return cell
    }

    private func columnCell(_ e: StructureEditor, row: Int, field: ColumnField) -> (CellContent, Bool) {
        let c = e.columns[row].value
        let changed = e.changedFields(ofColumn: row)
        switch field {
        case .key:
            let position = e.primaryKey.firstIndex(of: c.name)
            let text = position.map { e.primaryKey.count > 1 ? "PK \($0 + 1)" : "PK" } ?? ""
            let wasKey = e.columns[row].origin.map { loadedKey.contains(e.original.columns[$0].name) } ?? false
            return (.value(.text(text)), !e.columns[row].isNew && (position != nil) != wasKey || (position != nil && e.primaryKeyChanged))
        case .name: return (.value(.text(c.name)), changed.contains(.name))
        case .type: return (.value(.text(c.typeName)), changed.contains(.type))
        case .nullable: return (.value(.text(c.isNullable ? "YES" : "NO")), changed.contains(.nullable))
        case .defaultValue:
            return (c.defaultExpression.map { .value(.text($0)) } ?? .value(.text("")), changed.contains(.defaultValue))
        case .extra:
            var parts: [String] = []
            if let g = c.generated { parts.append(g) } else if c.isAutoIncrement { parts.append("auto_increment") }
            if let u = c.onUpdate { parts.append("on update \(u)") }
            return (.value(.text(parts.joined(separator: " "))), changed.contains(.autoIncrement))
        case .foreignKey:
            guard let k = e.foreignKey(forColumn: c.name) else { return (.value(.text("")), false) }
            let key = e.foreignKeys[k].value
            var text = "\(key.referencedTable.name)(\(key.referencedColumns.joined(separator: ", ")))"
            if key.onDelete != "NO ACTION" { text += " on delete \(key.onDelete.lowercased())" }
            return (.value(.text(text)), changed.contains(.foreignKey) || e.foreignKeys[k].isNew)
        case .comment: return (.value(.text(c.comment ?? "")), changed.contains(.comment))
        }
    }

    private func indexCell(_ e: StructureEditor, row: Int, field: IndexField) -> (CellContent, Bool) {
        let i = e.indexes[row].value
        let changed = e.changedFields(ofIndex: row)
        switch field {
        case .name: return (.value(.text(i.name.isEmpty ? "(automatic)" : i.name)), changed.contains(.name))
        case .columns: return (.value(.text(i.columns.joined(separator: ", "))), changed.contains(.columns))
        case .unique: return (.value(.text(i.isUnique ? "YES" : "NO")), changed.contains(.unique))
        case .method: return (.value(.text(i.method ?? "")), changed.contains(.method))
        case .condition: return (.value(.text(i.predicate ?? "")), changed.contains(.predicate))
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Redraw the cell cursor.
        (notification.object as? NSTableView)?.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<((notification.object as? NSTableView)?.numberOfRows ?? 0)),
            columnIndexes: IndexSet(integersIn: 0..<((notification.object as? NSTableView)?.numberOfColumns ?? 0)))
    }

    // MARK: - Editing

    @objc private func gridDoubleClicked(_ sender: Any?) {
        guard let grid = sender as? DataGrid else { return }
        let row = grid.clickedRow, column = grid.clickedColumn
        guard row >= 0, column >= 0 else { return }
        edit(grid, row: row, field: grid.tableColumns[column].identifier.rawValue)
    }

    /// Return or double-click on a cell: toggles yes/no cells, opens the foreign-key editor, or
    /// edits text inline.
    private func edit(_ grid: DataGrid, row: Int, field: String) {
        guard isEditable, let editor else { return NSSound.beep() }
        if grid === columnsGrid {
            let r = visibleColumns[row]
            guard !editor.columns[r].isDeleted, let f = ColumnField(rawValue: field) else { return NSSound.beep() }
            let column = editor.columns[r].value
            switch f {
            case .key: change { $0.togglePrimaryKey(r) }
            case .nullable:
                guard !editor.primaryKey.contains(column.name) else { return NSSound.beep() }
                change { $0.setColumn(r) { $0.isNullable.toggle() } }
            case .extra: toggleAutoIncrement(r)
            case .foreignKey: showForeignKeyEditor(forColumnRow: r, grid: grid, row: row)
            case .defaultValue where column.generated != nil: NSSound.beep()
            default: beginTextEdit(grid, row: row, field: field, text: text(of: column, f))
            }
        } else {
            guard !editor.indexes[row].isDeleted, let f = IndexField(rawValue: field) else { return NSSound.beep() }
            // Constraint indexes come and go with their constraint; they can only be deleted.
            guard !editor.indexes[row].value.isConstraint || editor.indexes[row].isNew else { return NSSound.beep() }
            if f == .unique {
                change { $0.setIndex(row) { $0.isUnique.toggle() } }
            } else {
                let i = editor.indexes[row].value
                let text = switch f {
                case .name: i.name
                case .columns: i.columns.joined(separator: ", ")
                case .method: i.method ?? ""
                case .condition: i.predicate ?? ""
                case .unique: ""
                }
                beginTextEdit(grid, row: row, field: field, text: text)
            }
        }
    }

    private func text(of c: ColumnInfo, _ f: ColumnField) -> String {
        switch f {
        case .name: c.name
        case .type: c.typeName
        case .defaultValue: c.defaultExpression ?? ""
        case .comment: c.comment ?? ""
        default: ""
        }
    }

    private func beginTextEdit(_ grid: DataGrid, row: Int, field: String, text: String) {
        let column = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(field))
        guard column >= 0 else { return }
        grid.scrollColumnToVisible(column)
        guard let cell = grid.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCell else { return }
        editing = (grid, row, field)
        cell.prepareForEditing(text, delegate: self)
        view.window?.makeFirstResponder(cell.label)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control !== nameField, control !== searchField else { return false }
        if selector == #selector(cancelOperation(_:)) {
            abortInlineEdit()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === nameField {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            if editor?.name != name { change { $0.name = name } }
            return
        }
        guard let editing, let field else { return }
        self.editing = nil
        apply(field.stringValue, grid: editing.grid, row: editing.row, field: editing.field)
        editing.grid.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<editing.grid.numberOfColumns))
        view.window?.makeFirstResponder(editing.grid)
    }

    private func apply(_ text: String, grid: DataGrid, row: Int, field: String) {
        guard let editor else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if grid === columnsGrid {
            let r = visibleColumns[row]
            switch ColumnField(rawValue: field) {
            case .name:
                guard !trimmed.isEmpty, trimmed != editor.columns[r].value.name else { return }
                change { $0.setColumn(r) { $0.name = trimmed } }
            case .type:
                guard !trimmed.isEmpty || dialect is SQLiteDialect, trimmed != editor.columns[r].value.typeName else { return }
                change { $0.setColumn(r) { $0.typeName = trimmed } }
            case .defaultValue:
                let sql = DefaultInput.sql(from: text, dialect: dialect)
                guard sql != editor.columns[r].value.defaultExpression else { return }
                change { $0.setColumn(r) { $0.defaultExpression = sql } }
            case .comment:
                let comment = trimmed.isEmpty ? nil : trimmed
                guard comment != editor.columns[r].value.comment else { return }
                change { $0.setColumn(r) { $0.comment = comment } }
            default: break
            }
        } else {
            switch IndexField(rawValue: field) {
            case .name: change { $0.setIndex(row) { $0.name = trimmed } }
            case .columns:
                let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard names != editor.indexes[row].value.columns else { return }
                change { $0.setIndex(row) { $0.columns = names } }
            case .method:
                guard trimmed != (editor.indexes[row].value.method ?? "") else { return }
                change { $0.setIndex(row) { $0.method = trimmed.isEmpty ? nil : trimmed } }
            case .condition:
                guard trimmed != (editor.indexes[row].value.predicate ?? "") else { return }
                change { $0.setIndex(row) { $0.predicate = trimmed.isEmpty ? nil : trimmed } }
            default: break
            }
        }
    }

    /// Ends the inline edit, keeping what was typed.
    func endInlineEdit() {
        guard let editing else { return }
        if let cell = editing.grid.view(
            atColumn: editing.grid.column(withIdentifier: NSUserInterfaceItemIdentifier(editing.field)),
            row: editing.row, makeIfNecessary: false) as? GridCell {
            view.window?.makeFirstResponder(editing.grid)
            if self.editing != nil {
                self.editing = nil
                apply(cell.label.stringValue, grid: editing.grid, row: editing.row, field: editing.field)
            }
        }
        self.editing = nil
        refresh()
    }

    private func abortInlineEdit() {
        guard let editing else { return }
        self.editing = nil
        view.window?.makeFirstResponder(editing.grid)
        editing.grid.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<editing.grid.numberOfColumns))
    }

    private func change(_ edit: (inout StructureEditor) -> Void) {
        guard editor != nil else { return }
        edit(&editor!)
        if let newTableID { changes.setNewTable(newTableID, editor!) } else { changes.setStructure(editor!) }
        refresh()
    }

    private func toggleAutoIncrement(_ row: Int) {
        guard let editor, editor.columns[row].value.generated == nil || editor.columns[row].value.isAutoIncrement else {
            return NSSound.beep()
        }
        change { e in
            e.setColumn(row) { c in
                c.isAutoIncrement.toggle()
                if c.isAutoIncrement { c.defaultExpression = nil }
                // An identity column isn't a generated expression any more once it's off.
                if !c.isAutoIncrement, c.generated?.contains("IDENTITY") == true { c.generated = nil }
            }
        }
    }

    private func showForeignKeyEditor(forColumnRow r: Int, grid: DataGrid, row: Int) {
        guard let editor else { return }
        let column = editor.columns[r].value.name
        let existing = editor.foreignKey(forColumn: column)
        let key = existing.map { editor.foreignKeys[$0].value }
            ?? ForeignKeyInfo(name: "", columns: [column], referencedTable: TableRef(schema: table.schema, ""), referencedColumns: [])
        let connection = connection
        let controller = ForeignKeyEditorController(key: key, isNew: existing == nil, tables: knownTables()) { table in
            (try? await connection.columns(of: table).primaryKey) ?? []
        }
        controller.onSave = { [weak self] k in
            self?.popover?.close()
            self?.change { $0.setForeignKey(existing, k) }
        }
        controller.onDelete = { [weak self] in
            self?.popover?.close()
            if let existing { self?.change { $0.deleteForeignKeys([existing]) } }
        }
        controller.onCancel = { [weak self] in self?.popover?.close() }
        let c = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(ColumnField.foreignKey.rawValue))
        present(controller, from: grid, at: grid.frameOfCell(atColumn: max(c, 0), row: row))
    }

    private func present(_ controller: NSViewController, from anchor: NSView, at rect: NSRect? = nil, size: NSSize? = nil) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = controller
        if let size { p.contentSize = size }
        p.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = p
    }

    // MARK: - Search

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { refresh() }
    }

    // MARK: - Actions

    /// Which grid the row commands apply to: the one with the focus, else the columns.
    private var activeGrid: DataGrid {
        view.window?.firstResponder === indexGrid ? indexGrid : columnsGrid
    }

    @objc func addRow(_ sender: Any?) {
        guard isEditable, editor != nil else { return NSSound.beep() }
        endInlineEdit()
        searchField.stringValue = ""
        let after = columnsGrid.selectedRowIndexes.last.map { visibleColumns[$0] }
        var row = 0
        let type = StructureEditor.newColumnType(dialect)
        change { row = $0.addColumn(type: type, after: after) }
        columnsGrid.selectRowIndexes([row], byExtendingSelection: false)
        columnsGrid.scrollRowToVisible(row)
        beginTextEdit(columnsGrid, row: row, field: ColumnField.name.rawValue, text: editor!.columns[row].value.name)
    }

    /// Adds an index on the selected columns (or an empty one to fill in).
    @objc func addIndex(_ sender: Any?) {
        guard isEditable, let editor else { return NSSound.beep() }
        endInlineEdit()
        let names = columnsGrid.selectedRowIndexes.map { visibleColumns[$0] }
            .filter { !editor.columns[$0].isDeleted }.map { editor.columns[$0].value.name }
        var row = 0
        change { row = $0.addIndex(columns: names) }
        indexGrid.selectRowIndexes([row], byExtendingSelection: false)
        indexGrid.scrollRowToVisible(row)
        view.window?.makeFirstResponder(indexGrid)
        if names.isEmpty { beginTextEdit(indexGrid, row: row, field: IndexField.columns.rawValue, text: "") }
    }

    @objc func duplicateRows(_ sender: Any?) {
        guard isEditable, editor != nil, activeGrid === columnsGrid, let last = columnsGrid.selectedRowIndexes.last else {
            return NSSound.beep()
        }
        searchField.stringValue = ""
        var row = 0
        change { row = $0.duplicateColumn(visibleColumns[last]) }
        columnsGrid.selectRowIndexes([row], byExtendingSelection: false)
    }

    @objc func deleteRows(_ sender: Any?) {
        guard isEditable, editor != nil else { return NSSound.beep() }
        let grid = (sender as? NSMenuItem)?.menu === indexGrid.menu ? indexGrid : activeGrid
        let rows = grid.selectedRowIndexes
        guard !rows.isEmpty else { return NSSound.beep() }
        endInlineEdit()
        if grid === columnsGrid {
            change { $0.deleteColumns(IndexSet(rows.map { visibleColumns[$0] })) }
        } else {
            change { $0.deleteIndexes(rows) }
        }
        grid.deselectAll(nil)
    }

    @objc private func restoreRows(_ sender: Any?) {
        guard let menu = (sender as? NSMenuItem)?.menu else { return }
        if menu === indexGrid.menu {
            for row in indexGrid.selectedRowIndexes { change { $0.restoreIndex(row) } }
        } else {
            for row in columnsGrid.selectedRowIndexes { change { $0.restoreColumn(visibleColumns[row]) } }
        }
    }

    @objc private func togglePrimaryKey(_ sender: Any?) {
        guard isEditable, let row = columnsGrid.selectedRowIndexes.first else { return NSSound.beep() }
        change { $0.togglePrimaryKey(visibleColumns[row]) }
    }

    @objc private func toggleAutoIncrementMenu(_ sender: Any?) {
        guard isEditable, let row = columnsGrid.selectedRowIndexes.first else { return NSSound.beep() }
        toggleAutoIncrement(visibleColumns[row])
    }

    @objc private func setType(_ sender: NSMenuItem) {
        guard isEditable else { return }
        let type = sender.title
        for row in columnsGrid.selectedRowIndexes where !(editor?.columns[visibleColumns[row]].isDeleted ?? true) {
            change { $0.setColumn(visibleColumns[row]) { $0.typeName = type } }
        }
    }

    @objc private func editForeignKey(_ sender: Any?) {
        guard isEditable, let row = columnsGrid.selectedRowIndexes.first else { return NSSound.beep() }
        showForeignKeyEditor(forColumnRow: visibleColumns[row], grid: columnsGrid, row: row)
    }

    /// ⌥⌘R: reads the structure again; staged changes to it stay.
    @objc func reloadCurrentTab(_ sender: Any?) {
        endInlineEdit()
        reload()
    }

    private func makeColumnMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Column", action: #selector(addRow(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateRows(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Primary Key", action: #selector(togglePrimaryKey(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Auto Increment", action: #selector(toggleAutoIncrementMenu(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Foreign Key…", action: #selector(editForeignKey(_:)), keyEquivalent: "").target = self
        let types = NSMenuItem(title: "Type", action: nil, keyEquivalent: "")
        types.submenu = NSMenu()
        for t in dialect.commonTypes { types.submenu!.addItem(withTitle: t, action: #selector(setType(_:)), keyEquivalent: "").target = self }
        menu.addItem(types)
        menu.addItem(withTitle: "New Index on Selected Columns", action: #selector(addIndex(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteRows(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restore", action: #selector(restoreRows(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func makeIndexMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Index", action: #selector(addIndex(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteRows(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restore", action: #selector(restoreRows(_:)), keyEquivalent: "").target = self
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor else { return false }
        switch item.action {
        case #selector(restoreRows(_:)):
            if item.menu === indexGrid.menu { return indexGrid.selectedRowIndexes.contains { editor.indexes[$0].isDeleted } }
            return columnsGrid.selectedRowIndexes.contains { editor.columns[visibleColumns[$0]].isDeleted }
        case #selector(togglePrimaryKey(_:)):
            let row = columnsGrid.selectedRowIndexes.first.map { visibleColumns[$0] }
            item.state = row.map { editor.primaryKey.contains(editor.columns[$0].value.name) } == true ? .on : .off
            return isEditable && row != nil
        case #selector(toggleAutoIncrementMenu(_:)):
            let row = columnsGrid.selectedRowIndexes.first.map { visibleColumns[$0] }
            item.state = row.map { editor.columns[$0].value.isAutoIncrement } == true ? .on : .off
            return isEditable && row != nil
        case #selector(addRow(_:)), #selector(addIndex(_:)):
            return isEditable
        case #selector(deleteRows(_:)), #selector(duplicateRows(_:)), #selector(setType(_:)), #selector(editForeignKey(_:)):
            let grid = item.menu === indexGrid.menu ? indexGrid : item.menu === columnsGrid.menu ? columnsGrid : activeGrid
            return isEditable && !grid.selectedRowIndexes.isEmpty
        default:
            return true
        }
    }

    // MARK: - Staged changes

    /// The bottom bar's change count: shows the workspace's preview.
    @objc private func showChanges(_ sender: Any?) {
        endInlineEdit()
        NSApp.sendAction(#selector(TabulaActions.previewChanges(_:)), to: nil, from: self)
    }

    @objc private func showDefinition(_ sender: Any?) {
        let object = DatabaseObject(table, kind: kind)
        let connection = connection
        Task {
            do {
                let text = try await connection.definition(of: object)
                let detail = editor.map { "\($0.original.columns.count) columns, \($0.original.indexes.count) indexes" } ?? ""
                present(DefinitionViewController(text: text, detail: detail), from: definitionButton, size: NSSize(width: 680, height: 420))
            } catch {
                showStatus("\(error)", isError: true)
            }
        }
    }
}
