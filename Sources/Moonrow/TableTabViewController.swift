import AppCore
import AppKit
import DBKit

/// A table tab: the rows (Data) or the columns and indexes (Structure), switched with the
/// control at the bottom left or ⌃⌘[ / ⌃⌘]; views and materialized views add their SQL
/// (Definition). Every side stages into the workspace's `StagedChanges`, so switching, closing
/// the tab or opening another table never asks.
@MainActor
final class TableTabViewController: NSViewController, ObjectTab, NSMenuItemValidation {
    enum Mode { case data, structure, definition }

    private(set) var table: TableRef
    private(set) var kind: ObjectKind
    private let connection: any DatabaseConnection
    private let changes: StagedChanges
    private let readOnlyConnection: Bool
    private let pageSize: Int?
    let tabID = UUID()
    var onTabItemChange: (() -> Void)?
    /// A preview tab (italic title) becomes a regular one once it's used: paging, sorting,
    /// filtering, switching to Structure, or staging a change on its table.
    var isPreview = false {
        didSet { if isPreview != oldValue { onTabItemChange?() } }
    }
    /// What was staged for the table when last checked; a new mark keeps a preview tab.
    private var lastMark: StagedChanges.Mark?
    /// Tables the foreign-key editor offers.
    var knownTables: () -> [TableRef] = { [] }
    /// Names of the schema's tables and views, for checking a new name.
    var existingNames: () -> [String] = { [] }
    /// Asks before commits are sent.
    var safety: SafetyGate?
    /// The connection's column layouts (the grid's Columns button).
    var columnLayouts: ColumnLayouts?

    private(set) var data: TableDataViewController?
    private(set) var structure: StructureViewController?
    /// Views and materialized views: their CREATE statement.
    private(set) var definition: DefinitionEditorController?
    private var hasDefinition: Bool { kind == .view || kind == .materializedView }
    private(set) var mode: Mode = .data
    /// Set while the tab shows a staged new table.
    private(set) var newTableID: UUID?
    private var isNewTable: Bool { newTableID != nil }

