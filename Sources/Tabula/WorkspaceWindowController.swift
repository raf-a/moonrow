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
        content = ContentViewController(connection: connection)

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
        content.show(object.ref)
        window?.subtitle = "\(object.ref) — \(config.summary)"
    }

    func windowWillClose(_ notification: Notification) {
        content.closeTable()
        let connection = connection
        Task { await connection.close() }
        onClose?()
    }

    // MARK: - Actions

    @objc func reloadWorkspace(_ sender: Any?) {
        sidebar.reload()
        content.reload()
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
    private(set) var tableController: TableDataViewController?
    private let placeholder = NSTextField(labelWithString: "Select a table in the sidebar")

    init(connection: any DatabaseConnection) {
        self.connection = connection
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

    func show(_ table: TableRef) {
        if tableController?.table == table { return }
        closeTable()
        let controller = TableDataViewController(connection: connection, table: table)
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
