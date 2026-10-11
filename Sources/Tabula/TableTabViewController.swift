import AppCore
import AppKit
import DBKit

/// A table tab: the rows (Data) or the columns and indexes (Structure), switched with the
/// control at the bottom left or ⌃⌘[ / ⌃⌘]. Each side asks about its own staged changes before
/// the other is shown, so only one of them ever has any.
@MainActor
final class TableTabViewController: NSViewController, WorkspaceTab, NSMenuItemValidation {
    enum Mode { case data, structure }

    private(set) var table: TableRef
    private(set) var kind: ObjectKind
    private let connection: any DatabaseConnection
    private let readOnlyConnection: Bool
    private let pageSize: Int?
    var onTabItemChange: (() -> Void)?
    /// After a structure commit: the table as it is named now, and whether it was just created.
    var onStructureCommitted: ((_ tab: TableTabViewController, _ created: Bool) -> Void)?
    /// Tables the foreign-key editor offers.
    var knownTables: () -> [TableRef] = { [] }

    private(set) var data: TableDataViewController?
    private(set) var structure: StructureViewController?
    private(set) var mode: Mode = .data
    /// A table that exists only in the structure editor so far.
    private var isNewTable = false

    init(connection: any DatabaseConnection, object: DatabaseObject, readOnlyConnection: Bool, pageSize: Int?, mode: Mode = .data) {
        self.connection = connection
        self.table = object.ref
        self.kind = object.kind
        self.readOnlyConnection = readOnlyConnection
        self.pageSize = pageSize
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    /// A tab for designing a new table; it becomes a regular table tab once created.
    init(connection: any DatabaseConnection, newTable: TableRef, pageSize: Int?) {
        self.connection = connection
        self.table = newTable
        self.kind = .table
        self.readOnlyConnection = false
        self.pageSize = pageSize
        self.mode = .structure
        self.isNewTable = true
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        show(mode)
    }

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
        let leave: (String, @escaping () -> Void) -> Void = mode == .data
            ? { [weak self] action, go in self?.data?.resolvePendingEdits(before: action, then: go) ?? go() }
            : { [weak self] action, go in self?.structure?.resolvePendingChanges(before: action, then: go) ?? go() }
        leave(wanted == .data ? "Showing the rows" : "Showing the structure") { [weak self] in
            self?.show(wanted)
        }
    }

    private func show(_ wanted: Mode) {
        active?.view.removeFromSuperview()
        mode = wanted
        let controller: NSViewController
        switch wanted {
        case .data:
            if data == nil {
                let d = TableDataViewController(
                    connection: connection, object: DatabaseObject(table, kind: kind),
                    readOnlyConnection: readOnlyConnection, pageSize: pageSize)
                d.leadingAccessory = makeSwitch()
                d.onTabItemChange = { [weak self] in self?.onTabItemChange?() }
                addChild(d)
                data = d
            }
            controller = data!
        case .structure:
            if structure == nil {
                let s = isNewTable
                    ? StructureViewController(connection: connection, newTable: table)
                    : StructureViewController(connection: connection, object: DatabaseObject(table, kind: kind), readOnlyConnection: readOnlyConnection)
                s.leadingAccessory = makeSwitch()
                s.knownTables = { [weak self] in self?.knownTables() ?? [] }
                s.onPendingChange = { [weak self] in self?.onTabItemChange?() }
                s.onCommitted = { [weak self] table, created in self?.structureCommitted(table, created: created) }
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

    /// The rows are read again under the table's current name the next time Data is shown.
    private func structureCommitted(_ newTable: TableRef, created: Bool) {
        table = newTable
        if created {
            isNewTable = false
            for case let control as NSSegmentedControl in [structure?.leadingAccessory] { control.setEnabled(true, forSegment: 0) }
        }
        if let data {
            data.stop()
            data.view.removeFromSuperview()
            data.removeFromParent()
            self.data = nil
        }
        onTabItemChange?()
        onStructureCommitted?(self, created)
    }

    // MARK: - Pending changes

    var hasPendingEdits: Bool { (data?.hasPendingEdits ?? false) || (structure?.hasPendingChanges ?? false) }

    func resolvePendingEdits(before action: String, then proceed: @escaping () -> Void) {
        let resolveData: () -> Void = { [weak self] in
            guard let data = self?.data else { return proceed() }
            data.resolvePendingEdits(before: action, then: proceed)
        }
        guard let structure else { return resolveData() }
        structure.resolvePendingChanges(before: action, then: resolveData)
    }

    /// Reads rows and structure again. Callers resolve staged changes first.
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
        let title = isNewTable ? (structure?.editor?.name).map { $0.isEmpty ? "New table" : $0 } ?? "New table" : table.name
        return TabStrip.Item(title: title, symbol: symbol, toolTip: table.description)
    }

    var preferredResponder: NSView {
        switch mode {
        case .data: data?.grid ?? view
        case .structure: structure?.columnsGrid ?? view
        }
    }

    func prepareToClose(then proceed: @escaping () -> Void) {
        resolvePendingEdits(before: "Closing the tab", then: proceed)
    }

    func tabDidClose() {
        data?.stop()
        structure?.stop()
    }
}
