import AppCore
import AppKit
import DBKit

/// One window per open connection: sidebar (items, saved queries, history) on the left, panes
/// of tabs (tables and query editors) on the right.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, MoonrowActions {
    let config: ConnectionConfig
    /// The database password the workspace logged in with (Backup and Restore reuse it).
    let loginPassword: String?
    let connection: any DatabaseConnection
    let environment: QueryEnvironment
    var onClose: (() -> Void)?
    var safety: SafetyGate { environment.safety }

    /// The tables and views list.
    let sidebar: SidebarViewController
    let leftSidebar: LeftSidebarController
    /// The panes of tabs side by side; `content` is the active one.
    let panes = WorkspacePanesController()
    /// Every statement the connection sends (the bottom panel, ⌃⌘C).
    let queryLog = QueryLog()
    /// Opens another session with the workspace's login (Running Queries).
    var openSession: (() async throws -> any DatabaseConnection)?
    /// For the dev harness: the Running Queries sheet while it's open.
    private(set) var runningQueries: RunningQueriesSheet?
    private(set) var center: WorkspaceCenterController!
    var content: WorkspaceTabsController { panes.active }
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
    /// Back / Forward over the tabs this window showed.
    private(set) var history = NavigationHistory<NavigationPlace>()
    private var isNavigating = false
    /// After tabs, panes or query text change, so the app can save its session.
    var onSessionChange: (() -> Void)?
    /// Items recently chosen in Quick Open, most recent first.
    var quickOpenRecent: [QuickOpen.Item] = []
    /// Quick Open's items from the last time it listed every schema.
    var quickOpenItems: [QuickOpen.Item] = []
    var picker: PickerPanel?
    /// Show Diagram's window, while it's open.
    private(set) var diagram: DiagramWindowController?

    /// `password` is the database password the workspace logged in with; safe mode's password
    /// levels ask for it.
    init(config: ConnectionConfig, connection: any DatabaseConnection, history: QueryHistory, savedQueries: SavedQueries,
         password: String?) {
        self.config = config
        self.loginPassword = password
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
        queryLog.follow(connection)
        center = WorkspaceCenterController(panes: panes, log: QueryLogViewController(log: queryLog, dialect: connection.dialect))
        let mainItem = NSSplitViewItem(viewController: center)
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
        // The toolbar shows the name, the connection's tag and the subtitle itself (`titleView`);
        // the window keeps them for the Window menu and window tabs.
        window.title = config.displayName
        window.subtitle = config.shortSummary
        window.titleVisibility = .hidden
        // Workspaces can be merged into one window's tabs (Window ▸ Merge All Windows); the
        // system's tab overview is View ▸ Show All Tabs.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MoonrowWorkspace"
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

        // A single click previews and leaves the focus in the list; a double-click keeps the tab.
        sidebar.onOpen = { [weak self] object, intent in self?.open(object, intent: intent, focus: intent != .preview) }
        sidebar.onObjectsLoaded = { [weak self] objects in self?.environment.catalog.setObjects(objects) }
        sidebar.markFor = { [weak self] object in self?.changes.mark(for: object) }
        sidebar.stagedNewTables = { [weak self] in
            self?.changes.newTables.map { ($0.id, $0.editor.name) } ?? []
        }
        sidebar.onOpenNewTable = { [weak self] id in self?.openNewTable(id) }
        sidebar.stagedNameFor = { [weak self] table in self?.changes.stagedName(for: table) }
        changes.onRestore = { [weak self] place in self?.show(place) }
        leftSidebar.queries.onOpen = { [weak self] query in self?.openSavedQuery(query) }
        leftSidebar.queries.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.queries.onChange = { [weak self] old, new in self?.savedQueryChanged(old, to: new) }
        environment.selectedQueriesFolder = { [weak self] in self?.leftSidebar.queries.selectedFolder }
        leftSidebar.history.onInsert = { [weak self] text in self?.insertIntoEditor(text) }
        leftSidebar.history.onOpenInNewTab = { [weak self] text in self?.newQuery(text: text) }
        environment.onSchemaChange = { [weak self] in self?.sidebar.reload() }
        connectSearch()
        panes.onActivate = { [weak self] in self?.tabChanged() }
        // The first pane exists already (the window loaded its content); later ones come here.
        for pane in panes.panes { setUp(pane) }
        panes.onNewPane = { [weak self] pane in self?.setUp(pane) }
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
    /// Table tabs of every pane.
    var tableTabs: [TableTabViewController] { panes.allTabs.compactMap { $0 as? TableTabViewController } }
    /// Routine and new-object tabs of every pane.
    var definitionTabs: [DefinitionTabViewController] { panes.allTabs.compactMap { $0 as? DefinitionTabViewController } }
    /// Every tab that shows an object.
    var objectTabs: [any ObjectTab] { panes.allTabs.compactMap { $0 as? any ObjectTab } }

    private func setUp(_ pane: WorkspaceTabsController) {
        pane.onSelectionChange = { [weak self, weak pane] in
            guard let self, let pane else { return }
            // A pane whose selection changes by itself (a tab closing) doesn't take over.
            if pane === self.content { self.tabChanged() } else { self.onSessionChange?() }
        }
        pane.onNewTab = { [weak self, weak pane] in
            guard let self, let pane, let i = self.panes.index(of: pane) else { return }
            self.panes.activate(i, focus: false)
            self.newQueryTab(nil)
        }
        pane.onDoubleClickTab = { [weak pane] i in
            (pane?.tabs[safe: i] as? any ObjectTab)?.isPreview = false
        }
    }

    // MARK: - Opening

    /// Opens a table or view in the active pane, by `TabPlacement`'s rules: a tab already
    /// showing it is selected; `.preview` uses the pane's preview tab; `.newTab` always adds a
    /// tab. Staged changes stay with the workspace, so replacing a tab never asks. `focus` moves
    /// the keyboard focus into the tab.
    /// `mode` nil keeps an open tab on its side; new tabs then show the data.
    func open(_ object: DatabaseObject, intent: TabPlacement.Intent = .regular, mode: TableTabViewController.Mode? = nil,
              focus: Bool = true) {
        let pane = content
        let tabs = pane.tabs.map { TabPlacement.Tab(object: ($0 as? any ObjectTab)?.object, isPreview: $0.isPreview) }
        switch TabPlacement.place(object, intent: intent, in: tabs, selected: pane.selectedIndex) {
        case .select(let i):
            pane.select(i, focus: focus)
            if let mode { tableTab?.switchTo(mode, focus: focus) }
        case .promote(let i):
            (pane.tabs[i] as? any ObjectTab)?.isPreview = false
            pane.select(i, focus: focus)
            if let mode { tableTab?.switchTo(mode, focus: focus) }
        case .replacePreview(let i):
            (pane.tabs[i] as? any ObjectTab)?.endEditing()
            pane.replace(at: i, with: makeTab(object, mode: mode ?? .data, preview: true), focus: focus)
        case .insert(let i, let preview):
            pane.add(makeTab(object, mode: mode ?? .data, preview: preview), at: i, focus: focus)
        }
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

    /// Stages a new view, materialized view, function, procedure, and opens its editor; it's
    /// created on commit.
    func newDefinition(_ kind: DefinitionKind) {
        let dialect = connection.dialect
        guard !config.readOnly, dialect.supportsDefinitions(of: kind) else { return NSSound.beep() }
        let taken = Set(environment.catalog.objects.map { $0.ref.name.lowercased() })
        let schema = sidebar.schema
        let id = UUID()
        changes.perform("New \(kind.title.capitalized)", at: EditPlace(newDefinition: id, side: .definition)) {
            changes.addNewDefinition(id: id, kind: kind, schema: schema, dialect: dialect, taken: taken) { name in
                DefinitionTemplate.text(kind, name: name, schema: schema, dialect: dialect)
            }
        }
        openNewDefinition(id)
    }

    /// Selects the tab of a staged new object, or opens one.
    func openNewDefinition(_ id: UUID) {
        for (n, pane) in panes.panes.enumerated() {
            if let i = pane.tabs.firstIndex(where: { ($0 as? DefinitionTabViewController)?.newDefinitionID == id }) {
                panes.activate(n, focus: false)
                return pane.select(i, force: true)
            }
        }
        guard let d = changes.definition(id) else { return }
        content.add(DefinitionTabViewController(newDefinition: id, kind: d.kind, connection: connection, changes: changes))
    }

    /// Selects the tab of a staged new table, or opens one.
    func openNewTable(_ id: UUID) {
        for (n, pane) in panes.panes.enumerated() {
            if let i = pane.tabs.firstIndex(where: { ($0 as? TableTabViewController)?.newTableID == id }) {
                panes.activate(n, focus: false)
                return pane.select(i, force: true)
            }
        }
        content.add(configure(TableTabViewController(
            connection: connection, changes: changes, newTable: id, schema: sidebar.schema, pageSize: config.pageSize)))
    }

    @discardableResult
    func newQuery(text: String = "", saved: SavedQueries.Query? = nil, file: URL? = nil) -> QueryEditorViewController {
        queryCount += 1
        let editor = QueryEditorViewController(environment: environment, number: queryCount, text: text, savedQuery: saved,
                                               file: file)
        editor.results.dialect = connection.dialect
        editor.onEdit = { [weak self] in self?.onSessionChange?() }
        content.add(editor)
        return editor
    }

    /// File ▸ Open…: the SQL file in a new query tab, or the tab that already has it. The text is
    /// read as UTF-8, else Windows-1252; files over 20 MB are refused (dump import is M11).
    func openSQLFile(_ url: URL) {
        let url = url.standardizedFileURL
        for (n, pane) in panes.panes.enumerated() {
            if let i = pane.tabs.firstIndex(where: { ($0 as? QueryEditorViewController)?.fileURL?.standardizedFileURL == url }) {
                panes.activate(n, focus: false)
                return pane.select(i, force: true)
            }
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.sqlFileLimit else {
                throw CocoaError(.fileReadTooLarge, userInfo: [
                    NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), too large to edit. Files up to 20 MB open in a query tab.",
                ])
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            window?.makeKeyAndOrderFront(nil)
            newQuery(text: text, file: url)
        } catch {
            present(error, title: "Couldn't open “\(url.lastPathComponent)”", in: window)
        }
    }

    static let sqlFileLimit = 20 * 1024 * 1024

    func openSavedQuery(_ query: SavedQueries.Query) {
        for (n, pane) in panes.panes.enumerated() {
            if let i = pane.tabs.firstIndex(where: { ($0 as? QueryEditorViewController)?.savedQuery?.url == query.url }) {
                panes.activate(n, focus: false)
                return pane.select(i, force: true)
            }
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
        for case let editor as QueryEditorViewController in panes.allTabs where editor.savedQuery?.url == old.url {
            editor.savedQueryChanged(to: new)
        }
    }

    func tabChanged() {
        inspector.source = tableTab?.active as? InspectorSource
        let table = tableTab?.table
        let definitionTab = content.current as? DefinitionTabViewController
        if let id = tableTab?.newTableID {
            sidebar.reveal(newTable: id)
        } else if let definitionTab {
            if let id = definitionTab.newDefinitionID { sidebar.reveal(newDefinition: id) } else { sidebar.reveal(definitionTab.object) }
        } else {
            sidebar.reveal(table)
        }
        if let object = definitionTab?.object {
            subtitle = "\(object.ref) — \(config.shortSummary)"
        } else if let table, tableTab?.newTableID == nil {
            subtitle = "\(table) — \(config.shortSummary)"
        } else if let editor = queryController {
            subtitle = "\(editor.tabItem.title) — \(config.shortSummary)"
        } else {
            subtitle = config.shortSummary
        }
        if !isNavigating, let tab = content.current { history.visit(NavigationPlace(tab)) }
        onSessionChange?()
    }

    /// What the title shows under the connection's name: the open table or query, and the
    /// connection's summary.
    private var subtitle: String {
        get { titleView.subtitle }
        set {
            titleView.subtitle = newValue
            window?.subtitle = newValue
        }
    }

    private lazy var titleView = WorkspaceTitleView(config)

    // MARK: - Staged changes

    @objc private func stagedChangesChanged() {
        window?.isDocumentEdited = !changes.isEmpty
        sidebar.stagedChangesChanged()
        // A new table or object that's no longer staged (discarded, deleted, undone) closes its tab.
        for tab in tableTabs {
            if let id = tab.newTableID, changes.newTable(id) == nil { closeWithoutAsking(tab) }
        }
        for tab in definitionTabs {
            if let id = tab.newDefinitionID, changes.definition(id) == nil, !tab.isAwaitingCommit { closeWithoutAsking(tab) }
        }
        for pane in panes.panes { pane.refreshTabItems() }
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
        case .definition:
            if let id = place.newDefinition {
                if changes.definition(id) != nil { openNewDefinition(id) }
            } else if let object = place.objects.first {
                open(object, intent: .preview, mode: object.kind.isRelation ? .definition : nil)
            }
        case .data, .structure:
            let mode: TableTabViewController.Mode = place.side == .data ? .data : .structure
            if let id = place.newTable {
                guard changes.newTable(id) != nil else { return }
                openNewTable(id)
            } else if let table = place.table {
                open(DatabaseObject(table, kind: place.kind), intent: .preview, mode: mode)
            }
            switch mode {
            case .data: tableTab?.data?.restoreSelection(place)
            case .structure: tableTab?.structure?.restoreSelection(place)
            case .definition: break
            }
        }
    }

    func closeWithoutAsking(_ tab: any WorkspaceTab) {
        if let pane = panes.pane(of: tab), let i = pane.index(of: tab) { pane.close(i) }
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
        connection.statementLog?.observe(nil)
        // Dragging the divider can hide the right sidebar too.
        UserDefaults.standard.set(isInspectorVisible, forKey: Self.inspectorVisibleKey)
        for pane in panes.panes { pane.closeAll() }
        panes.tearDown()
        picker?.close()
        diagram?.stop()
        diagram?.close()
        leftSidebar.search.stop()
        let connection = connection
        Task { await connection.close() }
        onClose?()
    }

    // MARK: - Actions

    /// ⌘R: reads the items and open tables again. Staged changes stay.
    @objc func reloadWorkspace(_ sender: Any?) {
        for tab in objectTabs { tab.endEditing() }
        sidebar.reload()
        for tab in objectTabs { tab.reload() }
    }

    @objc func focusItemFilter(_ sender: Any?) {
        leftSidebar.show(.items)
        sidebar.focusFilter()
    }

    @objc func newQueryTab(_ sender: Any?) {
        newQuery()
    }

    /// ⌘W closes the selected tab. An empty pane closes (unless it's the only one); with no
    /// tabs left the window closes.
    @objc func closeTab(_ sender: Any?) {
        guard let i = content.selectedIndex else {
            if panes.panes.count > 1 { return panes.remove(at: panes.activeIndex) }
            window?.performClose(sender)
            return
        }
        content.close(i)
    }

    // MARK: - Panes

    /// ⇧⌘D: a new pane to the right of the active one, showing the same table (in a regular
    /// tab, on the same side) or a new query tab.
    @objc func splitPaneRight(_ sender: Any?) {
        let current = content.current
        (current as? any ObjectTab)?.endEditing()
        let pane = panes.addPane()
        if let tab = current as? DefinitionTabViewController {
            if let object = tab.object { pane.add(makeTab(object, mode: .data, preview: false)) }
        } else if let tab = current as? TableTabViewController {
            if let id = tab.newTableID {
                pane.add(configure(TableTabViewController(
                    connection: connection, changes: changes, newTable: id, schema: tab.table.schema, pageSize: config.pageSize)))
            } else if let object = tab.object {
                pane.add(makeTab(object, mode: tab.mode, preview: false))
            }
        } else if current is QueryEditorViewController {
            newQuery()
        }
        tabChanged()
        if pane.tabs.isEmpty { window?.makeFirstResponder(pane.strip) }
    }

    /// ⌥⌘] / ⌥⌘[: the next or previous pane becomes active.
    @objc func selectNextPane(_ sender: Any?) { activatePane(by: 1) }
    @objc func selectPreviousPane(_ sender: Any?) { activatePane(by: -1) }

    private func activatePane(by delta: Int) {
        let n = panes.panes.count
        guard n > 1 else { return NSSound.beep() }
        panes.activate((panes.activeIndex + delta + n) % n, focus: true)
    }

    // MARK: - Back and forward

    /// ⌃⌘←: the tab shown before, reopening its table if the tab was closed.
    @objc func goBack(_ sender: Any?) { navigate { $0.goBack(where: canShow) } }
    /// ⌃⌘→
    @objc func goForward(_ sender: Any?) { navigate { $0.goForward(where: canShow) } }

    private func navigate(_ step: (inout NavigationHistory<NavigationPlace>) -> NavigationPlace?) {
        guard let place = step(&history) else { return NSSound.beep() }
        isNavigating = true
        defer { isNavigating = false }
        if let (n, i) = locate(place) {
            panes.activate(n, focus: false)
            content.select(i, force: true)
        } else if let object = place.object {
            open(object, intent: .preview)
        }
        // A reopened table is a new tab; it stands for the place from now on.
        if let tab = content.current { history.replaceCurrent(with: NavigationPlace(tab)) }
        tabChanged()
    }

    /// Back / Forward stop offering tables that were dropped.
    func forgetHistory(of tables: Set<TableRef>) {
        history.removeAll { $0.object.map { tables.contains($0.ref) } ?? false }
    }

    /// The pane and tab index still showing `place`.
    private func locate(_ place: NavigationPlace) -> (Int, Int)? {
        for (n, pane) in panes.panes.enumerated() {
            if let i = pane.tabs.firstIndex(where: { NavigationPlace($0) == place }) { return (n, i) }
        }
        return nil
    }

    /// A tab that's still open, or a table that can open again.
    private func canShow(_ place: NavigationPlace) -> Bool {
        locate(place) != nil || place.object != nil
    }

    @objc func selectNextTab(_ sender: Any?) { content.selectNext(by: 1) }

    @objc func selectPreviousTab(_ sender: Any?) { content.selectNext(by: -1) }

    /// ⌘1…⌘9; ⌘9 is always the last tab.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, !content.tabs.isEmpty else { return }
        content.select(tag == 9 ? content.tabs.count - 1 : tag - 1)
    }

    @objc func showQueryHistory(_ sender: Any?) { leftSidebar.show(.history) }

    // MARK: - Search in Database

    private func connectSearch() {
        let search = leftSidebar.search
        search.tables = { [weak self] in self?.environment.catalog.objects ?? [] }
        search.openSession = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.openLoggedSession()
        }
        search.onOpenRows = { [weak self] object, conditions, intent in
            guard let self else { return }
            self.open(object, intent: intent, mode: .data, focus: intent != .preview)
            self.tableTab?.data?.showRows(matching: conditions, focus: intent != .preview)
        }
        sidebar.onSearchInDatabase = { [weak self] in self?.searchInDatabase(nil) }
        sidebar.onShowDiagram = { [weak self] in self?.showDiagram(nil) }
    }

    /// Show Diagram: the listed schema's tables and foreign keys in a window of their own, read
    /// on a session of its own where the connection can open one.
    @objc func showDiagram(_ sender: Any?) {
        let tables = environment.catalog.objects.filter { $0.kind == .table }.map(\.ref)
        let schema = sidebar.schema
        if diagram?.schema != schema {
            diagram?.stop()
            diagram?.close()
            diagram = nil
        }
        if let diagram {
            diagram.showWindow(nil)
            return
        }
        let controller = DiagramWindowController(title: [config.displayName, schema].compactMap { $0 }.joined(separator: " — "),
                                                 schema: schema)
        controller.onOpen = { [weak self] object in
            self?.window?.makeKeyAndOrderFront(nil)
            self?.open(object, intent: .regular)
        }
        let connection = connection
        if openSession != nil {
            controller.load(tables, on: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.openLoggedSession()
            }, closeAfter: true)
        } else {
            controller.load(tables, on: { connection }, closeAfter: false)
        }
        diagram = controller
        controller.showWindow(nil)
    }

    /// A session of its own (Search in Database, Show Diagram) whose statements go to the query
    /// log with the workspace's.
    func openLoggedSession() async throws -> any DatabaseConnection {
        guard let openSession else { throw DatabaseError("No session can be opened.") }
        let session = try await openSession()
        queryLog.follow(session)
        return session
    }

    /// Search in Database…: the sidebar's Search pane, ready to type.
    @objc func searchInDatabase(_ sender: Any?) {
        if split.splitViewItems.first?.isCollapsed == true { split.splitViewItems.first?.animator().isCollapsed = false }
        leftSidebar.show(.search)
        leftSidebar.search.focus()
    }
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

    private lazy var safetyMenu = makeSafetyMenu()

    /// The Safe Mode button's menu, under the button.
    @objc private func showSafetyMenu(_ sender: Any?) {
        guard let window, let frame = window.contentView?.superview else { return }
        // A click: under the button. Otherwise (accessibility, keyboard): at the pointer.
        let point: NSPoint
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.window == window {
            point = frame.convert(event.locationInWindow, from: nil)
        } else {
            point = frame.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        }
        var view = frame.hitTest(point)
        while let v = view, !(v is NSControl) { view = v.superview }
        if let button = view {
            let below = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
            safetyMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: below), in: button)
        } else {
            safetyMenu.popUp(positioning: nil, at: point, in: frame)
        }
    }

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
        guard let item = toolbarItem(Self.safetyItem) else { return }
        let level = safety.level
        let symbol = config.readOnly ? "lock.fill"
            : level == .silent ? "shield" : level.requiresPassword ? "lock.shield" : "exclamationmark.shield"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Safe mode")
        item.label = "Safe Mode"
        item.toolTip = "Safe mode: \(level.title)" + (config.readOnly ? " · read-only connection" : "")
        for menuItem in safetyMenu.items where menuItem.action == #selector(changeSafeMode(_:)) {
            menuItem.state = menuItem.tag == SafeMode.allCases.firstIndex(of: level) ? .on : .off
        }
    }

    // MARK: - Toolbar

    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let changesItem = NSToolbarItem.Identifier("changes")
    private static let safetyItem = NSToolbarItem.Identifier("safety")
    private static let titleItem = NSToolbarItem.Identifier("title")
    /// Changes, Safe Mode and Reload, side by side as one group.
    private static let actionsItem = NSToolbarItem.Identifier("actions")
    private static let inspectorToggleItem = NSToolbarItem.Identifier("rightSidebar")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.titleItem, .flexibleSpace, Self.actionsItem,
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
            // On macOS 26 a pull-down gets a glass capsule of its own; as a plain button that
            // opens the menu it shares one with Changes and Reload.
            let item: NSToolbarItem
            if #available(macOS 26.0, *) {
                item = NSToolbarItem(itemIdentifier: id)
                item.isBordered = true
                item.target = self
                item.action = #selector(showSafetyMenu(_:))
            } else {
                let pullDown = NSMenuToolbarItem(itemIdentifier: id)
                pullDown.menu = safetyMenu
                pullDown.showsIndicator = true
                item = pullDown
            }
            DispatchQueue.main.async { [weak self] in self?.updateSafetyItem() }
            item.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Safe mode")
            item.label = "Safe Mode"
            return item
        case Self.actionsItem:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [Self.changesItem, Self.safetyItem, Self.reloadItem].compactMap {
                self.toolbar(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: flag)
            }
            group.label = "Actions"
            return group
        case Self.titleItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = titleView
            item.label = config.displayName
            item.isBordered = false
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

    /// The toolbar's item `id`, inside a group or not.
    func toolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        for item in window?.toolbar?.items ?? [] {
            for sub in (item as? NSToolbarItemGroup)?.subitems ?? [item] where sub.itemIdentifier == id { return sub }
        }
        return nil
    }

    /// The Changes item: an icon with the count as a badge, greyed out with nothing staged.
    func updateChangesItem() {
        guard let item = toolbarItem(Self.changesItem) else { return }
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

    // MARK: - Running queries

    /// Connection ▸ Running Queries…: the server's sessions, on a session of the sheet's own.
    @objc func showRunningQueries(_ sender: Any?) {
        guard ServerSessions.isSupported(connection), let openSession, let window, window.attachedSheet == nil else {
            return NSSound.beep()
        }
        let connection = connection
        Task {
            let own = await ServerSessions.ownID(of: connection)
            let sheet = RunningQueriesSheet(open: openSession, workspaceID: own)
            runningQueries = sheet
            sheet.begin(on: window)
        }
    }

    // MARK: - Query log

    /// ⌃⌘C, or View ▸ Sidebars ▸ Query Log.
    @objc func toggleQueryLog(_ sender: Any?) { center.toggleLog() }

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

/// The workspace's title in the toolbar: the connection's name with its tag as a badge after it,
/// and the subtitle under them.
final class WorkspaceTitleView: NSView {
    private let name: NSTextField
    private let detail = NSTextField(labelWithString: "")

    var subtitle: String {
        get { detail.stringValue }
        set { detail.stringValue = newValue }
    }

    init(_ config: ConnectionConfig) {
        name = NSTextField(labelWithString: config.displayName)
        super.init(frame: .zero)
        name.font = .boldSystemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.stringValue = config.shortSummary

        let top = NSStackView(views: [name])
        top.spacing = 6
        if let badge = ConnectionBadge(config) { top.addArrangedSubview(badge) }
        let stack = NSStackView(views: [top, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        // The toolbar's items keep their room; the title and subtitle are cut short instead.
        for v in [top, stack] { v.setClippingResistancePriority(.defaultLow, for: .horizontal) }
        addSubview(stack)
        stack.pin(to: self)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A tab the window showed, for Back / Forward: the tab, and the table it showed then.
struct NavigationPlace: Hashable, Sendable {
    var tab: UUID
    var object: DatabaseObject?

    @MainActor
    init(_ tab: any WorkspaceTab) {
        self.tab = tab.tabID
        object = (tab as? any ObjectTab)?.object
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
