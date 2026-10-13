import AppCore
import AppKit

/// The grid's Columns button: a checkbox per column (shown or hidden) in display order. Rows
/// drag to reorder; Show All and Reset Order undo the choices. Each change applies at once.
@MainActor
final class ColumnsPopoverController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let columns: [String]
    private(set) var layout: ColumnLayout
    var onChange: ((ColumnLayout) -> Void)?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let note = NSTextField(labelWithString: "")
    private var shown: [Int] = []
    private static let dragType = NSPasteboard.PasteboardType("app.moonrow.column-row")

    init(columns: [String], layout: ColumnLayout) {
        self.columns = columns
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = "Search columns"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("column")))
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let showAll = NSButton(title: "Show All", target: self, action: #selector(showAll(_:)))
        let reset = NSButton(title: "Reset Order", target: self, action: #selector(resetOrder(_:)))
        for b in [showAll, reset] {
            b.controlSize = .small
            b.bezelStyle = .push
        }
        let buttons = NSStackView(views: [note, NSView(), showAll, reset])
        buttons.spacing = 6
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 340))
        for v in [search, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        reloadList()
    }

    private func reloadList() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = layout.arranged(columns).filter { q.isEmpty || columns[$0].localizedCaseInsensitiveContains(q) }
        table.reloadData()
        let hidden = layout.hidden.count
        note.stringValue = hidden == 0 ? "All \(columns.count) shown" : "\(hidden) hidden"
    }

    private func changed() {
        reloadList()
        onChange?(layout)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = columns[shown[row]]
        let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(toggled(_:)))
        box.state = layout.isHidden(name) ? .off : .on
        box.tag = shown[row]
        box.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            box.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggled(_ sender: NSButton) {
        let name = columns[sender.tag]
        if !layout.setHidden(sender.state == .off, name, columns: columns) {
            sender.state = .on
            NSSound.beep()
            note.stringValue = "One column always shows."
            return
        }
        changed()
    }

    /// For the dev harness: shows or hides a column as its checkbox would.
    func setHidden(_ hidden: Bool, _ name: String) -> Bool {
        guard layout.setHidden(hidden, name, columns: columns) else { return false }
        changed()
        return true
    }

    /// For the dev harness: moves a column as a drag would.
    func move(_ name: String, to position: Int) {
        guard let from = layout.arranged(columns).firstIndex(where: { columns[$0] == name }) else { return }
        layout.move(from: from, to: position, columns: columns)
        changed()
    }

    @objc private func showAll(_ sender: Any?) {
        layout = ColumnLayout(order: layout.order, hidden: [])
        changed()
    }

    @objc private func resetOrder(_ sender: Any?) {
        layout = ColumnLayout(order: [], hidden: layout.hidden)
        changed()
    }

    @objc private func searchChanged(_ sender: Any?) { reloadList() }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard search.stringValue.isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(s) else { return false }
        layout.move(from: from, to: from < row ? row - 1 : row, columns: columns)
        changed()
        return true
    }
}
