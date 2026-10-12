import AppCore
import AppKit
import DBKit

/// A table tab: the rows (Data) or the columns and indexes (Structure), switched with the
/// control at the bottom left or ⌃⌘[ / ⌃⌘]. Both sides stage into the workspace's
/// `StagedChanges`, so switching, closing the tab or opening another table never asks.
@MainActor
final class TableTabViewController: NSViewController, WorkspaceTab, NSMenuItemValidation {
    enum Mode { case data, structure }

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
    var active: NSViewController? { mode == .data ? data : structure }

    // MARK: - Switching

    private func makeSwitch() -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Data", "Structure"], trackingMode: .selectOne, target: self, action: #selector(switchClicked(_:)))
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.setToolTip("Rows (⌃⌘[)", forSegment: 0)
        control.setToolTip("Columns and indexes (⌃⌘])", forSegment: 1)
        control.setEnabled(!isNewTable, forSegment: 0)
        control.selectedSegment = mode == .data ? 0 : 1
        return control
    }

    @objc private func switchClicked(_ sender: NSSegmentedControl) {
        let wanted: Mode = sender.selectedSegment == 0 ? .data : .structure
        sender.selectedSegment = mode == .data ? 0 : 1  // until the switch is allowed
        switchTo(wanted)
    }

    @objc func showTableData(_ sender: Any?) { switchTo(.data) }
    @objc func showTableStructure(_ sender: Any?) { switchTo(.structure) }

    func switchTo(_ wanted: Mode) {
        guard wanted != mode, !(wanted == .data && isNewTable) else { return }
        data?.endInlineEdit()
        structure?.endInlineEdit()
        isPreview = false
        show(wanted)
    }

    private func show(_ wanted: Mode) {
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
        }
        for case let control as NSSegmentedControl in [data?.leadingAccessory, structure?.leadingAccessory] {
            control.selectedSegment = wanted == .data ? 0 : 1
        }
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.pin(to: view)
        view.window?.makeFirstResponder(preferredResponder)
        onTabItemChange?()
    }

    // MARK: - After a commit

    /// The table now exists under `newTable` (it was created or renamed): both sides are built
    /// again for it, keeping the side that shows.
    func becomeTable(_ newTable: TableRef) {
        table = newTable
        newTableID = nil
        for child in [data, structure] as [NSViewController?] {
            (child as? TableDataViewController)?.stop()
            (child as? StructureViewController)?.stop()
            child?.view.removeFromSuperview()
            child?.removeFromParent()
        }
        data = nil
        structure = nil
        if isViewLoaded { show(mode) }
        onTabItemChange?()
    }

    /// Ends inline edits so what's typed is staged. Before a commit or preview.
    func endEditing() {
        data?.endInlineEdit()
        structure?.endInlineEdit()
    }

    /// Reads rows and structure again. Staged changes stay.
    func reload() {
        data?.reload()
        structure?.reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showTableData(_:)):
            item.state = mode == .data ? .on : .off
            return !isNewTable
        case #selector(showTableStructure(_:)):
            item.state = mode == .structure ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - WorkspaceTab

    var tabItem: TabStrip.Item {
        let symbol = isNewTable ? "plus.rectangle" : kind == .table ? "tablecells" : "eye"
        let staged = newTableID.flatMap { changes.newTable($0)?.name }
        let title = isNewTable ? staged.map { $0.isEmpty ? "New table" : $0 } ?? "New table" : table.name
        let tip = isPreview ? "\(table) — preview tab; double-click to keep it" : table.description
        return TabStrip.Item(title: title, symbol: symbol, toolTip: tip, italic: isPreview)
    }

    var preferredResponder: NSView {
        switch mode {
        case .data: data?.grid ?? view
        case .structure: structure?.columnsGrid ?? view
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
    }
}
