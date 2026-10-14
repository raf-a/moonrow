import AppCore
import AppKit
import DBKit
import SQLScript

/// A query run's output: one tab per statement that returned rows, plus Messages, which logs
/// every statement with its row count, time or error. A pinned result stays through the next
/// runs, until it's closed or unpinned; each result can show its rows as a chart. A result cut
/// by the row limit can be fetched again whole (Fetch All).
@MainActor
final class ResultsViewController: NSViewController {
    private let strip = TabStrip()
    private let container = NSView()
    private let messagesScroll = NSTextView.scrollableTextView()
    private var messages: NSTextView { messagesScroll.documentView as! NSTextView }
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "No Results")
    private let exportButton = NSButton(title: "Export…", target: nil, action: #selector(MoonrowActions.exportData(_:)))
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let chartButton = NSButton(title: "Chart", target: nil, action: nil)
    private let fetchAllButton = NSButton(title: "Fetch All", target: nil, action: nil)
    /// For Copy Rows As ▸ SQL INSERT.
    var dialect: any Dialect = SQLiteDialect()
    /// Fetch All: runs the result's statement again without the row limit, into that result.
    var onFetchAll: ((ResultGridController) -> Void)?

    private(set) var results: [ResultGridController] = []
    private var statements: [SQLStatementRange] = []
    /// Statement index → its result tab.
    private var resultForStatement: [Int: ResultGridController] = [:]
    /// Nil shows Messages.
    private var shown: ResultGridController?
    private var showsMessages = false
    private var runStart = ContinuousClock.now
    private(set) var failedStatement: Int?
    private var failure: ScriptRunner.Failure?
    /// Statements of the run that started.
    private var started = 0
    /// How the last statement without a result set ended.
    private var lastOutcome: ScriptRunner.Outcome?
    private var summary: ScriptRunner.Summary?
    /// The next result's number. It only grows while pinned results stay, so the tabs read in
    /// order; a run with nothing pinned starts over at 1.
    private var nextNumber = 1
    /// The result Fetch All is filling.
    private var fetching: ResultGridController?

    override func loadView() {
        strip.onSelect = { [weak self] i in self?.select(tab: i) }
        // Only pinned results have a close button.
        strip.onClose = { [weak self] i in self?.closeResult(at: i) }

        messages.isEditable = false
        messages.font = Self.messageFont
        messages.textContainerInset = NSSize(width: 6, height: 6)
        messagesScroll.isHidden = true

        placeholder.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        exportButton.toolTip = "Export the shown result"
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self
        pinButton.action = #selector(togglePin(_:))
        chartButton.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
        chartButton.imagePosition = .imageLeading
        chartButton.setButtonType(.pushOnPushOff)
        chartButton.target = self
        chartButton.action = #selector(toggleChart(_:))
        chartButton.toolTip = "Show the rows as a chart"
        fetchAllButton.target = self
        fetchAllButton.action = #selector(fetchAll(_:))
        fetchAllButton.toolTip = "Run the statement again without the row limit"
        for b in [exportButton, pinButton, chartButton, fetchAllButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.isHidden = true
        }
        // The spacer takes the slack, so the buttons stay at the trailing edge whatever the status says.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [statusLabel, spacer, fetchAllButton, chartButton, pinButton, exportButton])
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bottom.heightAnchor.constraint(equalToConstant: 24).isActive = true
        resultBar = bottom
        let line = NSBox()
        line.boxType = .separator

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        for v in [strip, container, line, bottom, placeholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        messagesScroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(messagesScroll)
        messagesScroll.pin(to: container)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            bottom.topAnchor.constraint(equalTo: line.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = root
        updateButtons()
        updateStrip()
    }

    // MARK: - Run lifecycle

    func beginRun(_ statements: [SQLStatementRange]) {
        fetching = nil
        shown?.shownView.removeFromSuperview()
        for r in results where !r.isPinned { r.removeFromParent() }
        results = results.filter(\.isPinned)
        if results.isEmpty { nextNumber = 1 }
        resultForStatement = [:]
        shown = nil
        showsMessages = false
        failedStatement = nil
        failure = nil
        started = 0
        lastOutcome = nil
        summary = nil
        self.statements = statements
        runStart = .now
        placeholder.isHidden = true
        messages.string = ""
        status("Running…")
        updateButtons()
        updateStrip()
        sourceChanged()
    }

    /// Fetch All: `result`'s statement runs again without the row limit. Its rows are replaced
    /// once the new ones start arriving; until then (or when it fails) it keeps the old ones.
    func beginFetchAll(_ result: ResultGridController) {
        fetching = result
        status("Fetching all rows…")
        updateButtons()
    }

    func handle(_ event: ScriptRunner.Event) {
        if let fetching { return handleFetchAll(event, into: fetching) }
        switch event {
        case .started(let i):
            started = i + 1
            log(statementLine(statements[i].text, index: i), color: .labelColor, time: true)
            status(statements.count > 1 ? "Running statement \(i + 1) of \(statements.count)…" : "Running…")
        case .columns(let i, let columns):
            let result = makeResult(columns, statement: statements[i])
            results.append(result)
            resultForStatement[i] = result
            if shown == nil && !showsMessages { show(result) }
            updateStrip()
        case .rows(let i, let rows):
            resultForStatement[i]?.append(rows)
            if shown === resultForStatement[i] { updateStatus() }
        case .finished(let i, let outcome):
            if let result = resultForStatement[i] {
                result.outcome = outcome
                result.rowsFinished()
            } else {
                lastOutcome = outcome
            }
            log(describe(outcome, returnsRows: resultForStatement[i] != nil), color: .secondaryLabelColor, indent: 2)
            if shown === resultForStatement[i] {
                updateStatus()
                updateButtons()
            }
        case .failed(let i, let failure):
            failedStatement = failedStatement ?? i
            self.failure = self.failure ?? failure
            log(failure)
            showMessages()
        case .done:
            finish(stopped: false)
        }
    }

    private func handleFetchAll(_ event: ScriptRunner.Event, into result: ResultGridController) {
        switch event {
        case .started:
            log(statementLine(result.statement.text, index: nil), color: .labelColor, time: true)
        case .columns(_, let columns):
            let target = columns == result.columns ? result : replace(result, columns: columns)
            target.removeAllRows()
            fetching = target
            if shown === target { updateStatus() }
        case .rows(_, let rows):
            result.append(rows)
            if shown === result { updateStatus() }
        case .finished(_, let outcome):
            result.outcome = outcome
            result.rowsFinished()
            log(describe(outcome, returnsRows: true), color: .secondaryLabelColor, indent: 2)
        case .failed(_, let failure):
            log(failure)
            fetching = nil
            showMessages()
            status(failure.headline, error: failure.message)
        case .done:
            fetching = nil
            updateButtons()
            if shown != nil { updateStatus() }
        }
    }

    /// The run was stopped by the user.
    func cancelled(atStatement index: Int?) {
        log("Stopped", color: .systemOrange, indent: 2)
        if let result = fetching {
            fetching = nil
            if result.outcome == nil { result.wasCancelled = true }
            updateButtons()
            return updateStatus()
        }
        if let index { resultForStatement[index]?.wasCancelled = true }
        finish(stopped: true)
    }

    private func finish(stopped: Bool) {
        summary = ScriptRunner.Summary(total: statements.count, ran: started, failed: failedStatement, stopped: stopped,
                                       duration: .now - runStart)
        if shown == nil && !showsMessages { showMessages() }
        updateStatus()
        updateStrip()
    }

    private func makeResult(_ columns: [ResultColumn], statement: SQLStatementRange) -> ResultGridController {
        let result = ResultGridController(columns: columns, statement: statement, number: nextNumber)
        nextNumber += 1
        result.dialect = dialect
        result.onSelectionChange = { [weak self, weak result] in
            if let self, result === self.shown { self.sourceChanged() }
        }
        addChild(result)
        return result
    }

    /// The statement now returns other columns: a new grid takes the old one's place and number.
    private func replace(_ old: ResultGridController, columns: [ResultColumn]) -> ResultGridController {
        let number = nextNumber
        nextNumber = old.number
        let new = makeResult(columns, statement: old.statement)
        nextNumber = number
        new.isPinned = old.isPinned
        if let i = results.firstIndex(where: { $0 === old }) { results[i] = new }
        for (k, v) in resultForStatement where v === old { resultForStatement[k] = new }
        let wasShown = shown === old
        old.shownView.removeFromSuperview()
        old.removeFromParent()
        if wasShown {
            shown = nil
            show(new)
        }
        updateStrip()
        return new
    }

    /// Whether `result` came from the last run (pinned ones may be older).
    private func isFromLastRun(_ result: ResultGridController) -> Bool {
        resultForStatement.values.contains { $0 === result }
    }

    // MARK: - Tabs

    private func updateStrip() {
        var items = results.map {
            TabStrip.Item(title: "Result \($0.number)", symbol: $0.isPinned ? "pin.fill" : "tablecells", closable: $0.isPinned,
                          toolTip: ($0.isPinned ? "Pinned. " : "") + $0.statement.text)
        }
        items.append(TabStrip.Item(title: "Messages", symbol: "text.alignleft", closable: false,
                                   tint: failedStatement == nil ? nil : .systemRed))
        strip.items = items
        if showsMessages {
            strip.selectedIndex = results.count
        } else {
            strip.selectedIndex = shown.flatMap { s in results.firstIndex { $0 === s } }
        }
    }

    private func select(tab i: Int) {
        if i < results.count { show(results[i]) } else { showMessages() }
    }

    private func show(_ result: ResultGridController) {
        shown?.shownView.removeFromSuperview()
        showsMessages = false
        messagesScroll.isHidden = true
        shown = result
        let v = result.shownView
        container.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.pin(to: container)
        updateButtons()
        updateStrip()
        updateStatus()
        sourceChanged()
    }

    private func updateButtons() {
        for b in [exportButton, pinButton, chartButton] { b.isHidden = shown == nil }
        let pinned = shown?.isPinned == true
        let pinTitle = pinned ? "Unpin Result" : "Pin Result"
        pinButton.state = pinned ? .on : .off
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinTitle)
        pinButton.toolTip = pinTitle
        pinButton.setAccessibilityLabel(pinTitle)
        chartButton.state = shown?.showsChart == true ? .on : .off
        fetchAllButton.isHidden = shown?.outcome?.truncated != true
        fetchAllButton.isEnabled = fetching == nil
    }

    @objc func togglePin(_ sender: Any?) {
        guard let shown else { return NSSound.beep() }
        shown.isPinned.toggle()
        updateButtons()
        updateStrip()
    }

    @objc func toggleChart(_ sender: Any?) {
        guard let result = shown else { return NSSound.beep() }
        result.shownView.removeFromSuperview()
        result.showsChart.toggle()
        show(result)
    }

    @objc func fetchAll(_ sender: Any?) {
        guard let shown, shown.outcome?.truncated == true, fetching == nil, let onFetchAll else { return NSSound.beep() }
        onFetchAll(shown)
    }

    /// A pinned result's close button: it goes; Messages or the next result shows instead.
    private func closeResult(at i: Int) {
        guard results.indices.contains(i) else { return }
        let result = results.remove(at: i)
        resultForStatement = resultForStatement.filter { $0.value !== result }
        result.removeFromParent()
        if shown === result {
            result.shownView.removeFromSuperview()
            shown = nil
            if results.indices.contains(min(i, results.count - 1)) { show(results[min(i, results.count - 1)]) } else { showMessages() }
        }
        updateStrip()
    }

    func showMessages() {
        shown?.shownView.removeFromSuperview()
        shown = nil
        updateButtons()
        showsMessages = true
        messagesScroll.isHidden = false
        placeholder.isHidden = true
        updateStrip()
        updateStatus()
        sourceChanged()
    }

    var showsMessagesTab: Bool { showsMessages }
    var messagesText: String { messages.string }
    var shownResult: ResultGridController? { shown }
    var statusText: String { statusLabel.stringValue }
    var statusIsError: Bool { statusLabel.textColor == .systemRed }
    private(set) var resultBar: NSView?
    var showsFetchAll: Bool { !fetchAllButton.isHidden }
    func select(_ result: ResultGridController) { show(result) }

    // MARK: - Messages and status

    private static let messageFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// "HH:mm:ss  " in front of each statement; everything else lines up after it.
    private static let stampWidth = 10
    private static let characterWidth = ("0" as NSString).size(withAttributes: [.font: messageFont]).width

    private func statementLine(_ text: String, index: Int?) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let more = text.contains(where: \.isNewline) ? " …" : ""
        let line = firstLine.count > 160 ? firstLine.prefix(160) + "…" : firstLine + more
        return index.map { statements.count > 1 ? "[\($0 + 1)] \(line)" : line } ?? line
    }

    /// Appends `text` after the time (or blanks as wide), each of its lines and their wrapped
    /// parts indented `indent` more.
    private func log(_ text: String, color: NSColor, time: Bool = false, indent: Int = 0) {
        let pad = String(repeating: " ", count: Self.stampWidth + indent)
        let stamp = time ? Self.time.string(from: Date()) + "  " + String(repeating: " ", count: indent) : pad
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.enumerated().map { ($0.offset == 0 ? stamp : pad) + $0.element }.joined(separator: "\n")
        let style = NSMutableParagraphStyle()
        style.headIndent = Self.characterWidth * CGFloat(Self.stampWidth + indent)
        let line = NSAttributedString(string: body + "\n", attributes: [
            .font: Self.messageFont, .foregroundColor: color, .paragraphStyle: style,
        ])
        messages.textStorage?.append(line)
        messages.scrollToEndOfDocument(nil)
    }

    private func log(_ failure: ScriptRunner.Failure) {
        var lines = failure.message.components(separatedBy: "\n")
        lines[0] = "Error: \(lines[0]) (\(DurationText.string(failure.duration)))"
        log(lines.joined(separator: "\n"), color: .systemRed, indent: 2)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func describe(_ outcome: ScriptRunner.Outcome, returnsRows: Bool) -> String {
        var parts: [String] = []
        if returnsRows {
            parts.append(rowsText(outcome.rowCount, truncated: outcome.truncated))
        } else if let n = outcome.rowsAffected {
            parts.append("\(n.formatted()) row\(n == 1 ? "" : "s") affected")
        } else {
            parts.append("Completed")
        }
        parts.append(DurationText.string(outcome.duration))
        return parts.joined(separator: " · ")
    }

    /// The shown result's rows and time, with the run's summary when the run had several
    /// statements and the result is one of them; on Messages, the summary. A run of one
    /// statement says how that statement ended: its error, or the rows it changed.
    private func updateStatus() {
        if let shown {
            var parts = [rowsText(shown.rows.count, truncated: shown.outcome?.truncated == true)]
            if let o = shown.outcome {
                parts.append(DurationText.string(o.duration))
            } else if shown.wasCancelled {
                parts.append("stopped")
            } else {
                parts.append("loading…")
            }
            if let summary, statements.count > 1, isFromLastRun(shown) { parts.append(summary.text()) }
            status(parts.joined(separator: " · "))
        } else if let summary {
            if statements.count == 1, let failure {
                status(failure.headline, error: failure.message)
            } else if statements.count == 1, !summary.stopped, let lastOutcome {
                status(describe(lastOutcome, returnsRows: false))
            } else {
                status(summary.text())
            }
        }
    }

    /// `error` (the whole message) turns the text red and becomes its tooltip.
    private func status(_ text: String, error: String? = nil) {
        statusLabel.stringValue = text
        statusLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        statusLabel.toolTip = error
    }

    private func rowsText(_ n: Int, truncated: Bool = false) -> String {
        truncated ? "First \(n.formatted()) row\(n == 1 ? "" : "s")" : "\(n.formatted()) row\(n == 1 ? "" : "s")"
    }

    private func sourceChanged() {
        NotificationCenter.default.post(name: .inspectorSourceDidChange, object: self)
    }
}

// MARK: - Right sidebar

/// The shown result's selected rows, read-only.
extension ResultsViewController: InspectorSource {
    var inspectorTitle: String { shown?.inspectorTitle ?? "" }
    var inspectorFields: [InspectorField] { shown?.inspectorFields ?? [] }
    func inspectorEdit(_ key: InspectorField.Key, text: String) { NSSound.beep() }
    func inspectorSet(_ key: InspectorField.Key, _ change: CellChange) { NSSound.beep() }
}

/// One result set in a read-only grid. Rows arrive in batches while the statement runs. A click
/// on a column's header sorts the rows in memory (again: the other way; a third time: as the
/// server sent them); copying and exporting follow the shown order.
@MainActor
final class ResultGridController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let columns: [ResultColumn]
    /// The statement as it ran (parameters filled in), with its place in the editor.
    let statement: SQLStatementRange
    let number: Int
    /// In the order the server sent them.
    private(set) var rows: [[DBValue]] = []
    var outcome: ScriptRunner.Outcome?
    var wasCancelled = false
    var dialect: any Dialect = SQLiteDialect()
    /// Kept through the next runs.
    var isPinned = false
    /// The rows as a chart instead of the grid.
    var showsChart = false
    /// The selected rows changed.
    var onSelectionChange: (() -> Void)?
    private(set) lazy var chart: ChartViewController = {
        let c = ChartViewController(columns: columns) { [weak self] in self?.rows ?? [] }
        addChild(c)
        return c
    }()
    let grid = DataGrid()
    private var columnsSized = false
    private var lastSelection = IndexSet()
    private var cellViewer: CellEditorController?
    private static let copyLimit = 100_000
    /// The column the rows are sorted by, if any.
    private(set) var sortKey: (column: Int, ascending: Bool)?
    /// Shown row → index into `rows`; nil while unsorted.
    private var order: [Int]?

    init(columns: [ResultColumn], statement: SQLStatementRange, number: Int) {
        self.columns = columns
        self.statement = statement
        self.number = number
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        grid.doubleAction = #selector(openCellViewer(_:))
        grid.onEdit = { [weak self] in self?.openCellViewer(nil) }
        let menu = NSMenu()
        // No shortcuts in context menus: AppKit would take them off the main menu's items.
        menu.addItem(withTitle: "Open Cell Viewer", action: #selector(openCellViewer(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Rows", action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(CopyFormat.menuItem(target: self, action: #selector(copyRowsAs(_:))))
        menu.addItem(withTitle: "Copy Selected Cells", action: #selector(copySelectedCells(_:)), keyEquivalent: "").target = self
        menu.addItem(CopyFormat.menuItem(target: self, action: #selector(copySelectedCellsAs(_:)), title: "Copy Selected Cells As"))
        menu.addItem(withTitle: "Copy Column Values", action: #selector(copyColumnValues(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Export…", action: #selector(MoonrowActions.exportData(_:)), keyEquivalent: "")
        grid.menu = menu
        grid.onFocusChange = { [weak self] _ in self?.refresh(self?.grid.selectedRowIndexes ?? []) }
        for (i, c) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            column.title = c.name
            column.headerToolTip = c.typeName.map { "\(c.name) — \($0)" } ?? c.name
            column.minWidth = 40
            column.maxWidth = 2000
            column.width = min(320, max(70, GridCell.width(of: c.name, header: true)))
            grid.addTableColumn(column)
        }
        grid.focusedColumn = grid.tableColumns.first?.identifier
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    /// The grid, or the chart.
    var shownView: NSView { showsChart ? chart.view : view }

    /// The statement finished: a chart picks up every row, a sort takes in the late rows.
    func rowsFinished() {
        if showsChart { chart.refreshColumns() }
        if sortKey != nil { applySort() }
    }

    func append(_ batch: [[DBValue]]) {
        let start = rows.count
        rows += batch
        // Sorted: new rows wait at the end until the statement finishes.
        if order != nil { order! += start..<rows.count }
        if !columnsSized { sizeColumns(start..<rows.count) }
        if isViewLoaded { grid.noteNumberOfRowsChanged() }
    }

    /// Fetch All's rows are about to replace these.
    func removeAllRows() {
        rows = []
        if order != nil { order = [] }
        outcome = nil
        wasCancelled = false
        if isViewLoaded {
            grid.deselectAll(nil)
            grid.reloadData()
        }
    }

    /// The row at a row of the grid.
    func shownRow(_ row: Int) -> [DBValue] { rows[order?[row] ?? row] }

    /// The rows in the order the grid shows them.
    var shownRows: [[DBValue]] { order.map { $0.map { rows[$0] } } ?? rows }

    /// Widens columns to fit the first rows, once.
    private func sizeColumns(_ range: Range<Int>) {
        _ = view
        columnsSized = true
        let sample = rows[range.prefix(200)]
        for column in grid.tableColumns {
            guard let i = Int(column.identifier.rawValue) else { continue }
            let widest = sample.lazy.map { GridCell.width(of: CellText.display($0[i]) ?? "NULL", header: false) }.max() ?? 0
            column.width = min(320, max(column.width, widest))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let i = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
        cell.show(.value(shownRow(row)[i]), focused: grid.isCellSelected(row: row, column: tableColumn))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: GridRowView.identifier, owner: nil) as? GridRowView ?? GridRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refresh(lastSelection.union(grid.selectedRowIndexes))
        lastSelection = grid.selectedRowIndexes
        onSelectionChange?()
    }

    private func refresh(_ rows: IndexSet) {
        let rows = rows.filteredIndexSet { $0 < grid.numberOfRows }
        grid.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<grid.numberOfColumns))
    }

    /// A double-click on a header's edge: the column as wide as its widest value.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        let tableColumn = tableView.tableColumns[column]
        guard let i = Int(tableColumn.identifier.rawValue) else { return tableColumn.width }
        // The visible rows and the first ones; measuring every row of a big result would show.
        let visible = tableView.rows(in: tableView.visibleRect)
        let sample = Set(0..<min(rows.count, 1_000)).union(visible.location..<min(rows.count, NSMaxRange(visible)))
        let widest = sample.lazy.map { GridCell.width(of: CellText.display(self.shownRow($0)[i]) ?? "NULL", header: false) }.max() ?? 0
        return min(tableColumn.maxWidth, max(tableColumn.minWidth, GridCell.width(of: tableColumn.title, header: true), widest))
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let i = Int(tableColumn.identifier.rawValue) else { return }
        switch sortKey {
        case (i, true)?: sortKey = (i, false)
        case (i, false)?: sortKey = nil
        default: sortKey = (i, true)
        }
        applySort()
    }

    /// Sorts by `sortKey`, keeping the same rows selected.
    private func applySort() {
        let selected = Set(grid.selectedRowIndexes.filter { $0 < rows.count }.map { order?[$0] ?? $0 })
        order = sortKey.map { ResultSort.order(rows, column: $0.column, ascending: $0.ascending) }
        for column in grid.tableColumns {
            let sorted = sortKey.map { String($0.column) == column.identifier.rawValue } ?? false
            grid.setIndicatorImage(sorted ? NSImage(named: sortKey!.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil,
                                   in: column)
        }
        grid.highlightedTableColumn = sortKey.flatMap { key in grid.tableColumns.first { $0.identifier.rawValue == String(key.column) } }
        grid.reloadData()
        guard !selected.isEmpty else { return }
        let shown = order.map { IndexSet($0.indices.filter { selected.contains(order![$0]) }) } ?? IndexSet(selected)
        grid.selectRowIndexes(shown, byExtendingSelection: false)
        if let first = shown.first { grid.scrollRowToVisible(first) }
    }

    // MARK: - Commands

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copySelectedCells(_:)), #selector(copySelectedCellsAs(_:)):
            return !grid.selectedRowIndexes.isEmpty && grid.selectedColumnSpan != nil
        case #selector(openCellViewer(_:)):
            return grid.selectedRow >= 0 && grid.focusedColumnIndex != nil
        case #selector(copyColumnValues(_:)):
            return !rows.isEmpty
        default:
            return true
        }
    }

    /// Return, a double-click: the value at the cursor in a window of its own, read-only.
    @objc func openCellViewer(_ sender: Any?) {
        // A double-click on the header isn't on a cell.
        if sender as? DataGrid === grid, grid.clickedRow < 0 { return }
        let row = grid.clickedRow >= 0 ? grid.clickedRow : grid.selectedRow
        guard row >= 0, row < rows.count, let display = grid.focusedColumnIndex, let window = view.window,
              window.attachedSheet == nil, let i = Int(grid.tableColumns[display].identifier.rawValue) else { return NSSound.beep() }
        let viewer = CellEditorController(title: columns[i].name, value: .value(shownRow(row)[i]), typeName: columns[i].typeName ?? "",
                                          isEditable: false, fileName: columns[i].name)
        cellViewer = viewer
        viewer.begin(on: window)
    }

    var shownCellViewer: CellEditorController? { cellViewer?.window?.isSheet == true ? cellViewer : nil }

    /// ⇧⌘C: the selected rows across the selected columns.
    @objc func copySelectedCells(_ sender: Any?) { copyCells(as: nil) }

    @objc func copySelectedCellsAs(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, CopyFormat.allCases.indices.contains(tag) else { return }
        copyCells(as: CopyFormat.allCases[tag])
    }

    private func copyCells(as format: CopyFormat?) {
        guard let span = grid.selectedColumnSpan else { return NSSound.beep() }
        put(grid.selectedRowIndexes, columns: span.compactMap { Int(grid.tableColumns[$0].identifier.rawValue) }, as: format)
    }

    /// Every value of the clicked column, one per line, in the shown order.
    @objc func copyColumnValues(_ sender: Any?) {
        guard let display = grid.clickedColumn >= 0 ? grid.clickedColumn : grid.focusedColumnIndex,
              let i = Int(grid.tableColumns[display].identifier.rawValue) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CellText.tsv(shownRows.map { [$0[i]] }), forType: .string)
    }

    /// Copies the selected rows as tab-separated text, in the grid's column order.
    @objc func copy(_ sender: Any?) { copyRows(as: nil) }

    /// Copy Rows As ▸ CSV, JSON, SQL INSERT (into `result`), Markdown.
    @objc func copyRowsAs(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, CopyFormat.allCases.indices.contains(tag) else { return }
        copyRows(as: CopyFormat.allCases[tag])
    }

    private func copyRows(as format: CopyFormat?) {
        var selection = grid.selectedRowIndexes
        if grid.clickedRow >= 0, !selection.contains(grid.clickedRow) { selection = [grid.clickedRow] }
        put(selection, columns: grid.tableColumns.compactMap { Int($0.identifier.rawValue) }, as: format)
    }

    private func put(_ selection: IndexSet, columns order: [Int], as format: CopyFormat?) {
        guard !selection.isEmpty else { return NSSound.beep() }
        guard selection.count <= Self.copyLimit else { return refuseCopy(selection.count) }
        let ordered = selection.map { r in order.map { shownRow(r)[$0] } }
        let text = format?.text(columns: order.map { columns[$0].name }, rows: ordered, dialect: dialect, table: nil)
            ?? CellText.tsv(ordered)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refuseCopy(_ count: Int) {
        let alert = NSAlert()
        alert.messageText = "Can’t copy \(count.formatted()) rows"
        alert.informativeText = "Copying takes at most \(Self.copyLimit.formatted()) rows at a time."
        if let window = view.window, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// What Export writes: the rows and columns in the order the grid shows them.
    var exportSubject: ExportSubject {
        _ = view
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let origin = outcome?.truncated == true ? "from the query (only its first \(rows.count.formatted()) rows)" : "from the query"
        return .result(name: "Result \(number)", columns: order.map { columns[$0].name },
                       rows: shownRows.map { r in order.map { r[$0] } }, origin: origin)
    }

    // MARK: - Right sidebar

    /// Most selected rows the right sidebar compares.
    private static let inspectorLimit = 1_000

    var inspectorTitle: String {
        let n = grid.selectedRowIndexes.count
        return n == 0 ? "Result \(number)" : "Result \(number) · \(n.formatted()) \(n == 1 ? "row" : "rows")"
    }

    var inspectorFields: [InspectorField] {
        let selected = grid.selectedRowIndexes.filteredIndexSet { $0 < rows.count }.prefix(Self.inspectorLimit)
        let shown = selected.map { r in shownRow(r).map(CellContent.value) }
        let info = columns.map { ColumnInfo(name: $0.name, typeName: $0.typeName ?? "") }
        return InspectorForm.rows(columns: info, shown: shown, staged: [], editable: false)
    }
}
