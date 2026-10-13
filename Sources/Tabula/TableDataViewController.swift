import AppCore
import AppKit
import DBKit

/// A table's rows in an editable grid.
///
/// The grid shows one page of the table (filter, sort and page from `query`). Within the page
/// the row cache fills in whatever is on screen, so even "all rows" stays fast. Edits are staged
/// in the workspace's `StagedChanges`, keyed by row, and drawn over the rows as they load, so
/// they outlive paging, sorting, filtering, reloads and the tab itself. The workspace commits
/// (⌘S) or discards (⇧⌘⌫) them, together with everything else staged.
@MainActor
final class TableDataViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuItemValidation, NSMenuDelegate, TabulaActions
{
    let table: TableRef
    let kind: ObjectKind
    var onTabItemChange: (() -> Void)?
    /// The user paged, sorted, filtered or staged an edit (a preview tab becomes regular).
    var onUse: (() -> Void)?
    /// Shown first in the bottom bar (the Data / Structure switch).
    var leadingAccessory: NSView?
    /// Why the grid can't be edited (a view, a read-only connection), or nil.
    let readOnlyReason: String?
    /// Asks before a commit is sent.
    var safety: SafetyGate?
    /// Where the Columns button keeps which columns show, per table.
    var columnLayouts: ColumnLayouts?
    var isEditable: Bool { readOnlyReason == nil }

    private let connection: any DatabaseConnection
    private let changes: StagedChanges
    let grid = DataGrid()
    let filterBar = FilterBar()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pageButton = NSButton(title: "", target: nil, action: nil)
    private let pageControl = NSSegmentedControl()
    private let addRowButton = NSButton(title: "Row", target: nil, action: nil)
    private let filtersButton = NSButton(title: "Filters", target: nil, action: nil)
    private let columnsButton = NSButton(title: "Columns", target: nil, action: nil)
    private var cellEditor: CellEditorController?
    /// The context menu's Quick Filter items, rebuilt for the clicked cell.
    private let quickFilterItem = NSMenuItem(title: "Quick Filter", action: nil, keyEquivalent: "")

    private(set) var browser: TableBrowser?
    private(set) var cache: RowCache?
    private(set) var query: GridQuery
    /// Rows matching the filter, across all pages.
    private(set) var total = 0
    /// `total` is the planner's estimate (a large unfiltered Postgres table).
    private var totalIsEstimate = false
    private var loadTask: Task<Void, Never>?
    private var columnsSized = false
    private var lastSelection = IndexSet()
    private var popover: NSPopover?
    private var stack = NSStackView()

    /// The inline edit in progress: grid row, model column and the text it started from.
    private var editing: (row: Int, column: Int, start: String)?

    /// Copying more rows than this asks the user to narrow the selection.
    private static let copyLimit = 100_000