    init(connection: any DatabaseConnection, changes: StagedChanges, object: DatabaseObject, readOnlyConnection: Bool,
         pageSize: Int?, mode: Mode = .data) {
        self.connection = connection
        self.changes = changes
        self.table = object.ref
        self.kind = object.kind
        self.readOnlyConnection = readOnlyConnection
        self.pageSize = pageSize
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        lastMark = changes.mark(for: table)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)
    }

    @objc private func stagedChangesChanged() {
        guard newTableID == nil else { return }
        let mark = changes.mark(for: table)
        if mark != nil, mark != lastMark { isPreview = false }
        lastMark = mark
    }

    /// A tab for a staged new table; it becomes a regular table tab once committed.
    init(connection: any DatabaseConnection, changes: StagedChanges, newTable id: UUID, schema: String?, pageSize: Int?) {
        self.connection = connection
        self.changes = changes
        self.table = TableRef(schema: schema, changes.newTable(id)?.name ?? "")
        self.kind = .table
        self.readOnlyConnection = false
        self.pageSize = pageSize
        self.mode = .structure
        self.newTableID = id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        show(mode)
    }

    /// The table or view the tab shows; nil for a staged new table.
    var object: DatabaseObject? { newTableID == nil ? DatabaseObject(table, kind: kind) : nil }

    /// The controller whose view is showing; menu commands go to it.
    var active: NSViewController? {
        switch mode {
        case .data: data
        case .structure: structure
        case .definition: definition
        }
    }

    // MARK: - Switching

    private static let modes: [Mode] = [.data, .structure, .definition]

    private func makeSwitch() -> NSSegmentedControl {
        let labels = hasDefinition ? ["Data", "Structure", "Definition"] : ["Data", "Structure"]
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(switchClicked(_:)))
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.setToolTip("Rows (⌃⌘[)", forSegment: 0)
        control.setToolTip("Columns and indexes (⌃⌘])", forSegment: 1)
        if hasDefinition { control.setToolTip("The view's SQL, editable", forSegment: 2) }
        control.setEnabled(!isNewTable, forSegment: 0)
        control.selectedSegment = Self.modes.firstIndex(of: mode) ?? 0
        return control
    }

    @objc private func switchClicked(_ sender: NSSegmentedControl) {
        let wanted = Self.modes[min(sender.selectedSegment, Self.modes.count - 1)]
        sender.selectedSegment = Self.modes.firstIndex(of: mode) ?? 0  // until the switch is allowed
        switchTo(wanted)
    }

    @objc func showTableData(_ sender: Any?) { switchTo(.data) }
    @objc func showTableStructure(_ sender: Any?) { switchTo(.structure) }
    @objc func showTableDefinition(_ sender: Any?) { switchTo(.definition) }

    /// `focus` moves the keyboard focus into the side shown.
    func switchTo(_ wanted: Mode, focus: Bool = true) {
        guard wanted != mode, !(wanted == .data && isNewTable), wanted != .definition || hasDefinition else { return }
        endEditing()
        isPreview = false
        show(wanted, focus: focus)
    }

    private func show(_ wanted: Mode, focus: Bool = true) {
        active?.view.removeFromSuperview()
        mode = wanted
        let controller: NSViewController
        switch wanted {
        case .data:
            if data == nil {
                let d = TableDataViewController(
                    connection: connection, changes: changes, object: DatabaseObject(table, kind: kind),
                    readOnlyConnection: readOnlyConnection, pageSize: pageSize)
                d.leadingAccessory = makeSwitch()
                d.safety = safety
                d.columnLayouts = columnLayouts
                d.onTabItemChange = { [weak self] in self?.onTabItemChange?() }
                d.onUse = { [weak self] in self?.isPreview = false }
                addChild(d)
                data = d
            }
            controller = data!
        case .structure:
            if structure == nil {
                let s = newTableID.map {
                    StructureViewController(connection: connection, changes: changes, newTable: $0, schema: table.schema)
                } ?? StructureViewController(
                    connection: connection, changes: changes, object: DatabaseObject(table, kind: kind),
                    readOnlyConnection: readOnlyConnection)
                s.leadingAccessory = makeSwitch()
                s.safety = safety
                s.knownTables = { [weak self] in self?.knownTables() ?? [] }
                s.existingNames = { [weak self] in self?.existingNames() ?? [] }
                s.onPendingChange = { [weak self] in self?.onTabItemChange?() }
                s.onUse = { [weak self] in self?.isPreview = false }
                addChild(s)
                structure = s
            }
            controller = structure!
        case .definition:
            if definition == nil {
                let defined = DefinedObject(DatabaseObject(table, kind: kind))!
                let d = DefinitionEditorController(
                    target: .existing(defined), kind: defined.kind, connection: connection, changes: changes,
                    readOnlyReason: readOnlyConnection ? "The connection is read-only." : nil,
                    place: EditPlace(side: .definition, objects: [DatabaseObject(table, kind: kind)]))
                d.leadingAccessory = makeSwitch()
                d.onUse = { [weak self] in self?.isPreview = false }
                addChild(d)
                definition = d
            }
            controller = definition!
        }
        for case let control as NSSegmentedControl in [data?.leadingAccessory, structure?.leadingAccessory, definition?.leadingAccessory] {
            control.selectedSegment = Self.modes.firstIndex(of: wanted) ?? 0
        }
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.pin(to: view)
        if focus { view.window?.makeFirstResponder(preferredResponder) }
        onTabItemChange?()
    }

    // MARK: - After a commit

    /// The table now exists under `newTable` (it was created or renamed): both sides are built
    /// again for it, keeping the side that shows.
    func becomeTable(_ newTable: TableRef) {
        table = newTable
        newTableID = nil
        for child in [data, structure, definition] as [NSViewController?] {
            (child as? TableDataViewController)?.stop()
            (child as? StructureViewController)?.stop()
            (child as? DefinitionEditorController)?.stop()
            child?.view.removeFromSuperview()
            child?.removeFromParent()
        }
        data = nil
        structure = nil
        definition = nil
        if isViewLoaded { show(mode) }
        onTabItemChange?()
    }

    /// Ends inline edits so what's typed is staged. Before a commit or preview.
    func endEditing() {
        data?.endInlineEdit()
        structure?.endInlineEdit()
        definition?.stageNow()
    }

    /// Reads rows and structure again. Staged changes stay.
    func reload() {
        data?.reload()
        structure?.reload()
        definition?.reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showTableData(_:)):
            item.state = mode == .data ? .on : .off
            return !isNewTable
        case #selector(showTableStructure(_:)):
            item.state = mode == .structure ? .on : .off
            return true
        case #selector(showTableDefinition(_:)):
            item.state = mode == .definition ? .on : .off
            return hasDefinition
        default:
            return true
        }
    }

    // MARK: - WorkspaceTab

    var tabItem: TabStrip.Item {
        let symbol = isNewTable ? "plus.rectangle" : kind == .table ? "tablecells" : DefinitionKind(kind)?.symbol ?? "eye"
        let staged = newTableID.flatMap { changes.newTable($0)?.name }
        let title = isNewTable ? staged.map { $0.isEmpty ? "New table" : $0 } ?? "New table" : table.name
        let tip = isPreview ? "\(table) — preview tab; double-click to keep it" : table.description
        return TabStrip.Item(title: title, symbol: symbol, toolTip: tip, italic: isPreview)
    }

    var preferredResponder: NSView {
        switch mode {
        case .data: data?.grid ?? view
        case .structure: structure?.columnsGrid ?? view
        case .definition: definition?.editor ?? view
        }
    }

    /// Staged changes stay with the workspace, so a table tab always closes at once.
    func prepareToClose(then proceed: @escaping () -> Void) {
        endEditing()
        proceed()
    }

    func tabDidClose() {
        data?.stop()
        structure?.stop()
        definition?.stop()
    }
}
