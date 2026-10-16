import AppCore
import AppKit
import DBKit
import SQLScript

/// Open Database (⌘K): the server's databases as a sheet laid out as Open Connection, to switch
/// the workspace to one. Return or a double-click opens; New… creates one (`NewDatabaseSheet`).
@MainActor
final class DatabasePicker: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let window: NSWindow
    let search = NSSearchField()
    let outline = KeyOutlineView()
    private let scroll = NSScrollView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let newButton = NSButton(title: "New…", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Every database, as listed; `shown` is what the search leaves.
    private(set) var databases: [String] = []
    private var shown: [String] = []
    /// The workspace's database, marked in the list.
    var current: String?
    /// Whether Rename… is offered (Postgres; MySQL can't rename a database).
    var canRename = false
    /// Whether New… is offered (not on read-only connections).
    var canCreate = true {
        didSet { newButton.isEnabled = canCreate }
    }

    var onOpen: ((String) -> Void)?
    var onOpenInNewTab: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDrop: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460), styleMask: [.titled],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Open Database"
        window.isReleasedWhenClosed = false
        window.contentView = makeContent()
    }

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: "Open Database")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center

        search.placeholderString = "Search databases"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: .init("database"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.indentationPerLevel = 0
        outline.backgroundColor = .clear
        outline.rowHeight = 28
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onReturn = { [weak self] in self?.open(nil) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        scroll.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        newButton.target = self
        newButton.action = #selector(newDatabase(_:))
        openButton.target = self
        openButton.action = #selector(open(_:))
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false
        let buttons = NSStackView(views: [cancel, NSView(), newButton, openButton])
        buttons.spacing = 8

        // The search field lines up with the list's selection, not its sides.
        let searchRow = NSStackView(views: [search])
        let inset = ConnectionList.selectionInset
        searchRow.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        let stack = NSStackView(views: [heading, searchRow, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [searchRow, scroll, buttons, heading] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        return stack
    }

    /// Shows `names`, selecting `select` (else the current database, else the first).
    func show(_ names: [String], select: String? = nil) {
        databases = names
        reload(select: select ?? selected ?? current)
    }

    private func reload(select name: String?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = Self.rank(databases, query: query)
        outline.reloadData()
        let row = name.flatMap { shown.firstIndex(of: $0) } ?? (shown.isEmpty ? nil : 0)
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        emptyLabel.stringValue = databases.isEmpty ? "No databases." : "No match."
        emptyLabel.isHidden = !shown.isEmpty
        openButton.isEnabled = selected != nil
    }

    /// Better matches first (prefix, word starts, then fuzzy), then by name; all when nothing is typed.
    static func rank(_ names: [String], query: String) -> [String] {
        guard !query.isEmpty else { return names }
        let matched = names.compactMap { name in SQLCompletion.matchTier(name, query: query).map { (name, $0) } }
        return matched.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.localizedStandardCompare(b.0) == .orderedAscending
        }.map(\.0)
    }

    /// Types `query` into the search field (the harness).
    func type(_ query: String) {
        search.stringValue = query
        reload(select: selected)
    }

    var selected: String? { shown.indices.contains(outline.selectedRow) ? shown[outline.selectedRow] : nil }

    func begin(on parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(search)
    }

    func close() {
        window.sheetParent?.endSheet(window)
        onClose?()
    }

    // MARK: - List

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? shown.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { shown[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let name = item as? String else { return nil }
        let cell = outlineView.makeView(withIdentifier: OpenDatabaseCell.identifier, owner: nil) as? OpenDatabaseCell ?? OpenDatabaseCell()
        cell.show(name, isCurrent: name == current)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = selected != nil
    }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) { reload(select: selected) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            // The arrows move in the list while typing goes on in the field.
            if let event = NSApp.currentEvent { outline.keyDown(with: event) }
        case #selector(NSResponder.insertNewline(_:)): open(nil)
        case #selector(NSResponder.cancelOperation(_:)): cancel(nil)
        default: return false
        }
        return true
    }

    // MARK: - Commands

    @objc private func doubleClicked() {
        guard shown.indices.contains(outline.clickedRow) else { return }
        choose(shown[outline.clickedRow])
    }

    @objc func open(_ sender: Any?) {
        guard let name = selected else { return NSSound.beep() }
        choose(name)
    }

    private func choose(_ name: String) {
        close()
        onOpen?(name)
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc func newDatabase(_ sender: Any?) {
        guard canCreate else { return NSSound.beep() }
        onNew?()
    }

    private var clicked: String? { shown.indices.contains(outline.clickedRow) ? shown[outline.clickedRow] : nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let name = clicked else { return }
        let isCurrent = name == current
        menu.add("Open in New Tab", #selector(openInNewTab(_:))).target = self
        menu.add("Open", #selector(openClicked(_:))).target = self
        menu.add("Copy Name", #selector(copyName(_:))).target = self
        menu.addItem(.separator())
        let new = menu.add("New…", #selector(newDatabase(_:)))
        new.target = self
        new.isEnabled = canCreate
        if canRename {
            let rename = menu.add("Rename…", #selector(rename(_:)))
            rename.target = isCurrent ? nil : self
            rename.isEnabled = !isCurrent && canCreate
        }
        let drop = menu.add("Drop…", #selector(drop(_:)))
        drop.target = isCurrent ? nil : self
        drop.isEnabled = !isCurrent && canCreate
        menu.autoenablesItems = false
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let name = clicked else { return }
        close()
        onOpenInNewTab?(name)
    }

    @objc private func openClicked(_ sender: Any?) { if let name = clicked { choose(name) } }

    @objc private func copyName(_ sender: Any?) {
        guard let name = clicked else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func rename(_ sender: Any?) { if let name = clicked { onRename?(name) } }
    @objc private func drop(_ sender: Any?) { if let name = clicked { onDrop?(name) } }
}

/// A database row: a cylinder (as Backup and Restore list databases) and the name, the current
/// one marked.
final class OpenDatabaseCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("OpenDatabaseCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let mark = NSTextField(labelWithString: "Current")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "cylinder", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mark.textColor = .secondaryLabelColor
        mark.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [icon, name, NSView(), mark])
        row.spacing = 8
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ database: String, isCurrent: Bool) {
        name.stringValue = database
        mark.isHidden = !isCurrent
        setAccessibilityLabel(isCurrent ? "\(database), current" : database)
    }
}

/// New Database…: a name, and the encoding and collation (Default leaves each to the server).
/// Shared by ⌘K's New… and the Backup and Restore windows. `create` makes the database (safe mode
/// and errors included); the sheet closes when that works, and shows the error otherwise.
@MainActor
final class NewDatabaseSheet: NSObject, NSTextFieldDelegate {
    let sheet: NSWindow
    let nameField = NSTextField()
    let encodingPopup = NSPopUpButton()
    let collationPopup = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let existing: [String]
    private let connection: any DatabaseConnection
    private let create: (NewDatabase) async -> Bool
    private let isMySQL: Bool
    private var encodings: [String] = []
    private var defaultEncoding: String?
    private(set) var collations: [DatabaseCollation] = []
    private var loadTask: Task<Void, Never>?
    /// Set once the encodings and the first collations are listed (for the harness).
    private(set) var isLoaded = false

    init(existing: [String], connection: any DatabaseConnection, create: @escaping (NewDatabase) async -> Bool) {
        self.existing = existing
        self.connection = connection
        self.create = create
        isMySQL = connection.dialect.lexer == .mysql
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        sheet.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "New Database")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.delegate = self
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        for popup in [encodingPopup, collationPopup] {
            popup.addItem(withTitle: "Default")
            popup.isEnabled = false
        }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.isSelectable = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: isMySQL ? "Character set:" : "Encoding:"), encodingPopup],
            [NSTextField(labelWithString: "Collation:"), collationPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        for popup in [encodingPopup, collationPopup] { popup.widthAnchor.constraint(equalTo: nameField.widthAnchor).isActive = true }
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 9
        grid.columnSpacing = 8

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(okClicked(_:))
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, okButton])
        let main = NSStackView(views: [title, grid, errorLabel, buttons])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in [errorLabel, buttons] { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -40).isActive = true }
        sheet.contentView = main
        sheet.initialFirstResponder = nameField
        load()
    }

    /// The server's encodings, then the collations for the default one.
    private func load() {
        let connection = connection
        loadTask = Task {
            do {
                let encodings = try await DatabaseCatalog.encodings(connection)
                let fallback = try await DatabaseCatalog.defaultEncoding(connection)
                guard !Task.isCancelled else { return }
                self.encodings = encodings
                defaultEncoding = fallback
                fill(encodingPopup, encodings, defaultTitle: fallback.map { "Default (\($0))" })
                encodingPopup.isEnabled = true
                await loadCollations(keeping: nil)
                isLoaded = true
            } catch {
                show(error: (error as? DatabaseError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func fill(_ popup: NSPopUpButton, _ titles: [String], defaultTitle: String? = nil) {
        popup.removeAllItems()
        popup.addItem(withTitle: defaultTitle ?? "Default")
        if !titles.isEmpty { popup.menu?.addItem(.separator()) }
        // Titles are added one by one: `addItems` drops duplicates and treats some as separators.
        for t in titles { popup.menu?.addItem(withTitle: t, action: nil, keyEquivalent: "") }
        popup.selectItem(at: 0)
    }

    var encoding: String? {
        encodingPopup.indexOfSelectedItem > 1 ? encodingPopup.titleOfSelectedItem : nil
    }

    var collation: DatabaseCollation? {
        let i = collationPopup.indexOfSelectedItem - 2
        return collations.indices.contains(i) ? collations[i] : nil
    }

    /// The collations for the chosen encoding (the default one for Default). MySQL starts again
    /// at Default for a new character set; Postgres keeps the choice when it's still offered.
    private func loadCollations(keeping kept: String?) async {
        collationPopup.isEnabled = false
        do {
            let list = try await DatabaseCatalog.collations(connection, encoding: encoding ?? defaultEncoding)
            collations = list
            fill(collationPopup, list.map(\.name))
            if let kept, let i = list.firstIndex(where: { $0.name == kept }) { collationPopup.selectItem(at: i + 2) }
            collationPopup.isEnabled = true
        } catch {
            show(error: (error as? DatabaseError)?.message ?? error.localizedDescription)
        }
    }

    @objc private func encodingChanged(_ sender: Any?) {
        let kept = isMySQL ? nil : collation?.name
        Task { await loadCollations(keeping: kept) }
    }

    func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        sheet.contentView.map { sheet.fit(to: $0) }
    }

    private var name: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    func controlTextDidChange(_ obj: Notification) {
        let taken = existing.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        errorLabel.stringValue = taken ? "A database named \(name) exists already." : ""
        errorLabel.isHidden = !taken
        okButton.isEnabled = !name.isEmpty && !taken
    }

    /// What OK creates.
    var newDatabase: NewDatabase { NewDatabase(name: name, encoding: encoding, collation: collation) }

    @objc func okClicked(_ sender: Any?) {
        guard okButton.isEnabled else { return }
        let new = newDatabase
        okButton.isEnabled = false
        errorLabel.isHidden = true
        Task {
            if await create(new) {
                loadTask?.cancel()
                sheet.sheetParent?.endSheet(sheet)
            } else {
                okButton.isEnabled = true
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        loadTask?.cancel()
        sheet.sheetParent?.endSheet(sheet)
    }
}