    init(connection: any DatabaseConnection, changes: StagedChanges, object: DatabaseObject,
         readOnlyConnection: Bool, pageSize: Int?) {
        self.connection = connection
        self.changes = changes
        self.table = object.ref
        self.kind = object.kind
        self.readOnlyReason = readOnlyConnection ? "The connection is read-only."
            : object.kind == .table ? nil : "Only tables can be edited."
        self.query = GridQuery(page: Paging(pageSize: pageSize))
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// This table's staged edits (empty when none are staged).
    var edits: TableEdits {
        changes.edits(for: table) ?? TableEdits(table: table, columns: browser?.columns ?? [])
    }

    /// Stages an edit as one undo step named `name`.
    fileprivate func updateEdits(_ name: String, _ body: (inout TableEdits) -> Void) {
        let before = changes.edits(for: table)
        changes.perform(name, at: place) {
            var e = edits
            body(&e)
            changes.setEdits(e)
        }
        if changes.edits(for: table) != before { onUse?() }
    }

    /// The table and selection, for undo.
    private var place: EditPlace {
        EditPlace(table: table, kind: kind, side: .data, rows: grid.selectedRowIndexes,
                  column: grid.focusedColumn.flatMap { Int($0.rawValue) })
    }

    /// Selection to restore once the page has loaded.
    private var pendingSelection: EditPlace?

    /// After an undo or redo: selects the rows (and cell) that were selected when the step was
    /// made, once they've loaded.
    func restoreSelection(_ place: EditPlace) {
        guard isViewLoaded, cache != nil else {
            pendingSelection = place
            return
        }
        pendingSelection = nil
        let rows = place.rows.filteredIndexSet { $0 < grid.numberOfRows }
        if let c = place.column { grid.focusedColumn = NSUserInterfaceItemIdentifier(String(c)) }
        grid.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { grid.scrollRowToVisible(first) }
        view.window?.makeFirstResponder(grid)
    }

    /// Rows loaded from the database on this page; new rows follow them.
    fileprivate var baseRowCount: Int { cache?.rowCount ?? 0 }
    fileprivate var rowCount: Int { baseRowCount + edits.insertedRowCount }
    private func isInserted(_ row: Int) -> Bool { row >= baseRowCount && row < rowCount }
    fileprivate func loadedRow(_ row: Int) -> [DBValue]? { row < baseRowCount ? cache?.row(at: row) : nil }
    fileprivate func state(of row: Int) -> TableEdits.RowState {
        isInserted(row) ? .inserted : edits.state(of: loadedRow(row))
    }
    fileprivate func change(row: Int, column: Int) -> CellChange? {
        isInserted(row) ? edits.inserts[row - baseRowCount][column] : edits.change(in: loadedRow(row), column: column)
    }

    /// Anything staged or unstaged anywhere in the workspace (a commit, a discard, another tab).
    @objc private func stagedChangesChanged() {
        guard isViewLoaded, editing == nil else { return }
        grid.reloadKeepingSelection()
        updateBar()
    }

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
        grid.headerView?.menu = makeHeaderMenu()
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
        columnsButton.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")
        columnsButton.imagePosition = .imageLeading
        columnsButton.target = self
        columnsButton.action = #selector(showColumns(_:))
        columnsButton.toolTip = "Choose and order the columns shown"
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
        for b in [addRowButton, filtersButton, columnsButton, pageButton] {
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

        var views: [NSView] = [addRowButton, filtersButton, columnsButton, statusLabel, pageButton, pageControl]
        if let leadingAccessory { views.insert(leadingAccessory, at: 0) }
        let bar = NSStackView(views: views)
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

    /// Re-reads columns, count and the current page. Staged edits stay; they find their rows
    /// again by key.
    func reload() {
        stop()
        abortInlineEdit()
        showStatus("Loading…")
        loadTask = Task {
            do {
                let browser = try await TableBrowser.open(table, on: connection)
                guard !Task.isCancelled else { return }
                let changed = browser.columns != self.browser?.columns
                self.browser = browser
                if changed { install(browser.columns) }
                if var e = changes.edits(for: table), e.columns != browser.columns {
                    e.rebase(columns: browser.columns)
                    changes.setEdits(e)
                }
                try await loadPage(recount: true, scrollToTop: false)
            } catch {
                guard !Task.isCancelled else { return }
                cache = nil
                grid.reloadData()
                showError(error)
            }
        }
    }

    /// Loads the page `query` describes, recounting rows first when the filter changed.
    private func reloadPage(recount: Bool, scrollToTop: Bool = true, exact: Bool = false) {
        stop()
        abortInlineEdit()
        loadTask = Task {
            do {
                try await loadPage(recount: recount, scrollToTop: scrollToTop, exact: exact)
            } catch {
                guard !Task.isCancelled else { return }
                showError(error)
            }
        }
    }

    private func loadPage(recount: Bool, scrollToTop: Bool, exact: Bool = false) async throws {
        guard let browser else { return }
        if recount || cache == nil {
            showStatus("Counting rows…")
            // An estimate can't address every row of one virtual page; count those exactly.
            let n = query.page.pageSize == nil || exact
                ? RowCount(try await browser.count(filter: query.filter))
                : try await browser.rowCount(filter: query.filter)
            guard !Task.isCancelled else { return }
            total = n.value
            totalIsEstimate = n.isEstimate
        }
        // A page past the end (rows were deleted, or a narrower filter): go to the last one.
        if let size = query.page.pageSize, query.page.offset >= total, total > 0 {
            query.page.offset = (total - 1) / size * size
        }
        let cache = RowCache(rowCount: query.page.rows(total: total).count, fetch: browser.fetcher(query))
        cache.onLoad = { [weak self] rows in self?.rowsLoaded(rows) }
        cache.onError = { [weak self] error in self?.showError(error) }
        self.cache = cache
        lastSelection = []
        grid.reloadData()
        if scrollToTop { grid.scrollRowToVisible(0) }
        if let pendingSelection { restoreSelection(pendingSelection) }
        showStatus(query.filter == nil ? "" : "Filtered")
        updateBar()
        visibleRowsChanged()
    }

    private func install(_ columns: [ColumnInfo]) {
        let names = columns.map(\.name)
        // Widths stay with their column across a re-arrangement.
        let widths = Dictionary(grid.tableColumns.map { ($0.title, $0.width) }, uniquingKeysWith: { a, _ in a })
        let focused = grid.focusedColumn
        for c in grid.tableColumns.reversed() { grid.removeTableColumn(c) }
        for i in layout.visible(names) {
            let info = columns[i]
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            column.title = info.name
            var tip = info.typeName.isEmpty ? info.name : "\(info.name) — \(info.typeName)"
            if info.primaryKeyPosition != nil { tip += " (primary key)" }
            column.headerToolTip = tip + "\nClick to sort"
            column.minWidth = 40
            column.maxWidth = 2000
            column.width = widths[info.name] ?? min(320, max(70, GridCell.width(of: info.name, header: true)))
            grid.addTableColumn(column)
        }
        query.sort.removeAll { !names.contains($0.column) }
        if query.filter != nil, filterBar.columns != names { query.filter = nil }
        filterBar.setColumns(names)
        if let pending = pendingConditions {
            DispatchQueue.main.async { [weak self] in self?.showRows(matching: pending.conditions, focus: pending.focus) }
        }
        grid.focusedColumn = focused.flatMap { grid.column(withIdentifier: $0) >= 0 ? $0 : nil } ?? grid.tableColumns.first?.identifier
        if widths.isEmpty { columnsSized = false }
        updateSortIndicators()
        updateColumnsButton()
    }

    /// The table's column layout (which columns show, in what order).
    private var layout: ColumnLayout { columnLayouts?.layout(for: table) ?? ColumnLayout() }

    private func setLayout(_ new: ColumnLayout) {
        columnLayouts?.set(new, for: table)
        guard let columns = browser?.columns else { return }
        endInlineEdit()
        install(columns)
        grid.reloadData()
    }

    private func updateColumnsButton() {
        let hidden = browser.map { b in b.columns.count - layout.visible(b.columns.map(\.name)).count } ?? 0
        columnsButton.contentTintColor = hidden > 0 ? .controlAccentColor : nil
        columnsButton.title = hidden > 0 ? "Columns (\(hidden) hidden)" : "Columns"
    }

    @objc func showColumns(_ sender: Any?) {
        guard let columns = browser?.columns else { return NSSound.beep() }
        let controller = ColumnsPopoverController(columns: columns.map(\.name), layout: layout)
        controller.onChange = { [weak self] layout in self?.setLayout(layout) }
        present(controller, from: columnsButton, edge: .maxY, size: NSSize(width: 280, height: 340))
    }

    /// Dragging a header remembers the new order.
    func tableViewColumnDidMove(_ notification: Notification) {
        guard let names = browser?.columns.map(\.name) else { return }
        var new = layout
        new.setShownOrder(grid.tableColumns.map(\.title), columns: names)
        columnLayouts?.set(new, for: table)
    }

    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func hideClickedColumn(_ sender: NSMenuItem) {
        guard let names = browser?.columns.map(\.name), let name = sender.representedObject as? String else { return }
        var new = layout
        guard new.setHidden(true, name, columns: names) else { return NSSound.beep() }
        setLayout(new)
    }

    @objc private func showAllColumns(_ sender: Any?) {
        setLayout(ColumnLayout(order: layout.order, hidden: []))
    }

    @objc private func resetColumnOrder(_ sender: Any?) {
        setLayout(ColumnLayout(order: [], hidden: layout.hidden))
    }

    @objc private func visibleRowsChanged() {
        guard let cache else { return }
        let visible = grid.rows(in: grid.visibleRect)
        let end = min(visible.location + visible.length, cache.rowCount)
        cache.setVisibleRows(min(visible.location, end)..<end)
    }

    private func rowsLoaded(_ rows: Range<Int>) {
        if !columnsSized { sizeColumnsToContent(rows) }
        // The estimate overshot: the page ends early. Count exactly and show the real end.
        if totalIsEstimate, let cache, rows.upperBound == cache.rowCount, cache.row(at: rows.upperBound - 1) == nil {
            totalIsEstimate = false
            return reloadPage(recount: true, scrollToTop: false, exact: true)
        }
        let visible = grid.rows(in: grid.visibleRect)
        // Selected rows that arrive fill in the right sidebar.
        if grid.selectedRowIndexes.intersects(integersIn: rows) {
            NotificationCenter.default.post(name: .inspectorSourceDidChange, object: self)
        }
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
        pageButton.title = cache == nil ? "" : query.page.describe(total: total, estimated: totalIsEstimate)
        pageButton.toolTip = totalIsEstimate ? "Page size and offset. The row count is the planner's estimate." : "Page size and offset"
        pageControl.setEnabled(query.page.previous != nil, forSegment: 0)
        pageControl.setEnabled(query.page.next(total: total) != nil, forSegment: 1)
        pageControl.isHidden = query.page.pageSize == nil
        filtersButton.state = filterBar.isHidden ? .off : .on
        filtersButton.contentTintColor = query.filter == nil ? nil : .controlAccentColor
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

    func numberOfRows(in tableView: NSTableView) -> Int { cache == nil ? 0 : rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
        let state = state(of: row)
        let change = change(row: row, column: column)
        cell.show(
            content(row: row, column: column),
            edited: change != nil && state != .inserted,
            focused: grid.isCellSelected(row: row, column: tableColumn),
            struckOut: state == .deleted)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: GridRowView.identifier, owner: nil) as? GridRowView ?? GridRowView()
        view.state = state(of: row)
        return view
    }

    /// What a cell shows: its staged change, else the loaded value.
    fileprivate func content(row: Int, column: Int) -> CellContent {
        switch change(row: row, column: column) {
        case .value(let v)?: return .value(v)
        case .defaultValue?: return .defaultValue
        case nil:
            if isInserted(row) { return .defaultValue }
            guard let values = cache?.row(at: row), column < values.count else { return .pending }
            return .value(values[column])
        }
    }

    /// The row as shown, for copying and duplicating. Nil while it hasn't loaded.
    private func shownValues(row: Int) -> [DBValue?]? {
        guard let columns = browser?.columns else { return nil }
        if !isInserted(row), cache?.row(at: row) == nil { return nil }
        return columns.indices.map { i in
            if case .value(let v) = content(row: row, column: i) { return v }
            return nil
        }
    }

    /// Redraws cells (and row tints) without disturbing an inline edit.
    private func refreshCells(_ rows: IndexSet, columns: IndexSet? = nil) {
        guard editing == nil else { return }
        let rows = rows.filteredIndexSet { $0 < grid.numberOfRows }
        for row in rows { (grid.rowView(atRow: row, makeIfNecessary: false) as? GridRowView)?.state = state(of: row) }
        grid.reloadData(forRowIndexes: rows, columnIndexes: columns ?? IndexSet(integersIn: 0..<grid.numberOfColumns))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = grid.selectedRowIndexes
        refreshCells(lastSelection.union(selected), columns: grid.selectedCellColumns)
        lastSelection = selected
        NotificationCenter.default.post(name: .inspectorSourceDidChange, object: self)
    }

    /// The cursor or the span of selected columns changed.
    private func focusMoved(from previous: NSUserInterfaceItemIdentifier?) {
        refreshCells(grid.selectedRowIndexes)
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard browser != nil else { return }
        endInlineEdit()
        query.cycleSort(tableColumn.title)
        query.page.offset = 0
        onUse?()
        updateSortIndicators()
        reloadPage(recount: false)
    }

    // MARK: - Filtering and paging

    /// Conditions waiting for the columns to load.
    private var pendingConditions: (conditions: [FilterCondition], focus: Bool)?

    /// Shows the rows matching every condition (Search in Database's results), in the filter
    /// bar. `focus` moves the keyboard focus to the grid.
    func showRows(matching conditions: [FilterCondition], focus: Bool = true) {
        guard browser != nil, !filterBar.columns.isEmpty else {
            pendingConditions = (conditions, focus)
            return
        }
        pendingConditions = nil
        if filterBar.isHidden {
            filterBar.isHidden = false
            stack.arrangedSubviews[1].isHidden = false
            updateBar()
        }
        filterBar.replace(with: conditions)
        if focus { view.window?.makeFirstResponder(grid) }
    }

    private func applyFilter(_ filter: Filter?) {
        endInlineEdit()
        // Applying the filter that is already applied refreshes the rows.
        if filter != query.filter {
            query.filter = filter
            query.page.offset = 0
            onUse?()
        }
        reloadPage(recount: true)
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
        endInlineEdit()
        query.page = page
        onUse?()
        reloadPage(recount: false)
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

    // MARK: - Popovers

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
        // Below the last row: a new row, as + Row does.
        if row < 0, grid.isBelowRows(NSApp.currentEvent) { return isEditable ? addRow(sender) : () }
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
        guard state(of: row) != .deleted else { return refuse("This row is marked for deletion.") }
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
        stage(.value(value), row: row, column: column)
    }

    /// Stages one cell of a loaded or new row; the change notification redraws the grid.
    private func stage(_ change: CellChange, row: Int, column: Int) {
        let loaded = loadedRow(row)
        let inserted = isInserted(row) ? row - baseRowCount : nil
        updateEdits("Edit Cell") { e in
            if let inserted { e.setInserted(change, row: inserted, column: column) }
            else if let loaded { e.set(change, column: column, in: loaded) }
        }
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

    /// Ends an inline edit, keeping what was typed. The workspace calls it before a commit.
    func endInlineEdit() {
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
        var index = 0
        updateEdits("Add Row") { index = $0.addRow() }
        let row = baseRowCount + index
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
        var copies: [[Int: CellChange]] = []
        for row in targetRows where state(of: row) != .deleted {
            guard let values = shownValues(row: row) else { continue }
            var cells: [Int: CellChange] = [:]
            for (i, v) in values.enumerated() where !key.contains(i) {
                if let v { cells[i] = .value(v) }
            }
            copies.append(cells)
        }
        guard !copies.isEmpty else { return NSSound.beep() }
        let first = rowCount
        updateEdits(copies.count == 1 ? "Duplicate Row" : "Duplicate Rows") { e in for c in copies { e.addRow(c) } }
        let added = IndexSet(integersIn: first..<rowCount)
        grid.selectRowIndexes(added, byExtendingSelection: false)
        grid.scrollRowToVisible(added.last!)
        updateBar()
    }

    @objc func deleteRows(_ sender: Any?) {
        guard isEditable, cache != nil else { return NSSound.beep() }
        let rows = targetRows
        guard !rows.isEmpty else { return NSSound.beep() }
        abortInlineEdit()
        let base = baseRowCount
        let loaded = rows.filter { $0 < base }.compactMap { cache?.row(at: $0) }
        updateEdits(rows.count == 1 ? "Delete Row" : "Delete Rows") { e in
            for row in loaded { e.delete(row) }
            e.removeInserted(rows.filter { $0 >= base }.map { $0 - base })
        }
        grid.selectRowIndexes(IndexSet(rows.filter { $0 < rowCount }), byExtendingSelection: false)
    }

    @objc func setNull(_ sender: Any?) { setFocusedCells(.value(.null), "Set NULL") }
    @objc func setEmpty(_ sender: Any?) { setFocusedCells(.value(.text("")), "Set Empty String") }
    @objc func setDefault(_ sender: Any?) { setFocusedCells(.defaultValue, "Set DEFAULT") }

    /// Sets the cursor's column in every target row.
    private func setFocusedCells(_ change: CellChange, _ name: String) {
        guard isEditable, let display = grid.focusedColumnIndex,
              let column = Int(grid.tableColumns[display].identifier.rawValue) else { return NSSound.beep() }
        endInlineEdit()
        let base = baseRowCount
        let rows = targetRows
        updateEdits(name) { e in
            e.set(change, column: column, loaded: rows.filter { $0 < base }.compactMap(loadedRow), inserted: rows.filter { $0 >= base }.map { $0 - base })
        }
    }

    /// ⌥⌘R: reads the table again; staged edits stay.
    @objc func reloadCurrentTab(_ sender: Any?) {
        endInlineEdit()
        reload()
    }

    // MARK: - Menus

    private func makeSetValueMenu() -> NSMenu {
        let menu = NSMenu(title: "Set Value")
        for (title, action) in [("NULL", #selector(setNull(_:))), ("Empty String", #selector(setEmpty(_:))),
                                ("DEFAULT", #selector(setDefault(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "From File…", action: #selector(setValueFromFile(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Context menus show no shortcuts: AppKit would take them off the main menu's items.
        menu.addItem(withTitle: "Open Cell Editor…", action: #selector(quickLook(_:)), keyEquivalent: "").target = self
        let setValue = menu.addItem(withTitle: "Set Value", action: nil, keyEquivalent: "")
        setValue.submenu = makeSetValueMenu()
        quickFilterItem.submenu = NSMenu(title: "Quick Filter")
        menu.addItem(quickFilterItem)
        menu.addItem(.separator())
        for (title, action) in [("Add Row", #selector(addRow(_:))), ("Duplicate", #selector(duplicateRows(_:))),
                                ("Delete", #selector(deleteRows(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Rows", action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(CopyFormat.menuItem(target: self, action: #selector(copyRowsAs(_:))))
        menu.addItem(withTitle: "Copy Selected Cells", action: #selector(copySelectedCells(_:)), keyEquivalent: "").target = self
        menu.addItem(CopyFormat.menuItem(target: self, action: #selector(copySelectedCellsAs(_:)), title: "Copy Selected Cells As"))
        menu.addItem(withTitle: "Copy Column Values", action: #selector(copyColumnValues(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Rows", action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste into Selected Cells", action: #selector(pasteIntoSelectedCells(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // Sent up the responder chain to the workspace.
        menu.addItem(withTitle: "Export…", action: #selector(TabulaActions.exportData(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Export Current Page…", action: #selector(exportCurrentPage(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Import CSV…", action: #selector(TabulaActions.importCSV(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Columns…", action: #selector(showColumns(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload", action: #selector(reloadCurrentTab(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// The header's menu (hide this column, show all, reset the order) and the cell menu's
    /// Quick Filter items are built for what was clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === grid.headerView?.menu { return fillHeaderMenu(menu) }
        guard menu === grid.menu, let submenu = quickFilterItem.submenu else { return }
        submenu.removeAllItems()
        for item in quickFilterItems() { submenu.addItem(item) }
        quickFilterItem.isEnabled = !submenu.items.isEmpty
    }

    private func fillHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = grid.clickedColumn
        if c >= 0 {
            let name = grid.tableColumns[c].title
            let hide = menu.addItem(withTitle: "Hide “\(name)”", action: #selector(hideClickedColumn(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = name
        }
        menu.addItem(withTitle: "Show All Columns", action: #selector(showAllColumns(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Column Order", action: #selector(resetColumnOrder(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Columns…", action: #selector(showColumns(_:)), keyEquivalent: "").target = self
    }

    /// Conditions on the clicked cell's column and value: equal, not equal, less, greater,
    /// contains (text), IS NULL and IS NOT NULL. Our own list.
    private func quickFilterItems() -> [NSMenuItem] {
        let row = grid.clickedRow >= 0 ? grid.clickedRow : grid.selectedRow
        guard row >= 0, let display = grid.clickedColumn >= 0 ? grid.clickedColumn : grid.focusedColumnIndex,
              let column = Int(grid.tableColumns[display].identifier.rawValue),
              let name = browser?.columns[column].name else { return [] }
        return QuickFilter.conditions(column: name, value: content(row: row, column: column).value).map { condition in
            let item = NSMenuItem(title: QuickFilter.title(condition), action: #selector(applyQuickFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = QuickFilter.Box(condition)
            return item
        }
    }

    /// Adds the condition to the filter bar (in the first row when that's empty) and applies the
    /// bar's checked rows.
    @objc private func applyQuickFilter(_ sender: NSMenuItem) {
        guard let condition = (sender.representedObject as? QuickFilter.Box)?.condition else { return }
        if filterBar.isHidden { toggleFilters(nil) }
        filterBar.add(condition)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // ⌘←, ⌘→ and ⌘⌫ belong to a text field while one is being edited.
        let typing = view.window?.firstResponder is NSTextView
        let hasRows = !targetRows.isEmpty
        switch item.action {
        case #selector(copy(_:)), #selector(copyRowsAs(_:)): return hasRows
        case #selector(copySelectedCells(_:)), #selector(copySelectedCellsAs(_:)):
            return !typing && hasRows && grid.selectedColumnSpan != nil
        case #selector(copyColumnValues(_:)): return cache != nil && (grid.clickedColumn >= 0 || grid.focusedColumnIndex != nil)
        case #selector(addRow(_:)):
            if item.menu?.title == "Edit" { item.title = "Add Row" }
            return isEditable && cache != nil
        case #selector(runCurrentQuery(_:)):
            item.title = "Open Cell Editor"
            return !typing && grid.selectedRow >= 0 && grid.focusedColumnIndex != nil
        case #selector(duplicateRows(_:)), #selector(setNull(_:)), #selector(setEmpty(_:)), #selector(setDefault(_:)),
             #selector(setValueFromFile(_:)):
            return isEditable && hasRows
        case #selector(paste(_:)):
            return !typing && isEditable && cache != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(pasteIntoSelectedCells(_:)):
            return !typing && isEditable && hasRows && NSPasteboard.general.string(forType: .string) != nil
        case #selector(quickLook(_:)):
            return !typing && grid.selectedRow >= 0 && grid.focusedColumnIndex != nil
        case #selector(deleteRows(_:)):
            if item.menu?.title == "Edit" { item.title = "Delete Rows" }
            return isEditable && hasRows && !typing
        case #selector(nextPage(_:)): return !typing && query.page.next(total: total) != nil
        case #selector(previousPage(_:)): return !typing && query.page.previous != nil
        case #selector(exportCurrentPage(_:)), #selector(showColumns(_:)): return cache != nil
        case #selector(toggleFilters(_:)):
            item.title = filterBar.isHidden ? "Show Filters" : "Hide Filters"
            return true
        default: return true
        }
    }

    // MARK: - Cell editor

    /// ⌘↩ (Run Current's shortcut) in the grid: the cell editor.
    @objc func runCurrentQuery(_ sender: Any?) { quickLook(sender) }

    /// ⌘↩: the cell at the cursor in a window of its own. Saving stages the value.
    @objc func quickLook(_ sender: Any?) {
        let row = grid.clickedRow >= 0 ? grid.clickedRow : grid.selectedRow
        guard row >= 0, let display = grid.focusedColumnIndex, let window = view.window, window.attachedSheet == nil,
              let columns = browser?.columns, let column = Int(grid.tableColumns[display].identifier.rawValue)
        else { return NSSound.beep() }
        let content = content(row: row, column: column)
        if case .pending = content { return NSSound.beep() }
        abortInlineEdit()
        let info = columns[column]
        let editable = isEditable && state(of: row) != .deleted && GridPaste.accepts(info)
        let editor = CellEditorController(
            title: "\(table.name).\(info.name)", value: content, typeName: info.typeName, isEditable: editable,
            fileName: info.name)
        editor.onSave = { [weak self] change in self?.stage(change, row: row, column: column) }
        cellEditor = editor
        editor.begin(on: window)
    }

    /// For the dev harness.
    var shownCellEditor: CellEditorController? { cellEditor?.window?.isSheet == true ? cellEditor : nil }

    /// Set Value ▸ From File…: bytes for binary columns, UTF-8 text otherwise, into the cursor's
    /// column of every target row.
    @objc func setValueFromFile(_ sender: Any?) {
        guard isEditable, let window = view.window, let display = grid.focusedColumnIndex,
              let column = Int(grid.tableColumns[display].identifier.rawValue), let info = browser?.columns[column]
        else { return NSSound.beep() }
        endInlineEdit()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            switch CellEditorController.load(url, typeName: info.typeName) {
            case .success(let v): self.setFocusedCells(.value(v), "Set Value from File")
            case .failure(let error): self.refuse(error.message)
            }
        }
    }

    // MARK: - Paste

    /// ⌘V: pasted lines become new rows, their fields filling the shown columns in order.
    @objc func paste(_ sender: Any?) {
        guard isEditable, cache != nil, let columns = browser?.columns,
              let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        endInlineEdit()
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let lines = GridPaste.fields(text)
        guard !lines.isEmpty else { return NSSound.beep() }
        let first = rowCount
        updateEdits(lines.count == 1 ? "Paste Row" : "Paste Rows") { e in
            for fields in lines {
                var cells: [Int: CellChange] = [:]
                for (i, field) in fields.enumerated() where i < order.count && GridPaste.accepts(columns[order[i]]) {
                    cells[order[i]] = .value(GridPaste.value(field, column: columns[order[i]]))
                }
                e.addRow(cells)
            }
        }
        let added = IndexSet(integersIn: first..<rowCount)
        grid.selectRowIndexes(added, byExtendingSelection: false)
        if let last = added.last { grid.scrollRowToVisible(last) }
        updateBar()
    }

    /// ⇧⌘V: fills the selected cells from the pasteboard (see `GridPaste.assignments`) as one
    /// undo step. Deleted rows, generated columns and rows still loading are skipped.
    @objc func pasteIntoSelectedCells(_ sender: Any?) {
        guard isEditable, let columns = browser?.columns, let span = grid.selectedColumnSpan,
              let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        endInlineEdit()
        let targets = GridPaste.assignments(
            GridPaste.fields(text), rows: grid.selectedRowIndexes, columns: span,
            rowCount: rowCount, columnCount: grid.numberOfColumns)
        let base = baseRowCount
        var skipped = 0
        let changes: [(row: Int, column: Int, value: DBValue, loaded: [DBValue]?)] = targets.compactMap { t in
            guard let column = Int(grid.tableColumns[t.column].identifier.rawValue), GridPaste.accepts(columns[column]),
                  state(of: t.row) != .deleted, t.row >= base || loadedRow(t.row) != nil
            else { skipped += 1; return nil }
            return (t.row, column, GridPaste.value(t.text, column: columns[column]), loadedRow(t.row))
        }
        guard !changes.isEmpty else { return refuse("Nothing to paste into the selected cells.") }
        updateEdits("Paste") { e in
            for c in changes {
                if c.row >= base { e.setInserted(.value(c.value), row: c.row - base, column: c.column) }
                else if let loaded = c.loaded { e.set(.value(c.value), column: c.column, in: loaded) }
            }
        }
        // Rows pasted below the selection join it, so the result is in view.
        let rows = IndexSet(changes.map(\.row))
        grid.selectRowIndexes(grid.selectedRowIndexes.union(rows), byExtendingSelection: false)
        showStatus(skipped == 0 ? "" : "\(skipped) cell\(skipped == 1 ? "" : "s") skipped (deleted rows, generated columns or rows still loading).")
    }

    // MARK: - Export

    /// The page as shown (staged edits included, shown columns in order), through the export sheet.
    @objc func exportCurrentPage(_ sender: Any?) {
        guard cache != nil, let columns = browser?.columns else { return NSSound.beep() }
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let pageNumber = query.page.pageSize.map { query.page.offset / $0 + 1 }
        withRows(IndexSet(integersIn: 0..<rowCount)) { [weak self] rows in
            guard let self, let workspace = self.view.window?.windowController as? WorkspaceWindowController else { return }
            let origin = pageNumber.map { "on page \($0) of \(self.table.name)" } ?? "of \(self.table.name)"
            workspace.presentExport(.result(name: self.table.name, columns: order.map { columns[$0].name },
                                            rows: rows.map { r in order.map { r[$0] } }, origin: origin))
        }
    }

    // MARK: - Copy

    /// Copies selected rows as tab-separated text, as shown (staged edits included), in the
    /// grid's current column order.
    @objc func copy(_ sender: Any?) { copyRows(as: nil) }

    /// Copy Rows As ▸ CSV, JSON, SQL INSERT, Markdown, HTML; the item's tag picks the format.
    @objc func copyRowsAs(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, CopyFormat.allCases.indices.contains(tag) else { return }
        copyRows(as: CopyFormat.allCases[tag])
    }

    /// ⇧⌘C: the selected cells (selected rows across the selected columns) as tab-separated text.
    @objc func copySelectedCells(_ sender: Any?) { copyCells(as: nil) }

    @objc func copySelectedCellsAs(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, CopyFormat.allCases.indices.contains(tag) else { return }
        copyCells(as: CopyFormat.allCases[tag])
    }

    /// Every value of the clicked column on this page, one per line (NULL as an empty line).
    @objc func copyColumnValues(_ sender: Any?) {
        guard let display = grid.clickedColumn >= 0 ? grid.clickedColumn : grid.focusedColumnIndex,
              let column = Int(grid.tableColumns[display].identifier.rawValue) else { return NSSound.beep() }
        withRows(IndexSet(integersIn: 0..<rowCount)) { rows in
            Self.putOnPasteboard(CellText.tsv(rows.map { [$0[column]] }))
        }
    }

    private func copyRows(as format: CopyFormat?) {
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        copy(targetRows, columns: order, as: format)
    }

    private func copyCells(as format: CopyFormat?) {
        guard let span = grid.selectedColumnSpan else { return NSSound.beep() }
        let order = span.compactMap { Int(grid.tableColumns[$0].identifier.rawValue) }
        copy(grid.selectedRowIndexes, columns: order, as: format)
    }

    private func copy(_ selection: IndexSet, columns order: [Int], as format: CopyFormat?) {
        withRows(selection) { [weak self] rows in
            guard let self else { return }
            let ordered = rows.map { row in order.map { row[$0] } }
            let names = order.map { self.browser?.columns[$0].name ?? "" }
            let text = format?.text(columns: names, rows: ordered, dialect: self.connection.dialect, table: self.table)
                ?? CellText.tsv(ordered)
            Self.putOnPasteboard(text)
        }
    }

    private static func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Hands `body` the rows of `selection` as shown (staged edits on top), every column in
    /// table order, loading any that aren't in the cache yet. Over `copyLimit` rows it refuses.
    private func withRows(_ selection: IndexSet, _ body: @escaping ([[DBValue]]) -> Void) {
        guard let cache, let first = selection.first, let last = selection.last else {
            NSSound.beep()
            return
        }
        guard last - first < Self.copyLimit else {
            let alert = NSAlert()
            alert.messageText = "Too many rows"
            alert.informativeText = "Select fewer than \(Self.copyLimit.formatted(.number)) rows, or use Export… (⌘E)."
            if let window = view.window { alert.beginSheetModal(for: window) }
            return
        }
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
                body(rows)
            } catch {
                showError(error)
            }
        }
    }

    /// A loaded row with its staged changes applied.
    private func overlay(_ values: [DBValue], row: Int) -> [DBValue] {
        values.indices.map { i in
            switch change(row: row, column: i) {
            case .value(let v)?: v
            case .defaultValue?: .null
            case nil: values[i]
            }
        }
    }
}

// MARK: - Right sidebar

extension TableDataViewController: InspectorSource {
    /// Most selected rows the right sidebar compares; past this its fields are read-only.
    private static let inspectorLimit = 1_000

    var inspectorTitle: String {
        let n = grid.selectedRowIndexes.count
        return n == 0 ? table.name : "\(table.name) · \(n.formatted()) \(n == 1 ? "row" : "rows")"
    }

    var inspectorFields: [InspectorField] {
        guard let columns = browser?.columns, cache != nil else { return [] }
        let selected = grid.selectedRowIndexes.filteredIndexSet { $0 < rowCount }
        let rows = Array(selected.prefix(Self.inspectorLimit))
        let shown = rows.map { r in columns.indices.map { content(row: r, column: $0) } }
        let staged = rows.map { r in
            state(of: r) == .inserted ? [] : Set(columns.indices.filter { change(row: r, column: $0) != nil })
        }
        let editable = isEditable && selected.count <= Self.inspectorLimit && rows.contains { state(of: $0) != .deleted }
        return InspectorForm.rows(columns: columns, shown: shown, staged: staged, editable: editable)
    }

    func inspectorEdit(_ key: InspectorField.Key, text: String) {
        guard case .cell(let column) = key, let browser else { return }
        inspectorSet(key, .value(CellInput.parse(text, typeName: browser.columns[column].typeName)))
    }

    func inspectorSet(_ key: InspectorField.Key, _ change: CellChange) {
        guard case .cell(let column) = key, isEditable else { return NSSound.beep() }
        endInlineEdit()
        let base = baseRowCount
        let rows = grid.selectedRowIndexes.filteredIndexSet { $0 < rowCount }
        updateEdits(rows.count == 1 ? "Edit Cell" : "Edit Cells") { e in
            e.set(change, column: column, loaded: rows.filter { $0 < base }.compactMap(loadedRow), inserted: rows.filter { $0 >= base }.map { $0 - base })
        }
    }
}

extension QuickFilter {
    /// Carries a condition in a menu item's `representedObject`.
    final class Box: NSObject {
        let condition: FilterCondition
        init(_ condition: FilterCondition) { self.condition = condition }
    }
}
