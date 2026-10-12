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
    var safety: SafetyGate { environment.safety }

    /// The tables and views list.
    let sidebar: SidebarViewController
    let leftSidebar: LeftSidebarController
    let content = WorkspaceTabsController()
    /// The right sidebar: the selected rows, columns or indexes as a form.
    let inspector = InspectorViewController()
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!
    /// Everything staged in this workspace; one commit (⌘S) covers it all, and its undo manager
    /// is the window's.
    let changes = StagedChanges()
    /// Field editor with its own text undo, so typing never lands in the staged changes' steps.
    private let fieldEditor = FieldEditor()
    private var queryCount = 0
    var isCommitting = false
    /// The open preview sheet, if any.
    var previewSheet: NSWindowController?

    /// `password` is the database password the workspace logged in with; safe mode's password
    /// levels ask for it.
    init(config: ConnectionConfig, connection: any DatabaseConnection, history: QueryHistory, savedQueries: SavedQueries,
         password: String?) {
        self.config = config
        self.connection = connection
        let safety = SafetyGate(
            level: config.safeMode, credential: SafetyCredential(password: password, connectionName: config.displayName),
            connectionName: config.displayName, dialect: connection.dialect.lexer)
        environment = QueryEnvironment(connection: connection, history: history, savedQueries: savedQueries, safety: safety)
        sidebar = SidebarViewController(connection: connection)
        leftSidebar = LeftSidebarController(items: sidebar, savedQueries: savedQueries, history: history)

        let sideItem = NSSplitViewItem(sidebarWithViewController: leftSidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 420
        split.addSplitViewItem(sideItem)
        let mainItem = NSSplitViewItem(viewController: content)
        mainItem.minimumThickness = 300
        split.addSplitViewItem(mainItem)
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 520
        inspectorItem.canCollapse = true
        split.addSplitViewItem(inspectorItem)
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
        self.inspectorItem = inspectorItem
        inspectorItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.inspectorVisibleKey)
        window.delegate = self
        safety.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(safetyLevelChanged), name: SafetyGate.levelDidChange, object: safety)
        NotificationCenter.default.addObserver(self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)

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
        sidebar.markFor = { [weak self] table in self?.changes.mark(for: table) }
        sidebar.stagedNewTables = { [weak self] in
            self?.changes.newTables.map { ($0.id, $0.editor.name) } ?? []
        }
        sidebar.onOpenNewTable = { [weak self] id in self?.openNewTable(id) }
        sidebar.stagedNameFor = { [weak self] table in self?.changes.stagedName(for: table) }
        changes.onRestore = { [weak self] place in self?.show(place) }
        leftSidebar.queries.onOpen = { [weak self] query in self?.openSavedQuery(query) }
        leftSidebar.queries.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.queries.onChange = { [weak self] old, new in self?.savedQueryChanged(old, to: new) }
        leftSidebar.history.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.history.onOpenInNewTab = { [weak self] text in self?.newQuery(text: text) }
        environment.onSchemaChange = { [weak self] in self?.sidebar.reload() }
        content.onSelectionChange = { [weak self] in self?.tabChanged() }
        content.onNewTab = { [weak self] in self?.newQueryTab(nil) }
        connectSidebarActions()
        connectTransferActions()
        sidebar.reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The selected tab, if it shows a table.
    var tableTab: TableTabViewController? { content.current as? TableTabViewController }
    /// The selected tab's rows, if it shows a table's data.
    var tableController: TableDataViewController? { tableTab?.data }
    var queryController: QueryEditorViewController? { content.current as? QueryEditorViewController }
    var tableTabs: [TableTabViewController] { content.tabs.compactMap { $0 as? TableTabViewController } }

    // MARK: - Opening

    /// Opens a table or view. A tab already showing it is selected. Otherwise it replaces the
    /// selected table tab, or opens a new tab when the selected tab is a query (or `newTab`).
    /// Staged changes stay with the workspace, so replacing a tab never asks.
    func open(_ object: DatabaseObject, newTab: Bool, mode: TableTabViewController.Mode = .data) {
        if let i = content.tabs.firstIndex(where: {
            ($0 as? TableTabViewController).map { $0.newTableID == nil && $0.table == object.ref } ?? false
        }) {
            content.select(i)
            tableTab?.switchTo(mode)
            return
        }
        let tab = makeTab(object, mode: mode)
        guard !newTab, let current = tableTab, let i = content.tabs.firstIndex(where: { $0 === current }) else {
            return content.add(tab)
        }
        current.endEditing()
        content.replace(at: i, with: tab)
    }

    /// Stages a new table and opens its structure; it is created on commit.
    @objc func newTable(_ sender: Any?) {
        guard !config.readOnly else { return NSSound.beep() }
        let taken = Set(environment.catalog.objects.map { $0.ref.name.lowercased() })
        let id = UUID()
        changes.perform("New Table", at: EditPlace(newTable: id, side: .sidebar)) {
            changes.addNewTable(id: id, schema: sidebar.schema, dialect: connection.dialect, taken: taken)
        }
        openNewTable(id)
    }

    /// Selects the tab of a staged new table, or opens one.
    func openNewTable(_ id: UUID) {
        if let i = content.tabs.firstIndex(where: { ($0 as? TableTabViewController)?.newTableID == id }) {
            return content.select(i)
        }
        content.add(configure(TableTabViewController(
            connection: connection, changes: changes, newTable: id, schema: sidebar.schema, pageSize: config.pageSize)))
    }

    @discardableResult
    func newQuery(text: String = "", saved: SavedQueries.Query? = nil) -> QueryEditorViewController {
        queryCount += 1
        let editor = QueryEditorViewController(environment: environment, number: queryCount, text: text, savedQuery: saved)
        editor.results.dialect = connection.dialect
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

    func tabChanged() {
        inspector.source = tableTab?.active as? InspectorSource
        let table = tableTab?.table
        if let id = tableTab?.newTableID { sidebar.reveal(newTable: id) } else { sidebar.reveal(table) }
        if let table, tableTab?.newTableID == nil {
            window?.subtitle = "\(table) — \(config.summary)"
        } else if let editor = queryController {
            window?.subtitle = "\(editor.tabItem.title) — \(config.summary)"
        } else {
            window?.subtitle = config.summary
        }
    }

    // MARK: - Staged changes

    @objc private func stagedChangesChanged() {
        window?.isDocumentEdited = !changes.isEmpty
        sidebar.stagedChangesChanged()
        // A new table that's no longer staged (discarded, deleted, undone) closes its tab.
        for tab in tableTabs {
            if let id = tab.newTableID, changes.newTable(id) == nil { closeWithoutAsking(tab) }
        }
        content.refreshTabItems()
        updateChangesItem()
        inspector.refresh()
    }

    /// After an undo or redo: opens the table the step was made on (if its tab was closed),
    /// on the side it was made, and selects what was selected then.
    func show(_ place: EditPlace) {
        switch place.side {
        case .sidebar:
            leftSidebar.show(.items)
            if let id = place.newTable, changes.newTable(id) != nil { return openNewTable(id) }
            sidebar.reveal(place.objects.map(\.ref))
        case .data, .structure:
            let mode: TableTabViewController.Mode = place.side == .data ? .data : .structure
            if let id = place.newTable {
                guard changes.newTable(id) != nil else { return }
                openNewTable(id)
            } else if let table = place.table {
                open(DatabaseObject(table, kind: place.kind), newTab: false, mode: mode)
            }
            switch mode {
            case .data: tableTab?.data?.restoreSelection(place)
            case .structure: tableTab?.structure?.restoreSelection(place)
            }
        }
    }

    func closeWithoutAsking(_ tab: TableTabViewController) {
        if let i = content.tabs.firstIndex(where: { $0 === tab }) { content.close(i) }
    }

    /// Asks to commit or discard everything staged before `action` (closing, quitting), then
    /// runs `proceed`. Cancel does nothing.
    func resolveStagedChanges(before action: String, then proceed: @escaping () -> Void) {
        endAllEditing()
        guard !changes.isEmpty, let window else { return proceed() }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Commit staged changes to \(config.displayName)?"
        alert.informativeText = "\(action) drops changes that aren't committed:\n\(changes.summary)"
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.commitStaged(then: proceed)
            case .alertSecondButtonReturn:
                self?.changes.clearAfterCommit()
                proceed()
            default: break
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard changes.isEmpty else {
            resolveStagedChanges(before: "Closing the window") { sender.close() }
            return false
        }
        return true
    }

    /// Commands work wherever the focus is in the window, e.g. ⌘S or ⌘↩ from the sidebar.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let active = tableTab?.active, active.responds(to: action) { return active }
        if let tab = content.current, tab.responds(to: action) { return tab }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { changes.undoManager }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? fieldEditor : nil
    }

    func windowWillClose(_ notification: Notification) {
        // Dragging the divider can hide the right sidebar too.
        UserDefaults.standard.set(isInspectorVisible, forKey: Self.inspectorVisibleKey)
        content.closeAll()
        let connection = connection
        Task { await connection.close() }
        onClose?()
    }

    // MARK: - Actions

    /// ⌘R: reads the items and open tables again. Staged changes stay.
    @objc func reloadWorkspace(_ sender: Any?) {
        for tab in tableTabs { tab.endEditing() }
        sidebar.reload()
        for tab in tableTabs { tab.reload() }
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

    // MARK: - Safe mode

    /// Asks safe mode before statements other than the grid's and editor's own are sent
    /// (imports, for example). True when they may go.
    func confirmWrite(_ statements: [String]) async -> Bool {
        await safety.approve(statements)
    }

    @objc func changeSafeMode(_ sender: NSMenuItem) {
        guard let level = SafeMode.allCases[safe: sender.tag] else { return }
        Task { await safety.change(to: level) }
    }

    @objc private func safetyLevelChanged() { updateSafetyItem() }

    private func makeSafetyMenu() -> NSMenu {
        let menu = NSMenu(title: "Safe Mode")
        for (i, level) in SafeMode.allCases.enumerated() {
            let item = menu.addItem(withTitle: level.title, action: #selector(changeSafeMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = level.detail
        }
        if config.readOnly {
            menu.addItem(.separator())
            menu.addItem(withTitle: "The connection is read-only", action: nil, keyEquivalent: "").isEnabled = false
        }
        return menu
    }

    private func updateSafetyItem() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.safetyItem }) as? NSMenuToolbarItem else { return }
        let level = safety.level
        let symbol = config.readOnly ? "lock.fill"
            : level == .silent ? "shield" : level.requiresPassword ? "lock.shield" : "exclamationmark.shield"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Safe mode")
        item.label = "Safe Mode"
        item.toolTip = "Safe mode: \(level.title)" + (config.readOnly ? " · read-only connection" : "")
        for menuItem in item.menu.items where menuItem.action == #selector(changeSafeMode(_:)) {
            menuItem.state = menuItem.tag == SafeMode.allCases.firstIndex(of: level) ? .on : .off
        }
    }

    // MARK: - Toolbar

    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let changesItem = NSToolbarItem.Identifier("changes")
    private static let safetyItem = NSToolbarItem.Identifier("safety")
    private static let markItem = NSToolbarItem.Identifier("mark")
    private static let inspectorToggleItem = NSToolbarItem.Identifier("rightSidebar")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
        if config.markColor != nil || config.tag != nil { items.append(Self.markItem) }
        return items + [.flexibleSpace, Self.changesItem, Self.safetyItem, Self.reloadItem,
                        .inspectorTrackingSeparator, .flexibleSpace, Self.inspectorToggleItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case Self.safetyItem:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = makeSafetyMenu()
            item.showsIndicator = true
            DispatchQueue.main.async { [weak self] in self?.updateSafetyItem() }
            item.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Safe mode")
            item.label = "Safe Mode"
            return item
        case Self.markItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = ConnectionMarkView(config)
            item.label = config.tag?.title ?? "Colour"
            item.toolTip = config.tag.map { "\($0.title) connection" } ?? config.displayName
            return item
        default:
            break
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case Self.reloadItem:
            item.label = "Reload"
            item.toolTip = "Reload items and open tables (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.action = #selector(reloadWorkspace(_:))
        case Self.changesItem:
            item.label = "Changes"
            item.toolTip = "Review the SQL for every staged change (⇧⌘P)"
            item.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Staged changes")
            item.action = #selector(previewChanges(_:))
            item.autovalidates = false
            DispatchQueue.main.async { [weak self] in self?.updateChangesItem() }
        case Self.inspectorToggleItem:
            item.label = "Right Sidebar"
            item.toolTip = "Show or hide the right sidebar (Space)"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Right sidebar")
            item.action = #selector(toggleRightSidebar(_:))
        default:
            return nil
        }
        return item
    }

    /// The Changes item: an icon with the count as a badge, greyed out with nothing staged.
    func updateChangesItem() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.changesItem }) else { return }
        let n = changes.changeCount
        shownChangeCount = n
        // Toolbar badges arrived in macOS 26; earlier systems show the icon alone.
        if #available(macOS 26.0, *) { item.badge = n > 0 ? .count(n) : nil }
        item.toolTip = n == 0 ? "No staged changes"
            : "\(n) staged \(n == 1 ? "change" : "changes"). Review the SQL (⇧⌘P)"
        item.isEnabled = n > 0 && !isCommitting
    }

    /// The count the Changes item shows.
    private(set) var shownChangeCount = 0

    // MARK: - Right sidebar

    static let inspectorVisibleKey = "RightSidebarVisible"

    var isInspectorVisible: Bool { !inspectorItem.isCollapsed }

    /// Space (from a grid), the toolbar button, or View ▸ Sidebars ▸ Right Sidebar.
    @objc func toggleRightSidebar(_ sender: Any?) {
        // Not animated, so the state is settled at once for the next toggle.
        inspectorItem.isCollapsed.toggle()
        UserDefaults.standard.set(!inspectorItem.isCollapsed, forKey: Self.inspectorVisibleKey)
        inspector.refresh()
    }
}

extension UndoManager {
    /// Validates Edit ▸ Undo / Redo against this manager, setting their titles; nil for other items.
    @MainActor
    func validate(_ item: NSMenuItem) -> Bool? {
        switch item.action.map(NSStringFromSelector) {
        case "undo:":
            item.title = undoMenuItemTitle
            return canUndo
        case "redo:":
            item.title = redoMenuItemTitle
            return canRedo
        default:
            return nil
        }
    }
}

/// The window's field editor. Its typing has its own undo, cleared when the edit ends, so ⌘Z
/// in a cell or field undoes text and ⌘Z elsewhere undoes staged changes.
final class FieldEditor: NSTextView {
    private let textUndo = UndoManager()

    init() {
        super.init(frame: .zero)
        isFieldEditor = true
        allowsUndo = true
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { textUndo }

    // NSWindow's undo: would use the window's manager; these keep ⌘Z on the text.
    @objc func undo(_ sender: Any?) { textUndo.undo() }
    @objc func redo(_ sender: Any?) { textUndo.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        textUndo.validate(item) ?? super.validateMenuItem(item)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { textUndo.removeAllActions() }
        return resigned
    }
}
