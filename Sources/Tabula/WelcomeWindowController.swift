import AppCore
import AppKit

/// The launch window: app identity on the left, saved connections on the right.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate
{
    private let store: ConnectionStore
    private unowned let app: AppDelegate

    private let table = KeyTableView()
    private let search = NSSearchField()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var shown: [ConnectionConfig] = []

    init(store: ConnectionStore, app: AppDelegate) {
        self.store = store
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Connections"
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("Welcome")

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: ConnectionStore.didChange, object: store)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(table)
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let root = NSView()

        // Left: identity and the two ways in.
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let name = NSTextField(labelWithString: "Tabula")
        name.font = .systemFont(ofSize: 26, weight: .semibold)
        let version = NSTextField(labelWithString: "Version \(Self.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let newButton = NSButton(title: "New Connection…", target: nil, action: #selector(TabulaActions.newConnection(_:)))
        let openButton = NSButton(title: "Open Database File…", target: nil, action: #selector(AppDelegate.openDocument(_:)))
        for b in [newButton, openButton] {
            b.controlSize = .large
            b.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }

        let sideStack = NSStackView(views: [icon, name, version, NSView(), newButton, openButton])
        sideStack.orientation = .vertical
        sideStack.alignment = .centerX
        sideStack.spacing = 8
        sideStack.setCustomSpacing(16, after: icon)
        sideStack.edgeInsets = NSEdgeInsets(top: 56, left: 20, bottom: 24, right: 20)
        side.addSubview(sideStack)
        sideStack.pin(to: side)

        // Right: search, add, the list.
        search.placeholderString = "Search connections"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New connection")!,
                           target: nil, action: #selector(TabulaActions.newConnection(_:)))
        add.bezelStyle = .accessoryBarAction
        add.toolTip = "New connection"
        let header = NSStackView(views: [search, add])
        header.spacing = 6

        let column = NSTableColumn(identifier: .init("connection"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectClicked(_:))
        table.menu = makeContextMenu()
        table.onReturn = { [weak self] in self?.connectSelected() }
        table.onDelete = { [weak self] in self?.deleteClicked(nil) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        scroll.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
        ])

        let main = NSStackView(views: [header, scroll])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 40, left: 16, bottom: 16, right: 16)
        header.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -32).isActive = true
        scroll.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        for v in [side, main] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 250),
            main.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if clickedConnection != nil {
            menu.add("Connect", #selector(connectClicked(_:))).target = self
            menu.add("Edit…", #selector(editClicked(_:))).target = self
            menu.add("Duplicate", #selector(duplicateClicked(_:))).target = self
            menu.addItem(.separator())
            menu.add("Delete…", #selector(deleteClicked(_:))).target = self
            menu.addItem(.separator())
        }
        menu.add("New Connection…", #selector(TabulaActions.newConnection(_:)))
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Data

    @objc private func storeChanged() { reload() }

    private func reload() {
        let selected = selectedConnection?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? store.connections : store.connections.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        if let selected, let row = shown.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        emptyLabel.stringValue = store.connections.isEmpty
            ? "No saved connections.\nClick + to add one, or drop a database file on the Dock icon."
            : "Nothing matches “\(query)”."
        emptyLabel.isHidden = !shown.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Arrow keys and Return in the search field drive the list.
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            window?.makeFirstResponder(table)
            table.keyDown(with: NSApp.currentEvent!)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            connectSelected()
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ConnectionCell.identifier, owner: nil) as? ConnectionCell
            ?? ConnectionCell()
        cell.show(shown[row])
        return cell
    }

    // MARK: - Commands

    private var selectedConnection: ConnectionConfig? {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
    }

    /// The right-clicked row if there is one, else the selection.
    private var clickedConnection: ConnectionConfig? {
        if table.clickedRow >= 0 { return shown.indices.contains(table.clickedRow) ? shown[table.clickedRow] : nil }
        return selectedConnection
    }

    private func connectSelected() {
        guard let c = selectedConnection else { return }
        app.connect(c, presentingErrorsIn: window)
    }

    @objc private func connectClicked(_ sender: Any?) {
        guard let c = clickedConnection else { return }
        app.connect(c, presentingErrorsIn: window)
    }

    @objc private func editClicked(_ sender: Any?) {
        guard let c = clickedConnection else { return }
        app.editConnection(c, isNew: false)
    }

    @objc private func duplicateClicked(_ sender: Any?) {
        guard let c = clickedConnection else { return }
        do { try store.duplicate(id: c.id) } catch { present(error, title: "Couldn't duplicate", in: window) }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let c = clickedConnection, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(c.displayName)”?"
        alert.informativeText = "This removes the saved connection. The database itself is not touched."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.delete(id: c.id) } catch { present(error, title: "Couldn't delete", in: self.window) }
        }
    }

}

/// Name over a one-line summary, with a driver glyph.
private final class ConnectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for f in [title, detail] {
            f.lineBreakMode = .byTruncatingMiddle
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        glyph.image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        glyph.contentTintColor = .controlAccentColor
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [glyph, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        addSubview(row)
        row.pin(to: self)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: ConnectionConfig) {
        title.stringValue = c.displayName
        detail.stringValue = c.summary
        toolTip = c.expandedFilePath
    }
}

/// A table that reports Return and Delete instead of beeping.
final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, [36, 76].contains(event.keyCode), let onReturn {  // Return, keypad Enter
            onReturn()
        } else if plain, [51, 117].contains(event.keyCode), let onDelete {  // Delete, Forward Delete
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension NSView {
    /// Pins all four edges to `container`.
    func pin(to container: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }
}
