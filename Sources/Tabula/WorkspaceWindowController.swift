import AppCore
import AppKit
import DBKit

/// One window per open connection: items sidebar on the left, the open table on the right.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, TabulaActions {
    let config: ConnectionConfig
    let connection: any DatabaseConnection
    var onClose: (() -> Void)?

    let sidebar: SidebarViewController
    let content: ContentViewController

    init(config: ConnectionConfig, connection: any DatabaseConnection) {
        self.config = config
        self.connection = connection
        sidebar = SidebarViewController(connection: connection)
        content = ContentViewController(connection: connection, config: config)

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 420
        split.addSplitViewItem(sideItem)
        let mainItem = NSSplitViewItem(viewController: content)
        mainItem.minimumThickness = 300
        split.addSplitViewItem(mainItem)
        split.splitView.autosaveName = "WorkspaceSplit"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.minSize = NSSize(width: 600, height: 360)
        window.title = config.displayName
        window.subtitle = config.summary
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.center()
        window.setFrameAutosaveName("Workspace")

        sidebar.onOpen = { [weak self] object in self?.open(object) }
        sidebar.reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func open(_ object: DatabaseObject) {
        guard let current = content.tableController, current.table != object.ref, current.hasPendingEdits else {
            content.show(object)
            window?.subtitle = "\(object.ref) — \(config.summary)"
            return
        }
        // Keep the sidebar on the table with staged edits until the user decides.
        sidebar.select { $0.ref == current.table }
        current.resolvePendingEdits(before: "Opening \(object.ref.name)") { [weak self] in
            self?.sidebar.select { $0 == object }
        }
    }

    var hasPendingEdits: Bool { content.tableController?.hasPendingEdits == true }

    /// Asks to commit or discard staged edits, then runs `proceed`.
    func resolvePendingEdits(before action: String, then proceed: @escaping () -> Void) {
        guard let table = content.tableController else { return proceed() }
        window?.makeKeyAndOrderFront(nil)
        table.resolvePendingEdits(before: action, then: proceed)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasPendingEdits else { return true }
        resolvePendingEdits(before: "Closing the window") { sender.close() }
        return false
    }

    /// Grid commands work wherever the focus is in the window, e.g. ⌘S from the sidebar.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let table = content.tableController, table.responds(to: action) { return table }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func windowWillClose(_ notification: Notification) {
        content.closeTable()
        let connection = connection
        Task { await connection.close() }
        onClose?()
    }

    // MARK: - Actions

    @objc func reloadWorkspace(_ sender: Any?) {
        resolvePendingEdits(before: "Reloading") { [self] in
            sidebar.reload()
            content.reload()
        }
    }

    @objc func focusItemFilter(_ sender: Any?) {
        sidebar.focusFilter()
    }

    // MARK: - Toolbar

    private static let reloadItem = NSToolbarItem.Identifier("reload")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.reloadItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard id == Self.reloadItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Reload"
        item.toolTip = "Reload items and the open table (⌘R)"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        item.action = #selector(reloadWorkspace(_:))
        item.target = self
        item.isBordered = true
        return item
    }
}

/// Hosts whatever the sidebar opened. M1 has a single table slot; tabs arrive with M3.
@MainActor
final class ContentViewController: NSViewController {
    private let connection: any DatabaseConnection
    private let config: ConnectionConfig
    private(set) var tableController: TableDataViewController?
    private let placeholder = NSTextField(labelWithString: "Select a table in the sidebar")

    init(connection: any DatabaseConnection, config: ConnectionConfig) {
        self.connection = connection
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    /// Opens `object` in the table slot, replacing what was there. Callers deal with staged edits.
    func show(_ object: DatabaseObject) {
        if tableController?.table == object.ref { return }
        replaceTable(with: object)
    }

    private func replaceTable(with object: DatabaseObject) {
        closeTable()
        let controller = TableDataViewController(
            connection: connection, object: object, readOnlyConnection: config.readOnly, pageSize: config.pageSize)
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.pin(to: view)
        tableController = controller
        placeholder.isHidden = true
    }

    func closeTable() {
        guard let controller = tableController else { return }
        controller.stop()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        tableController = nil
        placeholder.isHidden = false
    }

    func reload() {
        tableController?.reload()
    }
}
