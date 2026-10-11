import AppCore
import AppKit
import DBKit

/// A table's rows in an editable grid.
///
/// The grid shows one page of the table (filter, sort and page from `query`). Within the page
/// the row cache fills in whatever is on screen, so even "all rows" stays fast. Edits are staged
/// in `edits` and drawn over the loaded rows until Commit (⌘S) or Discard (⇧⌘⌫). While edits
/// are staged, anything that would load different rows asks to commit or discard first.
@MainActor
final class TableDataViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuItemValidation, TabulaActions
{
    let table: TableRef
    let kind: ObjectKind
    var onTabItemChange: (() -> Void)?
    /// Why the grid can't be edited (a view, a read-only connection), or nil.
    let readOnlyReason: String?
    var isEditable: Bool { readOnlyReason == nil }

    private let connection: any DatabaseConnection
    let grid = DataGrid()
    let filterBar = FilterBar()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pageButton = NSButton(title: "", target: nil, action: nil)
    private let pageControl = NSSegmentedControl()
    private let changesButton = NSButton(title: "", target: nil, action: nil)
    private let addRowButton = NSButton(title: "Row", target: nil, action: nil)
    private let filtersButton = NSButton(title: "Filters", target: nil, action: nil)

    private(set) var browser: TableBrowser?
    private(set) var cache: RowCache?
    private(set) var edits = StagedEdits(baseRowCount: 0)
    private(set) var query: GridQuery
    /// Rows matching the filter, across all pages.
    private(set) var total = 0
    private var loadTask: Task<Void, Never>?
    private var isCommitting = false
    private var columnsSized = false
    private var lastSelection = IndexSet()
    private var popover: NSPopover?
    private var stack = NSStackView()

    /// The inline edit in progress: grid row, model column and the text it started from.
    private var editing: (row: Int, column: Int, start: String)?

    /// Copying more rows than this asks the user to narrow the selection.
    private static let copyLimit = 100_000

