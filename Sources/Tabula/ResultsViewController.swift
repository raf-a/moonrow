import AppCore
import AppKit
import DBKit
import SQLScript

/// A query run's output: one tab per statement that returned rows, plus Messages, which logs
/// every statement with its row count, time or error.
@MainActor
final class ResultsViewController: NSViewController {
    private let strip = TabStrip()
    private let container = NSView()
    private let messagesScroll = NSTextView.scrollableTextView()
    private var messages: NSTextView { messagesScroll.documentView as! NSTextView }
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "Run a query with ⌘↩ (current) or ⇧⌘↩ (all)")
    private let exportButton = NSButton(title: "Export…", target: nil, action: #selector(TabulaActions.exportData(_:)))
    /// For Copy Rows As ▸ SQL INSERT.
    var dialect: any Dialect = SQLiteDialect()

    private(set) var results: [ResultGridController] = []
    private var statements: [SQLStatementRange] = []
    /// Statement index → its result tab.
    private var resultForStatement: [Int: ResultGridController] = [:]
    /// Nil shows Messages.
    private var shown: ResultGridController?
    private var showsMessages = false
    private var runStart = ContinuousClock.now
    private(set) var failedStatement: Int?
    private var summary = ""

    override func loadView() {
        strip.onSelect = { [weak self] i in self?.select(tab: i) }
        strip.onClose = nil

        messages.isEditable = false
        messages.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        messages.textContainerInset = NSSize(width: 6, height: 6)
        messagesScroll.isHidden = true

        placeholder.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        exportButton.bezelStyle = .accessoryBarAction
        exportButton.controlSize = .small
        exportButton.font = .systemFont(ofSize: 11)
        exportButton.toolTip = "Export the shown result (⌘E)"
        exportButton.isHidden = true
        let bottom = NSStackView(views: [statusLabel, exportButton])
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bottom.heightAnchor.constraint(equalToConstant: 24).isActive = true
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
        updateStrip()
    }

    // MARK: - Run lifecycle

    func beginRun(_ statements: [SQLStatementRange]) {
        for r in results { r.view.removeFromSuperview() }
        results = []
        resultForStatement = [:]
        shown = nil
        showsMessages = false
        failedStatement = nil
        self.statements = statements
        runStart = .now
        placeholder.isHidden = true
        messages.string = ""
        summary = ""
        status("Running…")
        updateStrip()
    }

    func handle(_ event: ScriptRunner.Event) {
        switch event {
        case .started(let i):
            log(statementLine(i), color: .labelColor, time: true)
            status(statements.count > 1 ? "Running statement \(i + 1) of \(statements.count)…" : "Running…")
        case .columns(let i, let columns):
            let result = ResultGridController(columns: columns, statement: statements[i].text, number: results.count + 1)
            result.dialect = dialect
            results.append(result)
            resultForStatement[i] = result
            addChild(result)
            if shown == nil && !showsMessages { show(result) }
            updateStrip()
        case .rows(let i, let rows):
            resultForStatement[i]?.append(rows)
            if shown === resultForStatement[i] { updateStatus() }
        case .finished(let i, let outcome):
            resultForStatement[i]?.outcome = outcome
            log("  " + describe(outcome, returnsRows: resultForStatement[i] != nil), color: .secondaryLabelColor)
            if shown === resultForStatement[i] { updateStatus() }
        case .failed(let i, let message, let duration):
            failedStatement = failedStatement ?? i
            log("  Error: \(message) (\(format(duration)))", color: .systemRed)
            showMessages()
        case .done:
            finish(cancelled: false)
        }
    }

    /// The run was stopped by the user.
    func cancelled(atStatement index: Int?) {
        log("  Cancelled", color: .systemOrange)
        if let index { resultForStatement[index]?.wasCancelled = true }
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        let n = statements.count
        var parts = ["\(n) statement\(n == 1 ? "" : "s")"]
        if let f = failedStatement { parts.append("error in statement \(f + 1)") }
        if cancelled { parts.append("cancelled") }
        parts.append(format(.now - runStart))
        summary = parts.joined(separator: " · ")
        if shown == nil && !showsMessages { showMessages() }
        updateStatus()
        updateStrip()
    }

    // MARK: - Tabs

    private func updateStrip() {
        var items = results.map {
            TabStrip.Item(title: "Result \($0.number)", symbol: "tablecells", closable: false, toolTip: $0.statement)
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
        shown?.view.removeFromSuperview()
        showsMessages = false
        messagesScroll.isHidden = true
        shown = result
        exportButton.isHidden = false
        container.addSubview(result.view)
        result.view.translatesAutoresizingMaskIntoConstraints = false
        result.view.pin(to: container)
        updateStrip()
        updateStatus()
    }

    func showMessages() {
        shown?.view.removeFromSuperview()
        shown = nil
        exportButton.isHidden = true
        showsMessages = true
        messagesScroll.isHidden = false
        placeholder.isHidden = true
        updateStrip()
        updateStatus()
    }

    var showsMessagesTab: Bool { showsMessages }
    var messagesText: String { messages.string }
    var shownResult: ResultGridController? { shown }

    // MARK: - Messages and status

    private func statementLine(_ i: Int) -> String {
        let firstLine = statements[i].text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let more = statements[i].text.contains(where: \.isNewline) ? " …" : ""
        let text = firstLine.count > 160 ? firstLine.prefix(160) + "…" : firstLine + more
        return statements.count > 1 ? "[\(i + 1)] \(text)" : text
    }

    private func log(_ text: String, color: NSColor, time: Bool = false) {
        let stamp = time ? Self.time.string(from: Date()) + "  " : String(repeating: " ", count: 10)
        let line = NSAttributedString(string: stamp + text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color,
        ])
        messages.textStorage?.append(line)
        messages.scrollToEndOfDocument(nil)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func describe(_ outcome: ScriptRunner.Outcome, returnsRows: Bool) -> String {
        var parts: [String] = []
        if returnsRows {
            parts.append(rowsText(outcome.rowCount) + (outcome.truncated ? " (row limit reached)" : ""))
        } else if let n = outcome.rowsAffected {
            parts.append("\(n.formatted()) row\(n == 1 ? "" : "s") affected")
        } else {
            parts.append("OK")
        }
        parts.append(format(outcome.duration))
        return parts.joined(separator: " · ")
    }

    private func updateStatus() {
        if let shown {
            var parts = [rowsText(shown.rows.count)]
            if let o = shown.outcome {
                if o.truncated { parts[0] += " (row limit reached)" }
                parts.append(format(o.duration))
            } else if shown.wasCancelled {
                parts.append("cancelled")
            } else {
                parts.append("loading…")
            }
            if !summary.isEmpty, statements.count > 1 { parts.append(summary) }
            status(parts.joined(separator: " · "))
        } else if !summary.isEmpty {
            status(summary)
        }
    }

    private func status(_ text: String) {
        statusLabel.stringValue = text
    }

    private func rowsText(_ n: Int) -> String { "\(n.formatted()) row\(n == 1 ? "" : "s")" }

    private func format(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return ms < 1000 ? String(format: "%.0f ms", max(ms, 0)) : String(format: "%.2f s", ms / 1000)
    }
}

/// One result set in a read-only grid. Rows arrive in batches while the statement runs.
@MainActor
final class ResultGridController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let columns: [ResultColumn]
    let statement: String
    let number: Int
    private(set) var rows: [[DBValue]] = []
    var outcome: ScriptRunner.Outcome?
    var wasCancelled = false
    var dialect: any Dialect = SQLiteDialect()
    let grid = DataGrid()
    private var columnsSized = false
    private static let copyLimit = 100_000

    init(columns: [ResultColumn], statement: String, number: Int) {
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
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Rows", action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(CopyFormat.menuItem(target: self, action: #selector(copyRowsAs(_:))))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Export…", action: #selector(TabulaActions.exportData(_:)), keyEquivalent: "")
        grid.menu = menu
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

    func append(_ batch: [[DBValue]]) {
        let start = rows.count
        rows += batch
        if !columnsSized { sizeColumns(start..<rows.count) }
        if isViewLoaded { grid.noteNumberOfRowsChanged() }
    }

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
        cell.show(.value(rows[row][i]))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: GridRowView.identifier, owner: nil) as? GridRowView ?? GridRowView()
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
        guard !selection.isEmpty else { return NSSound.beep() }
        guard selection.count <= Self.copyLimit else { return NSSound.beep() }
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let ordered = selection.map { r in order.map { rows[r][$0] } }
        let text = format?.text(columns: order.map { columns[$0].name }, rows: ordered, dialect: dialect, table: nil)
            ?? CellText.tsv(ordered)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
