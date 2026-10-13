import AppCore
import AppKit

/// Edit Tags… (the connection form's tag menu): the store's tags in order, each with its colour
/// and name, plus and minus in the footer. Save replaces the store's tags; connections whose tag
/// was removed lose it.
@MainActor
final class TagsSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: ConnectionStore
    private var tags: [ConnectionTag]
    let table = NSTableView()
    /// Plus and minus, joined.
    private let listButtons = NSSegmentedControl()
    let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    private static let dragType = NSPasteboard.PasteboardType("app.moonrow.tag-row")

    init(store: ConnectionStore) {
        self.store = store
        tags = store.tags
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Tags"
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let colour = NSTableColumn(identifier: .init("color"))
        colour.title = "Colour"
        colour.width = 64
        colour.resizingMask = []
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"
        table.addTableColumn(colour)
        table.addTableColumn(name)
        table.dataSource = self
        table.registerForDraggedTypes([Self.dragType])
        // A line where the rows will land. The gap style slid rows over each other while
        // dragging upwards.
        table.draggingDestinationFeedbackStyle = .regular
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        listButtons.segmentCount = 2
        listButtons.trackingMode = .momentary
        for (i, (symbol, label)) in [("plus", "Add tag"), ("minus", "Remove tag")].enumerated() {
            listButtons.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: i)
            listButtons.setWidth(28, forSegment: i)
        }
        listButtons.target = self
        listButtons.action = #selector(listButtonClicked(_:))

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        // Plus and minus at the left of the footer, Cancel and Save at the right.
        let bottom = NSStackView(views: [listButtons, NSView(), cancel, saveButton])
        bottom.spacing = 8

        let title = NSTextField(labelWithString: "Tags")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let main = NSStackView(views: [title, scroll, status, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 0
        main.setCustomSpacing(10, after: title)
        main.setCustomSpacing(14, after: scroll)
        main.setCustomSpacing(14, after: status)
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for v in [scroll, status, bottom] { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -36).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        main.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window?.contentView = main
        status.isHidden = true
        refresh()
        window?.fit(to: main)
    }

    /// `ended` runs when the sheet closes, saved or not.
    func begin(on parent: NSWindow, ended: @escaping () -> Void = {}) {
        guard let sheet = window else { return }
        parent.beginSheet(sheet) { _ in ended() }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { tags.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tag = tags[row]
        let cell = NSTableCellView()
        let control: NSControl
        if tableColumn?.identifier.rawValue == "color" {
            let popup = NSPopUpButton()
            popup.isBordered = false
            for c in ConnectionColor.allCases {
                popup.addItem(withTitle: c.title)
                popup.lastItem?.image = c.dot()
            }
            popup.selectItem(at: ConnectionColor.allCases.firstIndex(of: tag.color) ?? 0)
            popup.imagePosition = .imageOnly
            popup.setAccessibilityLabel("Colour of \(tag.name)")
            popup.target = self
            popup.action = #selector(colorChanged(_:))
            control = popup
        } else {
            let field = NSTextField(string: tag.name)
            field.isBordered = false
            field.drawsBackground = false
            field.placeholderString = "Name"
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            cell.textField = field
            control = field
        }
        cell.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let rows = IndexSet(info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: Self.dragType).flatMap(Int.init) } ?? [])
        guard !rows.isEmpty else { return false }
        moveRows(rows, to: row)
        return true
    }

    /// Moves the rows, in their order, to sit before row `destination` (as it was before the move),
    /// and keeps them selected.
    func moveRows(_ rows: IndexSet, to destination: Int) {
        window?.makeFirstResponder(nil)
        let moving = rows.filter(tags.indices.contains).map { tags[$0] }
        guard !moving.isEmpty else { return }
        let at = destination - rows.count { $0 < destination }
        tags = tags.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        tags.insert(contentsOf: moving, at: max(0, min(at, tags.count)))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integersIn: at..<(at + moving.count)), byExtendingSelection: false)
        refresh()
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard tags.indices.contains(row) else { return }
        tags[row].color = ConnectionColor.allCases[max(0, sender.indexOfSelectedItem)]
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard tags.indices.contains(row) else { return }
        tags[row].name = field.stringValue
        refresh()
    }

    // MARK: - Actions

    /// A tag named "New Tag" (numbered past names taken) in a colour no tag has yet, if any,
    /// with its name ready to type over.
    @objc private func listButtonClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addTag(sender) } else { removeTags(sender) }
    }

    @objc func addTag(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let taken = Set(trimmedNames.map { $0.lowercased() })
        var name = "New Tag"
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "New Tag \(n)"
            n += 1
        }
        let used = Set(tags.map(\.color))
        tags.append(ConnectionTag(name: name, color: ConnectionColor.allCases.first { !used.contains($0) } ?? .gray))
        let row = tags.count - 1
        table.insertRows(at: [row], withAnimation: [])
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if let field = (table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        refresh()
    }

    @objc func removeTags(_ sender: Any?) {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        window?.makeFirstResponder(nil)
        for i in rows.reversed() { tags.remove(at: i) }
        table.removeRows(at: rows, withAnimation: [])
        let next = min(rows.first ?? 0, tags.count - 1)
        if next >= 0 { table.selectRowIndexes([next], byExtendingSelection: false) }
        refresh()
    }

    @objc private func cancel(_ sender: Any?) { window?.sheetParent?.endSheet(window!) }

    @objc func save(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        guard problem == nil else { return refresh() }
        do {
            try store.setTags(tags)
        } catch {
            present(error, title: "Couldn't save the tags", in: window)
            return
        }
        window?.sheetParent?.endSheet(window!)
    }

    // MARK: - State

    private var trimmedNames: [String] { tags.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) } }

    /// Why the tags can't be saved as they are.
    private var problem: String? {
        let names = trimmedNames
        if names.contains(where: \.isEmpty) { return "A tag has no name." }
        var seen = Set<String>()
        for n in names where !seen.insert(n.lowercased()).inserted { return "Two tags are named “\(n)”." }
        return nil
    }

    private func refresh() {
        listButtons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
        saveButton.isEnabled = problem == nil
        let message: String?
        if let problem {
            message = problem
            status.textColor = .systemRed
        } else {
            // Connections whose tag is about to be removed.
            let kept = Set(tags.map(\.id))
            let n = store.connections.filter { c in c.tagID.map { !kept.contains($0) && store.tag(id: $0) != nil } ?? false }.count
            message = n == 0 ? nil : "\(n) connection\(n == 1 ? "" : "s") will have no tag."
            status.textColor = .secondaryLabelColor
        }
        status.stringValue = message ?? ""
        // The sheet grows for the message and shrinks back without it.
        if status.isHidden != (message == nil) {
            status.isHidden = message == nil
            if let window, let content = window.contentView { window.fit(to: content, animate: true) }
        }
    }
}