    init(connection: any DatabaseConnection, object: DatabaseObject, readOnlyConnection: Bool, pageSize: Int?) {
        self.connection = connection
        self.table = object.ref
        self.kind = object.kind
        self.readOnlyReason = readOnlyConnection ? "The connection is read-only."
            : object.kind == .table ? nil : "Only tables can be edited."
        self.query = GridQuery(page: Paging(pageSize: pageSize))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasPendingEdits: Bool { !edits.isEmpty || editing != nil }

    // MARK: - Layout

    override func loadView() {
        grid.style = .plain
        grid.rowSizeStyle = .custom
        grid.rowHeight = 22
        grid.intercellSpacing = NSSize(width: 1, height: 0)
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.usesAlternatingRowBackgroundColors = true
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.allowsMultipleSelection = true
        grid.allowsColumnReordering = true
        grid.allowsColumnResizing = true
        grid.focusRingType = .none
        grid.dataSource = self
        grid.delegate = self
        grid.target = self
        grid.doubleAction = #selector(gridDoubleClicked(_:))
        grid.menu = makeContextMenu()
        grid.onEdit = { [weak self] in self?.editFocusedCell() }
        grid.onFocusChange = { [weak self] previous in self?.focusMoved(from: previous) }
        grid.setValueMenu = { [weak self] in self?.makeSetValueMenu() }

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRowsChanged), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRowsChanged), name: NSView.frameDidChangeNotification,
            object: scroll.contentView)

        filterBar.isHidden = true
        filterBar.onApply = { [weak self] filter in self?.applyFilter(filter) }
        filterBar.onExit = { [weak self] in self?.toggleFilters(nil) }

        stack = NSStackView(views: [filterBar, separator(), scroll, separator(), makeBottomBar()])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.arrangedSubviews[1].isHidden = true  // separator under the filter bar
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        // The window's content runs under the toolbar; start below it.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeBottomBar() -> NSView {
        addRowButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add row")
        addRowButton.imagePosition = .imageLeading
        addRowButton.target = self
        addRowButton.action = #selector(addRow(_:))
        addRowButton.toolTip = "Add a row (⌘I)"
        addRowButton.isEnabled = isEditable
        filtersButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filters")
        filtersButton.imagePosition = .imageLeading
        filtersButton.setButtonType(.pushOnPushOff)
        filtersButton.target = self
        filtersButton.action = #selector(toggleFilters(_:))
        filtersButton.toolTip = "Show or hide filters (⌘F)"
        changesButton.target = self
        changesButton.action = #selector(previewChanges(_:))
        changesButton.toolTip = "Review the SQL for staged changes (⇧⌘P)"
        changesButton.contentTintColor = .systemOrange
        changesButton.isHidden = true
        pageButton.target = self
        pageButton.action = #selector(showPaging(_:))
        pageButton.toolTip = "Page size and offset"
        pageControl.segmentCount = 2
        pageControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous page"), forSegment: 0)
        pageControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next page"), forSegment: 1)
        pageControl.setToolTip("Previous page (⌘←)", forSegment: 0)
        pageControl.setToolTip("Next page (⌘→)", forSegment: 1)
        pageControl.trackingMode = .momentary
        pageControl.target = self
        pageControl.action = #selector(pageControlClicked(_:))
        for b in [addRowButton, filtersButton, changesButton, pageButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        pageControl.controlSize = .small

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [addRowButton, filtersButton, statusLabel, changesButton, pageButton, pageControl])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return bar
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // MARK: - Loading

    /// Stops all loading. Called when the table is closed.
    func stop() {
        loadTask?.cancel()
        cache?.cancel()
    }

    /// Re-reads columns, count and the current page. Staged edits are dropped: callers ask first.
    func reload() {
        stop()
        abortInlineEdit()
        showStatus("Loading…")
        loadTask = Task {
            do {
                let browser = try await TableBrowser.open(table, on: connection)
                guard !Task.isCancelled else { return }
                if browser.columns != self.browser?.columns { install(browser.columns) }
                self.browser = browser
                try await loadPage(recount: true, scrollToTop: false)
            } catch {
                guard !Task.isCancelled else { return }
                cache = nil
                edits = StagedEdits(baseRowCount: 0)
                grid.reloadData()
                showError(error)
            }
        }
    }

    /// Loads the page `query` describes, recounting rows first when the filter changed.
    private func reloadPage(recount: Bool, scrollToTop: Bool = true) {
        stop()
        abortInlineEdit()
        loadTask = Task {
            do {
                try await loadPage(recount: recount, scrollToTop: scrollToTop)
            } catch {
                guard !Task.isCancelled else { return }
                showError(error)
            }
        }
    }

    private func loadPage(recount: Bool, scrollToTop: Bool) async throws {
        guard let browser else { return }
        if recount || cache == nil {
            showStatus("Counting rows…")
            let n = try await browser.count(filter: query.filter)
            guard !Task.isCancelled else { return }
            total = n
        }
        // A page past the end (rows were deleted, or a narrower filter): go to the last one.
        if let size = query.page.pageSize, query.page.offset >= total, total > 0 {
            query.page.offset = (total - 1) / size * size
        }
        let cache = RowCache(rowCount: query.page.rows(total: total).count, fetch: browser.fetcher(query))
        cache.onLoad = { [weak self] rows in self?.rowsLoaded(rows) }
        cache.onError = { [weak self] error in self?.showError(error) }
        self.cache = cache
        edits = StagedEdits(baseRowCount: cache.rowCount)
        lastSelection = []
        grid.reloadData()
        if scrollToTop { grid.scrollRowToVisible(0) }
        showStatus(query.filter == nil ? "" : "Filtered")
        updateBar()
        visibleRowsChanged()
    }

    private func install(_ columns: [ColumnInfo]) {
        for c in grid.tableColumns.reversed() { grid.removeTableColumn(c) }
        for (i, info) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            column.title = info.name
            var tip = info.typeName.isEmpty ? info.name : "\(info.name) — \(info.typeName)"
            if info.primaryKeyPosition != nil { tip += " (primary key)" }
            column.headerToolTip = tip + "\nClick to sort"
            column.minWidth = 40
            column.maxWidth = 2000
            column.width = min(320, max(70, GridCell.width(of: info.name, header: true)))
            grid.addTableColumn(column)
        }
        let names = columns.map(\.name)
        query.sort.removeAll { !names.contains($0.column) }
        if query.filter != nil, filterBar.columns != names { query.filter = nil }
        filterBar.setColumns(names)
        grid.focusedColumn = grid.tableColumns.first?.identifier
        columnsSized = false
        updateSortIndicators()
    }

    @objc private func visibleRowsChanged() {
        guard let cache else { return }
        let visible = grid.rows(in: grid.visibleRect)
        let end = min(visible.location + visible.length, cache.rowCount)
        cache.setVisibleRows(min(visible.location, end)..<end)
    }

    private func rowsLoaded(_ rows: Range<Int>) {
        if !columnsSized { sizeColumnsToContent(rows) }
        let visible = grid.rows(in: grid.visibleRect)
        let shown = rows.clamped(to: visible.location..<(visible.location + visible.length))
        guard !shown.isEmpty else { return }
        refreshCells(IndexSet(integersIn: shown))
    }

    /// Widens columns to fit the first rows that arrive, once per table.
    private func sizeColumnsToContent(_ rows: Range<Int>) {
        guard let cache else { return }
        columnsSized = true
        let sample = rows.prefix(200).compactMap(cache.row(at:))
        for column in grid.tableColumns {
            guard let i = Int(column.identifier.rawValue) else { continue }
            let widest = sample.lazy.map { GridCell.width(of: CellText.display($0[i]) ?? "NULL", header: false) }.max() ?? 0
            column.width = min(320, max(column.width, widest))
        }
    }

    // MARK: - Status

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
    }

    private func showError(_ error: any Error) {
        statusLabel.stringValue = "\(error)"
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = "\(error)"
    }

    private func updateBar() {
        pageButton.title = cache == nil ? "" : query.page.describe(total: total)
        pageControl.setEnabled(query.page.previous != nil, forSegment: 0)
        pageControl.setEnabled(query.page.next(total: total) != nil, forSegment: 1)
        pageControl.isHidden = query.page.pageSize == nil
        filtersButton.state = filterBar.isHidden ? .off : .on
        filtersButton.contentTintColor = query.filter == nil ? nil : .controlAccentColor

        let parts = [
            (edits.updatedRowCount, "edited"), (edits.insertedRowCount, "new"), (edits.deleted.count, "deleted"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        changesButton.isHidden = parts.isEmpty
        changesButton.title = parts.joined(separator: ", ")
    }

    /// Column titles are the column names.
    private func updateSortIndicators() {
        let sort = query.sort.first
        for column in grid.tableColumns {
            let image = sort?.column == column.title
                ? NSImage(named: sort!.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
            grid.setIndicatorImage(image, in: column)
        }
        grid.highlightedTableColumn = sort.flatMap { s in grid.tableColumns.first { $0.title == s.column } }
    }

    // MARK: - Grid data

    func numberOfRows(in tableView: NSTableView) -> Int { cache == nil ? 0 : edits.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
        let state = edits.state(of: row)
        let change = edits.change(row: row, column: column)
        cell.show(
            content(row: row, column: column),
            edited: change != nil && state != .inserted,
            focused: grid.selectedRowIndexes.contains(row) && grid.focusedColumn == tableColumn.identifier,
            struckOut: state == .deleted)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: GridRowView.identifier, owner: nil) as? GridRowView ?? GridRowView()
        view.state = edits.state(of: row)
        return view
    }

    /// What a cell shows: its staged change, else the loaded value.
    private func content(row: Int, column: Int) -> CellContent {
        switch edits.change(row: row, column: column) {
        case .value(let v)?: return .value(v)
        case .defaultValue?: return .defaultValue
        case nil:
            if edits.isInserted(row) { return .defaultValue }
            guard let values = cache?.row(at: row), column < values.count else { return .pending }
            return .value(values[column])
        }
    }

    /// The row as shown, for copying and duplicating. Nil while it hasn't loaded.
    private func shownValues(row: Int) -> [DBValue?]? {
        guard let columns = browser?.columns else { return nil }
        if !edits.isInserted(row), cache?.row(at: row) == nil { return nil }
        return columns.indices.map { i in
            if case .value(let v) = content(row: row, column: i) { return v }
            return nil
        }
    }

    /// Redraws cells (and row tints) without disturbing an inline edit.
    private func refreshCells(_ rows: IndexSet, columns: IndexSet? = nil) {
        guard editing == nil else { return }
        let rows = rows.filteredIndexSet { $0 < grid.numberOfRows }
        for row in rows { (grid.rowView(atRow: row, makeIfNecessary: false) as? GridRowView)?.state = edits.state(of: row) }
        grid.reloadData(forRowIndexes: rows, columnIndexes: columns ?? IndexSet(integersIn: 0..<grid.numberOfColumns))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = grid.selectedRowIndexes
        if let c = grid.focusedColumnIndex { refreshCells(lastSelection.union(selected), columns: [c]) }
        lastSelection = selected
    }

    private func focusMoved(from previous: NSUserInterfaceItemIdentifier?) {
        var columns = IndexSet()
        if let previous, case let i = grid.column(withIdentifier: previous), i >= 0 { columns.insert(i) }
        if let i = grid.focusedColumnIndex { columns.insert(i) }
        refreshCells(grid.selectedRowIndexes, columns: columns)
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard browser != nil else { return }
        let name = tableColumn.title
        resolvePendingEdits(before: "Sorting") { [self] in
            query.cycleSort(name)
            query.page.offset = 0
            updateSortIndicators()
            reloadPage(recount: false)
        }
    }

    // MARK: - Filtering and paging

    private func applyFilter(_ filter: Filter?) {
        guard filter != query.filter else { return reloadPageIfFilterUnchanged() }
        resolvePendingEdits(before: "Filtering") { [self] in
            query.filter = filter
            query.page.offset = 0
            reloadPage(recount: true)
        }
    }

    /// Applying the filter that is already applied refreshes the rows.
    private func reloadPageIfFilterUnchanged() {
        resolvePendingEdits(before: "Refreshing") { [self] in reloadPage(recount: true) }
    }

    @objc func toggleFilters(_ sender: Any?) {
        filterBar.isHidden.toggle()
        stack.arrangedSubviews[1].isHidden = filterBar.isHidden
        if filterBar.isHidden {
            view.window?.makeFirstResponder(grid)
        } else {
            filterBar.focus()
        }
        updateBar()
    }

    private func go(to page: Paging) {
        guard page != query.page else { return }
        resolvePendingEdits(before: "Changing page") { [self] in
            query.page = page
            reloadPage(recount: false)
        }
    }

    @objc func nextPage(_ sender: Any?) {
        if let next = query.page.next(total: total) { go(to: next) }
    }

    @objc func previousPage(_ sender: Any?) {
        if let previous = query.page.previous { go(to: previous) }
    }

    @objc private func pageControlClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? previousPage(sender) : nextPage(sender)
    }

    @objc private func showPaging(_ sender: NSButton) {
        let controller = PagingController(query.page)
        controller.onGo = { [weak self] page in
            self?.popover?.close()
            self?.go(to: page)
        }
        present(controller, from: sender, edge: .maxY)
    }

    /// Shows all rows in one virtual page. For the scroll benchmark.
    func showAllRows() {
        query.page = Paging(pageSize: nil)
        reloadPage(recount: false)
    }

    // MARK: - Pending edits

    /// Runs `proceed` once there's nothing staged, asking to commit or discard if there is.
    func resolvePendingEdits(before action: String, then proceed: @escaping () -> Void) {
        endInlineEdit()
        guard !edits.isEmpty else { return proceed() }
        let alert = NSAlert()
        alert.messageText = "Commit changes to \(table.name)?"
        alert.informativeText = "\(action) reloads the rows, so staged changes (\(changesButton.title)) must be committed or discarded first."
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.commit(then: proceed)
            case .alertSecondButtonReturn:
                self.discardStaged()
                proceed()
            default: break
            }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: - Commit, discard, preview

    @objc func commitChanges(_ sender: Any?) {
        endInlineEdit()
        guard !edits.isEmpty else { return NSSound.beep() }
        commit(then: nil)
    }

    private func commit(then proceed: (() -> Void)?) {
        guard let browser, !isCommitting else { return }
        isCommitting = true
        popover?.close()
        let edits = edits
        showStatus("Committing…")
        Task {
            defer { isCommitting = false }
            do {
                try await browser.commit(edits)
                if let proceed {
                    self.edits.discard()
                    proceed()
                } else {
                    reloadPage(recount: true, scrollToTop: false)
                }
            } catch {
                showStatus("")
                showCommitError(error)
            }
        }
    }

    private func showCommitError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't commit changes"
        var info = "\(error)"
        if let sql = (error as? DatabaseError)?.sql { info += "\n\n\(sql)" }
        alert.informativeText = info + "\n\nNothing was changed. Your edits are still staged."
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc func discardChanges(_ sender: Any?) {
        abortInlineEdit()
        guard !edits.isEmpty else { return NSSound.beep() }
        discardStaged()
    }

    private func discardStaged() {
        popover?.close()
        edits.discard()
        grid.reloadData()
        updateBar()
    }

    @objc func previewChanges(_ sender: Any?) {
        endInlineEdit()
        guard let browser, !edits.isEmpty else { return NSSound.beep() }
        let note = browser.hasPrimaryKey ? nil
            : "\(table.name) has no primary key, so rows are matched on every column. If a statement would change no row or more than one, nothing is committed."
        let controller = ChangesPreviewController(statements: browser.preview(edits), note: note)
        controller.onCommit = { [weak self] in self?.commitChanges(nil) }
        controller.onDiscard = { [weak self] in self?.discardChanges(nil) }
        let anchor: NSView = changesButton.isHidden ? pageButton : changesButton
        present(controller, from: anchor, edge: .maxY, size: NSSize(width: 640, height: 320))
    }

    private func present(_ controller: NSViewController, from anchor: NSView, edge: NSRectEdge, size: NSSize? = nil, at rect: NSRect? = nil) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = controller
        if let size { p.contentSize = size }
        p.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: edge)
        popover = p
    }

    // MARK: - Editing cells

    @objc private func gridDoubleClicked(_ sender: Any?) {
        let row = grid.clickedRow, column = grid.clickedColumn
        guard row >= 0, column >= 0 else { return }
        beginEditing(row: row, displayColumn: column)
    }

    private func editFocusedCell() {
        guard grid.selectedRow >= 0, let c = grid.focusedColumnIndex else { return NSSound.beep() }
        beginEditing(row: grid.selectedRow, displayColumn: c)
    }

    private func beginEditing(row: Int, displayColumn: Int) {
        guard browser != nil, let column = Int(grid.tableColumns[displayColumn].identifier.rawValue) else { return }
        if let readOnlyReason { return refuse(readOnlyReason) }
        guard edits.state(of: row) != .deleted else { return refuse("This row is marked for deletion.") }
        let text: String
        switch content(row: row, column: column) {
        case .pending: return NSSound.beep()
        case .defaultValue: text = ""
        case .value(let v):
            guard CellInput.isEditableAsText(v) else { return refuse("Binary values can't be edited as text. Use Set Value to change them.") }
            text = CellInput.editingText(v)
        }
        grid.focusedColumn = grid.tableColumns[displayColumn].identifier
        grid.scrollRowToVisible(row)
        grid.scrollColumnToVisible(displayColumn)

        if text.contains(where: \.isNewline) || text.count > CellText.maxLength {
            let editor = CellTextEditorController(text: text)
            editor.onSave = { [weak self] new in
                self?.popover?.close()
                if new != text { self?.stage(new, row: row, column: column) }
            }
            editor.onCancel = { [weak self] in self?.popover?.close() }
            let cell = grid.frameOfCell(atColumn: displayColumn, row: row)
            present(editor, from: grid, edge: .maxY, size: NSSize(width: 480, height: 260), at: cell)
            return
        }
        guard let cell = grid.view(atColumn: displayColumn, row: row, makeIfNecessary: true) as? GridCell else { return }
        editing = (row, column, text)
        cell.prepareForEditing(text, delegate: self)
        grid.editColumn(displayColumn, row: row, with: nil, select: true)
    }

    private func refuse(_ message: String) {
        NSSound.beep()
        showStatus(message)
    }

    /// Stages what was typed into a cell.
    private func stage(_ text: String, row: Int, column: Int) {
        guard let browser else { return }
        let value = CellInput.parse(text, typeName: browser.columns[column].typeName)
        edits.set(.value(value), row: row, column: column, original: cache?.row(at: row))
        refreshCells([row])
        updateBar()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let edit = editing else { return }
        editing = nil
        if field.stringValue != edit.start { stage(field.stringValue, row: edit.row, column: edit.column) }
        else { refreshCells([edit.row]) }
        view.window?.makeFirstResponder(grid)
        // Tab moves along the row, editing the next cell.
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement == .tab || movement == .backtab {
            grid.moveFocus(by: movement == .tab ? 1 : -1)
            editFocusedCell()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), editing != nil else { return false }
        abortInlineEdit()
        return true
    }

    /// Ends an inline edit, keeping what was typed.
    private func endInlineEdit() {
        guard editing != nil else { return }
        view.window?.makeFirstResponder(grid)
    }

    /// Ends an inline edit, dropping what was typed.
    private func abortInlineEdit() {
        guard let edit = editing else { return }
        editing = nil
        let display = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(String(edit.column)))
        if display >= 0 { (grid.view(atColumn: display, row: edit.row, makeIfNecessary: false) as? GridCell)?.label.abortEditing() }
        view.window?.makeFirstResponder(grid)
        refreshCells([edit.row])
    }

    // MARK: - Row actions

    /// Rows the row actions apply to: the selection, or the clicked row from a context menu.
    private var targetRows: IndexSet {
        let clicked = grid.clickedRow
        if clicked >= 0, !grid.selectedRowIndexes.contains(clicked) { return [clicked] }
        return grid.selectedRowIndexes
    }

    @objc func addRow(_ sender: Any?) {
        guard isEditable, cache != nil, let browser else { return NSSound.beep() }
        endInlineEdit()
        let row = edits.addRow()
        grid.insertRows(at: [row])
        grid.selectRowIndexes([row], byExtendingSelection: false)
        // Start in the first column that isn't part of the key; keys are usually generated.
        let first = browser.columns.firstIndex { $0.primaryKeyPosition == nil } ?? 0
        let display = grid.column(withIdentifier: NSUserInterfaceItemIdentifier(String(first)))
        updateBar()
        if display >= 0 { beginEditing(row: row, displayColumn: display) }
    }

    @objc func duplicateRows(_ sender: Any?) {
        guard isEditable, let browser else { return NSSound.beep() }
        endInlineEdit()
        let key = Set(browser.columns.indices.filter { browser.columns[$0].primaryKeyPosition != nil })
        var added = IndexSet()
        for row in targetRows where edits.state(of: row) != .deleted {
            guard let values = shownValues(row: row) else { continue }
            var cells: [Int: CellChange] = [:]
            for (i, v) in values.enumerated() where !key.contains(i) {
                if let v { cells[i] = .value(v) }
            }
            added.insert(edits.addRow(cells))
        }
        guard !added.isEmpty else { return NSSound.beep() }
        grid.insertRows(at: added)
        grid.selectRowIndexes(added, byExtendingSelection: false)
        grid.scrollRowToVisible(added.last!)
        updateBar()
    }

    @objc func deleteRows(_ sender: Any?) {
        guard isEditable, cache != nil else { return NSSound.beep() }
        let rows = targetRows
        guard !rows.isEmpty else { return NSSound.beep() }
        abortInlineEdit()
        let before = edits.rowCount
        edits.delete(rows: rows, original: { [cache] in cache?.row(at: $0) })
        if edits.rowCount != before {
            grid.reloadData()
            grid.selectRowIndexes(IndexSet(rows.filter { $0 < edits.rowCount }), byExtendingSelection: false)
        } else {
            refreshCells(rows)
        }
        updateBar()
    }

    @objc func setNull(_ sender: Any?) { setFocusedCells(.value(.null)) }
    @objc func setEmpty(_ sender: Any?) { setFocusedCells(.value(.text(""))) }
    @objc func setDefault(_ sender: Any?) { setFocusedCells(.defaultValue) }

    /// Sets the cursor's column in every target row.
    private func setFocusedCells(_ change: CellChange) {
        guard isEditable, let display = grid.focusedColumnIndex,
              let column = Int(grid.tableColumns[display].identifier.rawValue) else { return NSSound.beep() }
        endInlineEdit()
        let rows = targetRows
        for row in rows where edits.state(of: row) != .deleted {
            edits.set(change, row: row, column: column, original: cache?.row(at: row))
        }
        refreshCells(rows)
        updateBar()
    }

    @objc func reloadCurrentTab(_ sender: Any?) {
        resolvePendingEdits(before: "Reloading") { [self] in reload() }
    }

    // MARK: - Menus

    private func makeSetValueMenu() -> NSMenu {
        let menu = NSMenu(title: "Set Value")
        for (title, action) in [("NULL", #selector(setNull(_:))), ("Empty String", #selector(setEmpty(_:))),
                                ("DEFAULT", #selector(setDefault(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let setValue = menu.addItem(withTitle: "Set Value", action: nil, keyEquivalent: "")
        setValue.submenu = makeSetValueMenu()
        menu.addItem(.separator())
        for (title, action) in [("Add Row", #selector(addRow(_:))), ("Duplicate", #selector(duplicateRows(_:))),
                                ("Delete", #selector(deleteRows(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Rows", action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload", action: #selector(reloadCurrentTab(_:)), keyEquivalent: "").target = self
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // ⌘←, ⌘→ and ⌘⌫ belong to a text field while one is being edited.
        let typing = view.window?.firstResponder is NSTextView
        let hasRows = !targetRows.isEmpty
        switch item.action {
        case #selector(copy(_:)): return hasRows
        case #selector(commitChanges(_:)), #selector(discardChanges(_:)), #selector(previewChanges(_:)):
            if item.action == #selector(commitChanges(_:)) { item.title = "Commit Changes" }
            return !edits.isEmpty || editing != nil
        case #selector(addRow(_:)): return isEditable && cache != nil
        case #selector(duplicateRows(_:)), #selector(setNull(_:)), #selector(setEmpty(_:)), #selector(setDefault(_:)):
            return isEditable && hasRows
        case #selector(deleteRows(_:)): return isEditable && hasRows && !typing
        case #selector(nextPage(_:)): return !typing && query.page.next(total: total) != nil
        case #selector(previousPage(_:)): return !typing && query.page.previous != nil
        case #selector(toggleFilters(_:)):
            item.title = filterBar.isHidden ? "Show Filters" : "Hide Filters"
            return true
        default: return true
        }
    }

    // MARK: - Copy

    /// Copies selected rows as tab-separated text, as shown (staged edits included), in the
    /// grid's current column order.
    @objc func copy(_ sender: Any?) {
        guard let cache, let first = targetRows.first, let last = targetRows.last else {
            NSSound.beep()
            return
        }
        guard last - first < Self.copyLimit else {
            let alert = NSAlert()
            alert.messageText = "Too many rows to copy"
            alert.informativeText = "Select fewer than \(Self.copyLimit.formatted(.number)) rows. Export arrives in a later version."
            if let window = view.window { alert.beginSheetModal(for: window) }
            return
        }
        let selection = targetRows
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        Task {
            do {
                // Load the span once so shownValues finds every base row.
                let baseEnd = min(last + 1, cache.rowCount)
                let span = first < baseEnd ? try await cache.rows(first..<baseEnd) : []
                let rows: [[DBValue]] = selection.compactMap { row in
                    if let shown = shownValues(row: row) { return shown.map { $0 ?? .null } }
                    guard row - first < span.count else { return nil }
                    return overlay(span[row - first], row: row)
                }
                let text = CellText.tsv(rows.map { row in order.map { row[$0] } })
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                showError(error)
            }
        }
    }

    /// A loaded row with its staged changes applied.
    private func overlay(_ values: [DBValue], row: Int) -> [DBValue] {
        values.indices.map { i in
            switch edits.change(row: row, column: i) {
            case .value(let v)?: v
            case .defaultValue?: .null
            case nil: values[i]
            }
        }
    }
}

extension TableDataViewController: WorkspaceTab {
    var tabItem: TabStrip.Item {
        TabStrip.Item(title: table.name, symbol: kind == .table ? "tablecells" : "eye", toolTip: table.description)
    }

    var preferredResponder: NSView { grid }

    func prepareToClose(then proceed: @escaping () -> Void) {
        resolvePendingEdits(before: "Closing the tab", then: proceed)
    }

    func tabDidClose() { stop() }
}
