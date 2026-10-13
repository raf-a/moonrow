import AppCore
import AppKit
import DBKit

/// A table's triggers (the Structure view's Triggers button): the list on the left, the selected
/// trigger's CREATE statement on the right. Edits, new triggers and deletions are staged with
/// the workspace's other changes; ⌘S commits them.
@MainActor
final class TriggersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        var name: String
        var detail: String
        /// Nil for a staged new trigger.
        var object: DefinedObject?
        var newID: UUID?
    }

    let table: TableRef
    private let connection: any DatabaseConnection
    private let changes: StagedChanges
    let readOnlyReason: String?
    private var loaded: [TriggerInfo] = []
    private var rows: [Row] = []
    let list = NSTableView()
    private let editorBox = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No trigger selected")
    private let addButton = NSButton(title: "Trigger", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private(set) var editor: DefinitionEditorController?
    private let split = NSSplitView()
    private var placedDivider = false
    private var loadTask: Task<Void, Never>?

    init(table: TableRef, connection: any DatabaseConnection, changes: StagedChanges, readOnlyReason: String?) {
        self.table = table
        self.connection = connection
        self.changes = changes
        self.readOnlyReason = readOnlyReason
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("trigger"))
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .plain
        list.rowHeight = 34
        list.dataSource = self
        list.delegate = self
        list.target = self
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true

        emptyLabel.textColor = .secondaryLabelColor
        for b in [addButton, deleteButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
        }
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New trigger")
        addButton.imagePosition = .imageLeading
        addButton.action = #selector(addTrigger(_:))
        addButton.toolTip = "A new trigger on \(table.name)"
        deleteButton.action = #selector(deleteTrigger(_:))
        deleteButton.toolTip = "Delete the selected trigger, or restore one marked for deletion"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [addButton, deleteButton, statusLabel])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(editorBox)
        editorBox.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: editorBox.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: editorBox.centerYAnchor),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            editorBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 440))
        for v in [bar, split] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        addButton.isEnabled = readOnlyReason == nil
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The list starts narrow; the statement gets the room.
        if !placedDivider, split.bounds.width > 0 {
            placedDivider = true
            split.setPosition(240, ofDividerAt: 0)
        }
    }

    // MARK: - Loading

    func reload() {
        loadTask?.cancel()
        statusLabel.stringValue = "Loading…"
        let connection = connection
        let table = table
        loadTask = Task {
            do {
                let triggers = try await connection.triggers(of: table)
                guard !Task.isCancelled else { return }
                loaded = triggers
                rebuild()
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = "\(error)"
            }
        }
    }

    private func rebuild() {
        let selected = list.selectedRow >= 0 && list.selectedRow < rows.count ? rows[list.selectedRow] : nil
        rows = loaded.map { t in
            Row(name: t.name, detail: ([t.timing] + t.events).joined(separator: " "), object: .trigger(t.name, on: table))
        }
        rows += changes.triggerDefinitions(of: table).filter(\.isNew).map { d in
            Row(name: d.name, detail: "new, created on commit", object: nil, newID: d.id)
        }
        list.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.object == selected.object && $0.newID == selected.newID }) {
            list.selectRowIndexes([i], byExtendingSelection: false)
        }
        updateBar()
    }

    private func updateBar() {
        let n = rows.count
        statusLabel.stringValue = readOnlyReason ?? "\(n) \(n == 1 ? "trigger" : "triggers") on \(table.name)"
        let row = list.selectedRow >= 0 && list.selectedRow < rows.count ? rows[list.selectedRow] : nil
        deleteButton.isEnabled = readOnlyReason == nil && row != nil
        deleteButton.title = row?.object.flatMap { changes.definition(for: $0)?.isDropped == true ? "Restore" : nil } ?? "Delete"
    }

    @objc private func stagedChangesChanged() {
        guard isViewLoaded else { return }
        let ids = Set(changes.triggerDefinitions(of: table).filter(\.isNew).map(\.id))
        let shown = Set(rows.compactMap(\.newID))
        if ids != shown { rebuild() } else {
            list.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: [0])
            updateBar()
        }
    }

    // MARK: - List

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: r.name)
        let detail = NSTextField(labelWithString: r.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        if r.newID != nil {
            attributes[.foregroundColor] = NSColor.systemGreen
        } else if let object = r.object, let staged = changes.definition(for: object) {
            attributes[.foregroundColor] = staged.isDropped ? NSColor.systemRed : NSColor.systemOrange
            if staged.isDropped { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        name.attributedStringValue = NSAttributedString(string: r.name, attributes: attributes)
        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showEditor()
        updateBar()
    }

    /// The selected trigger's statement in the editor, or the empty label.
    private func showEditor() {
        editor?.stageNow()
        editor?.stop()
        editor?.view.removeFromSuperview()
        editor?.removeFromParent()
        editor = nil
        guard list.selectedRow >= 0, list.selectedRow < rows.count else {
            emptyLabel.isHidden = false
            return
        }
        let row = rows[list.selectedRow]
        let place = EditPlace(table: table, side: .structure)
        let target: DefinitionEditorController.Target = row.newID.map { .new($0) } ?? .existing(row.object!)
        let e = DefinitionEditorController(target: target, kind: .trigger, connection: connection, changes: changes,
                                           readOnlyReason: readOnlyReason, place: place)
        e.onStage = { [weak self] in self?.stagedChangesChanged() }
        addChild(e)
        editorBox.addSubview(e.view)
        e.view.translatesAutoresizingMaskIntoConstraints = false
        e.view.pin(to: editorBox)
        emptyLabel.isHidden = true
        editor = e
    }

    /// Stages what's typed (the popover is closing, or the workspace commits).
    func endEditing() { editor?.stageNow() }

    // MARK: - Commands

    @objc func addTrigger(_ sender: Any?) {
        guard readOnlyReason == nil else { return NSSound.beep() }
        endEditing()
        let dialect = connection.dialect
        let table = table
        let taken = Set(loaded.map { $0.name.lowercased() })
        let id = UUID()
        changes.perform("New Trigger", at: EditPlace(table: table, side: .structure)) {
            changes.addNewDefinition(id: id, kind: .trigger, schema: table.schema, table: table, dialect: dialect, taken: taken) { name in
                DefinitionTemplate.text(.trigger, name: name, schema: table.schema, table: table, dialect: dialect)
            }
        }
        rebuild()
        if let i = rows.firstIndex(where: { $0.newID == id }) {
            list.selectRowIndexes([i], byExtendingSelection: false)
            view.window?.makeFirstResponder(editor?.editor)
        }
    }

    /// Marks the selected trigger for deletion (or restores it); a new one is removed.
    @objc func deleteTrigger(_ sender: Any?) {
        guard readOnlyReason == nil, list.selectedRow >= 0, list.selectedRow < rows.count else { return NSSound.beep() }
        endEditing()
        let row = rows[list.selectedRow]
        let place = EditPlace(table: table, side: .structure)
        if let id = row.newID {
            changes.perform("Delete Trigger", at: place) { changes.removeDefinition(id) }
            return rebuild()
        }
        guard let object = row.object else { return }
        if let staged = changes.definition(for: object), staged.isDropped {
            changes.perform("Restore Trigger", at: place) { changes.removeDefinition(staged.id) }
        } else {
            let original = loaded.first { $0.name == object.ref.name }?.definition ?? ""
            var d = StagedDefinition(kind: .trigger, object: object, schema: table.schema, original: original, text: original,
                                     lexer: connection.dialect.lexer)
            d.isDropped = true
            changes.perform("Delete Trigger", at: place) { changes.setDefinition(d) }
        }
        editor?.reload()
    }
}
