import AppCore
import AppKit
import DBKit

/// A table's rows in a virtual grid: the grid has one row per database row, and the row cache
/// fills in whatever is on screen.
@MainActor
final class TableDataViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table: TableRef

    private let connection: any DatabaseConnection
    let grid = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var browser: TableBrowser?
    private(set) var cache: RowCache?
    private var loadTask: Task<Void, Never>?
    private var columnsSized = false

    /// Copying more rows than this asks the user to narrow the selection.
    private static let copyLimit = 100_000

    init(connection: any DatabaseConnection, table: TableRef) {
        self.connection = connection
        self.table = table
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        grid.dataSource = self
        grid.delegate = self

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

        for label in [countLabel, statusLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let bar = NSStackView(views: [countLabel, NSView(), statusLabel])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let separator = NSBox()
        separator.boxType = .separator

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for v in [scroll, separator, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])
        view = root
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

    /// Re-reads columns and count, keeping the scroll position.
    func reload() {
        stop()
        statusLabel.stringValue = ""
        countLabel.stringValue = "Loading…"
        loadTask = Task {
            do {
                let browser = try await TableBrowser.open(table, on: connection)
                guard !Task.isCancelled else { return }
                if browser.columns != self.browser?.columns { install(browser.columns) }
                self.browser = browser
                countLabel.stringValue = "Counting rows…"

                let count = try await browser.count()
                guard !Task.isCancelled else { return }
                show(RowCache(rowCount: count, fetch: browser.fetcher()), columns: browser.columns.count)
            } catch {
                guard !Task.isCancelled else { return }
                cache = nil
                grid.reloadData()
                countLabel.stringValue = ""
                showError(error)
            }
        }
    }

    private func show(_ cache: RowCache, columns: Int) {
        cache.onLoad = { [weak self] rows in self?.rowsLoaded(rows) }
        cache.onError = { [weak self] error in self?.showError(error) }
        self.cache = cache
        countLabel.stringValue = Self.describe(count: cache.rowCount, columns: columns)
        grid.reloadData()
        visibleRowsChanged()
    }

    private func install(_ columns: [ColumnInfo]) {
        for c in grid.tableColumns.reversed() { grid.removeTableColumn(c) }
        for (i, info) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            column.title = info.name
            column.headerToolTip = info.typeName.isEmpty ? info.name : "\(info.name) — \(info.typeName)"
            column.minWidth = 40
            column.maxWidth = 2000
            column.width = min(320, max(70, GridCell.width(of: info.name, header: true)))
            grid.addTableColumn(column)
        }
        columnsSized = false
        grid.scrollRowToVisible(0)
    }

    @objc private func visibleRowsChanged() {
        guard let cache else { return }
        let visible = grid.rows(in: grid.visibleRect)
        cache.setVisibleRows(visible.location..<(visible.location + visible.length))
    }

    private func rowsLoaded(_ rows: Range<Int>) {
        if !columnsSized { sizeColumnsToContent(rows) }
        let visible = grid.rows(in: grid.visibleRect)
        let shown = rows.clamped(to: visible.location..<(visible.location + visible.length))
        guard !shown.isEmpty else { return }
        grid.reloadData(forRowIndexes: IndexSet(integersIn: shown), columnIndexes: IndexSet(integersIn: 0..<grid.numberOfColumns))
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

    private func showError(_ error: any Error) {
        statusLabel.stringValue = "\(error)"
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = "\(error)"
    }

    private static func describe(count: Int, columns: Int) -> String {
        let rows = count.formatted(.number)
        return "\(rows) \(count == 1 ? "row" : "rows") · \(columns) \(columns == 1 ? "column" : "columns")"
    }

    // MARK: - Grid

    func numberOfRows(in tableView: NSTableView) -> Int { cache?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
        if let values = cache?.row(at: row), index < values.count {
            cell.show(values[index])
        } else {
            cell.showPending()
        }
        return cell
    }

    // MARK: - Copy

    /// Copies selected rows as tab-separated text, in the grid's current column order.
    @objc func copy(_ sender: Any?) {
        guard let cache, let first = grid.selectedRowIndexes.first, let last = grid.selectedRowIndexes.last else {
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
        let selection = grid.selectedRowIndexes
        let order = grid.tableColumns.compactMap { Int($0.identifier.rawValue) }
        Task {
            do {
                let span = try await cache.rows(first..<(last + 1))
                let picked = selection.compactMap { $0 - first < span.count ? span[$0 - first] : nil }
                let text = CellText.tsv(picked.map { row in order.map { row[$0] } })
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                showError(error)
            }
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !grid.selectedRowIndexes.isEmpty }
        return true
    }
}

/// One grid cell. Frame-based layout: cells are created and reused constantly while scrolling.
private final class GridCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    private static let padding: CGFloat = 5

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: Self.padding, y: floor((bounds.height - Self.lineHeight) / 2),
            width: max(0, bounds.width - 2 * Self.padding), height: Self.lineHeight)
    }

    func show(_ value: DBValue) {
        if let text = CellText.display(value) {
            label.stringValue = text
            label.textColor = .labelColor
        } else {
            label.stringValue = "NULL"
            label.textColor = .tertiaryLabelColor
        }
    }

    func showPending() {
        label.stringValue = ""
    }

    /// Width a column needs to show `text` without truncating.
    static func width(of text: String, header: Bool) -> CGFloat {
        let font = header ? headerFont : font
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * padding + (header ? 14 : 4)
    }
}
