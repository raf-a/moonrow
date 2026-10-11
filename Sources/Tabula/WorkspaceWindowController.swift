import AppCore
import AppKit
import DBKit

/// One window per open connection: sidebar (items, saved queries, history) on the left, tabs
/// of tables and query editors on the right.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, TabulaActions {
    let config: ConnectionConfig
    let connection: any DatabaseConnection
    let environment: QueryEnvironment
    var onClose: (() -> Void)?

    /// The tables and views list.
    let sidebar: SidebarViewController
    let leftSidebar: LeftSidebarController
    let content = WorkspaceTabsController()
    private var queryCount = 0

    init(config: ConnectionConfig, connection: any DatabaseConnection, history: QueryHistory, savedQueries: SavedQueries) {
        self.config = config
        self.connection = connection
        environment = QueryEnvironment(connection: connection, history: history, savedQueries: savedQueries)
        sidebar = SidebarViewController(connection: connection)
        leftSidebar = LeftSidebarController(items: sidebar, savedQueries: savedQueries, history: history)

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: leftSidebar)
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

        sidebar.onOpen = { [weak self] object in self?.open(object, newTab: false) }
        sidebar.onOpenInNewTab = { [weak self] object in self?.open(object, newTab: true) }
        sidebar.onObjectsLoaded = { [weak self] objects in self?.environment.catalog.setObjects(objects) }
        leftSidebar.queries.onOpen = { [weak self] query in self?.openSavedQuery(query) }
        leftSidebar.queries.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.queries.onChange = { [weak self] old, new in self?.savedQueryChanged(old, to: new) }
        leftSidebar.history.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.history.onOpenInNewTab = { [weak self] text in self?.newQuery(text: text) }
        environment.onSchemaChange = { [weak self] in self?.sidebar.reload() }
        content.onSelectionChange = { [weak self] in self?.tabChanged() }
        content.onNewTab = { [weak self] in self?.newQueryTab(nil) }
        sidebar.reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The selected tab's table, if it shows one.
    var tableController: TableDataViewController? { content.current as? TableDataViewController }
    var queryController: QueryEditorViewController? { content.current as? QueryEditorViewController }
    private var tableTabs: [TableDataViewController] { content.tabs.compactMap { $0 as? TableDataViewController } }

    // MARK: - Opening

    /// Opens a table or view. A tab already showing it is selected. Otherwise it replaces the
    /// selected table tab, or opens a new tab when the selected tab is a query (or `newTab`).
    func open(_ object: DatabaseObject, newTab: Bool) {
        if let i = content.tabs.firstIndex(where: { ($0 as? TableDataViewController)?.table == object.ref }) {
            return content.select(i)
        }
        let make = { [config, connection] in
            TableDataViewController(connection: connection, object: object, readOnlyConnection: config.readOnly, pageSize: config.pageSize)
        }
        guard !newTab, let current = tableController else {
            return content.add(make())
        }
        // Keep the sidebar on the table with staged edits until the user decides.
        sidebar.reveal(current.table)
        current.resolvePendingEdits(before: "Opening \(object.ref.name)") { [weak self] in
            guard let self, let i = self.content.tabs.firstIndex(where: { $0 === current }) else { return }
            self.content.replace(at: i, with: make())
        }
    }

    @discardableResult
    func newQuery(text: String = "", saved: SavedQueries.Query? = nil) -> QueryEditorViewController {
        queryCount += 1
        let editor = QueryEditorViewController(environment: environment, number: queryCount, text: text, savedQuery: saved)
        content.add(editor)
        return editor
    }

    private func openSavedQuery(_ query: SavedQueries.Query) {
        if let i = content.tabs.firstIndex(where: { ($0 as? QueryEditorViewController)?.savedQuery?.url == query.url }) {
            return content.select(i)
        }
        do {
            newQuery(text: try environment.savedQueries.text(of: query), saved: query)
        } catch {
            present(error, title: "Couldn't open “\(query.name)”", in: window)
        }
    }

    /// History and saved queries go into the selected query tab, or a new one.
    private func insertIntoEditor(_ text: String) {
        if let editor = queryController {
            editor.insertStatement(text)
        } else {
            newQuery(text: text)
        }
    }

    private func savedQueryChanged(_ old: SavedQueries.Query, to new: SavedQueries.Query?) {
        for case let editor as QueryEditorViewController in content.tabs where editor.savedQuery?.url == old.url {
            editor.savedQueryChanged(to: new)
        }
    }

    private func tabChanged() {
        let table = tableController?.table
        sidebar.reveal(table)
        if let table {
            window?.subtitle = "\(table) — \(config.summary)"
        } else if let editor = queryController {
            window?.subtitle = "\(editor.tabItem.title) — \(config.summary)"
        } else {
            window?.subtitle = config.summary
        }
    }

    // MARK: - Pending edits

    var hasPendingEdits: Bool { tableTabs.contains { $0.hasPendingEdits } }

    /// Asks, one tab at a time, to commit or discard staged edits, then runs `proceed`.
    func resolvePendingEdits(before action: String, then proceed: @escaping () -> Void) {
        guard let tab = tableTabs.first(where: \.hasPendingEdits),
              let i = content.tabs.firstIndex(where: { $0 === tab }) else { return proceed() }
        window?.makeKeyAndOrderFront(nil)
        content.select(i)
        tab.resolvePendingEdits(before: action) { [weak self] in
            self?.resolvePendingEdits(before: action, then: proceed)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasPendingEdits else { return true }
        resolvePendingEdits(before: "Closing the window") { sender.close() }
        return false
    }

    /// Commands work wherever the focus is in the window, e.g. ⌘S or ⌘↩ from the sidebar.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let tab = content.current, tab.responds(to: action) { return tab }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func windowWillClose(_ notification: Notification) {
        content.closeAll()
        let connection = connection
        Task { await connection.close() }
        onClose?()
    }

    // MARK: - Actions

    @objc func reloadWorkspace(_ sender: Any?) {
        resolvePendingEdits(before: "Reloading") { [self] in
            sidebar.reload()
            for tab in tableTabs { tab.reload() }
        }
    }

    @objc func focusItemFilter(_ sender: Any?) {
        leftSidebar.show(.items)
        sidebar.focusFilter()
    }

    @objc func newQueryTab(_ sender: Any?) {
        newQuery()
    }

    /// ⌘W closes the selected tab; with no tabs left it closes the window.
    @objc func closeTab(_ sender: Any?) {
        guard let i = content.selectedIndex else {
            window?.performClose(sender)
            return
        }
        content.close(i)
    }

    @objc func selectNextTab(_ sender: Any?) { content.selectNext(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { content.selectNext(by: -1) }

    /// ⌘1…⌘9; ⌘9 is always the last tab.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, !content.tabs.isEmpty else { return }
        content.select(tag == 9 ? content.tabs.count - 1 : tag - 1)
    }

    @objc func showQueryHistory(_ sender: Any?) { leftSidebar.show(.history) }
    @objc func showSavedQueries(_ sender: Any?) { leftSidebar.show(.queries) }

    // MARK: - Toolbar

    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let queryItem = NSToolbarItem.Identifier("query")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.queryItem, Self.reloadItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case Self.reloadItem:
            item.label = "Reload"
            item.toolTip = "Reload items and open tables (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.action = #selector(reloadWorkspace(_:))
        case Self.queryItem:
            item.label = "New Query"
            item.toolTip = "Open a new query tab (⌘T)"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New query")
            item.action = #selector(newQueryTab(_:))
        default:
            return nil
        }
        return item
    }
}
