import AppCore
import AppKit
import DBKit

/// Edits one foreign key: its columns, the table and columns it references, and what happens
/// to rows here when the referenced row is updated or deleted.
@MainActor
final class ForeignKeyEditorController: NSViewController, NSComboBoxDelegate {
    var onSave: ((ForeignKeyInfo) -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    private let key: ForeignKeyInfo
    private let isNew: Bool
    private let tables: [TableRef]
    /// The referenced table's primary key, to fill in referenced columns.
    private let primaryKey: @MainActor (TableRef) async -> [String]
    private let nameField = NSTextField().singleLine()
    private let columnsField = NSTextField().singleLine()
    private let tableBox = NSComboBox()
    private let referencedField = NSTextField().singleLine()
    private let onUpdate = NSPopUpButton()
    private let onDelete_ = NSPopUpButton()
    private static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]

    init(key: ForeignKeyInfo, isNew: Bool, tables: [TableRef], primaryKey: @escaping @MainActor (TableRef) async -> [String]) {
        self.key = key
        self.isNew = isNew
        self.tables = tables
        self.primaryKey = primaryKey
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        nameField.stringValue = key.name
        nameField.placeholderString = "Chosen by the database"
        columnsField.stringValue = key.columns.joined(separator: ", ")
        columnsField.placeholderString = "column, …"
        tableBox.addItems(withObjectValues: tables.map(\.name))
        tableBox.stringValue = key.referencedTable.name
        tableBox.placeholderString = "Table"
        tableBox.completes = true
        tableBox.delegate = self
        referencedField.stringValue = key.referencedColumns.joined(separator: ", ")
        referencedField.placeholderString = "Its primary key"
        for (popup, value) in [(onUpdate, key.onUpdate), (onDelete_, key.onDelete)] {
            popup.addItems(withTitles: Self.actions)
            popup.selectItem(withTitle: Self.actions.contains(value) ? value : "NO ACTION")
        }

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Columns"), columnsField],
            [label("References"), tableBox],
            [label("Referenced columns"), referencedField],
            [label("On update"), onUpdate],
            [label("On delete"), onDelete_],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for f in [nameField, columnsField, tableBox, referencedField] as [NSView] {
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteKey(_:)))
        delete.isHidden = isNew
        delete.hasDestructiveAction = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(save(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [delete, NSView(), cancel, ok])

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pin(to: root, inset: 14)
        view = root
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// Picking a table fills its primary key in as the referenced columns.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        let i = tableBox.indexOfSelectedItem
        guard i >= 0, i < tables.count else { return }
        let table = tables[i]
        Task {
            let pk = await primaryKey(table)
            if !pk.isEmpty { referencedField.stringValue = pk.joined(separator: ", ") }
        }
    }

    private static func names(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @objc private func save(_ sender: Any?) {
        let name = tableBox.stringValue.trimmingCharacters(in: .whitespaces)
        let target = tables.first { $0.name == name } ?? TableRef(schema: key.referencedTable.schema, name)
        var k = key
        k.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        k.columns = Self.names(columnsField.stringValue)
        k.referencedTable = target
        k.referencedColumns = Self.names(referencedField.stringValue)
        k.onUpdate = onUpdate.titleOfSelectedItem ?? "NO ACTION"
        k.onDelete = onDelete_.titleOfSelectedItem ?? "NO ACTION"
        if k.referencedColumns.isEmpty {
            // Left empty: the referenced table's primary key.
            let partial = k
            Task {
                var k = partial
                k.referencedColumns = await primaryKey(target)
                onSave?(k)
            }
            return
        }
        onSave?(k)
    }

    @objc private func deleteKey(_ sender: Any?) { onDelete?() }
    @objc private func cancel(_ sender: Any?) { onCancel?() }
}

/// Shows a table's CREATE statements, read-only, with a Copy button.
@MainActor
final class DefinitionViewController: NSViewController {
    private let text: String
    private let detail: String

    init(text: String, detail: String) {
        self.text = text
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text

        let info = NSTextField(labelWithString: detail)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText(_:)))
        let bar = NSStackView(views: [info, NSView(), copy])

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 8
        for v in [scroll, bar] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pin(to: root, inset: 12)
        view = root
    }

    @objc private func copyText(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
