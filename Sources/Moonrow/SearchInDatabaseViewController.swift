import AppCore
import AppKit
import DBKit

/// The sidebar's Search pane (Search in Database…): a text looked for in every column of the
/// schema's tables, or the ones chosen, table by table on a session of its own. The list shows
/// each table with matching rows and how many; clicking one opens the table in a tab, filtered
/// by the search (the filter bar's Any column condition), so the tab shows exactly those rows.
@MainActor
final class SearchInDatabaseViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate
{
    /// The tables and views searched when nothing is chosen: the listed schema's.
    var tables: () -> [DatabaseObject] = { [] }
    /// Opens another session with the workspace's login.
    var openSession: (() async throws -> any DatabaseConnection)?
    /// Opens a table showing the rows that match the conditions: a single click previews it
    /// (`.preview`), a double-click keeps the tab.
    var onOpenRows: ((DatabaseObject, [FilterCondition], TabPlacement.Intent) -> Void)?

    let field: NSSearchField = SidebarSearchField()
    private let operatorPopup = NSPopUpButton()
    private let scopeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let startButton = NSButton(title: "Search", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    let list = NSTableView()
    /// Tables chosen in the scope menu; empty means every table.
    private(set) var chosen: [DatabaseObject] = []
    private(set) var results: [Result] = []
    private var task: Task<Void, Never>?
    private(set) var isSearching = false
    private var request: DatabaseSearch.Request?

    struct Result {
        let object: DatabaseObject
        let count: Int
    }

    override func loadView() {
        field.placeholderString = "Search in database"
        field.delegate = self
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(start(_:))
        for popup in [operatorPopup, scopeButton] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        for op in DatabaseSearch.Operator.allCases { operatorPopup.addItem(withTitle: op.title) }
        operatorPopup.toolTip = "How a value matches (case doesn't matter, except for =)"
        scopeButton.menu?.delegate = self
        scopeButton.toolTip = "Which tables to search"
        updateScopeTitle()
        startButton.controlSize = .small
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startOrStop(_:))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        list.addTableColumn(NSTableColumn(identifier: .init("hit")))
        list.headerView = nil
        list.style = .sourceList
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(doubleClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // One row: how to match, where, and the Search / Stop button at the right. In a narrow
        // sidebar the popups shrink, never the button.
        let controls = NSStackView(views: [operatorPopup, scopeButton, NSView(), startButton])
        controls.spacing = 6
        for popup in [operatorPopup, scopeButton] {
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        startButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        startButton.setContentHuggingPriority(.required, for: .horizontal)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        for v in [field, controls, statusLabel, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func focus() {
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Scope

    private var searchable: [DatabaseObject] { tables().filter(\.kind.isRelation) }

    private func updateScopeTitle() {
        // A count, never names: they can be long.
        let title = chosen.isEmpty ? "All tables" : "\(chosen.count) \(chosen.count == 1 ? "table" : "tables")"
        scopeButton.menu?.removeAllItems()
        scopeButton.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
    }

    /// The scope menu: All Tables, then each table and view (views only when chosen) with a
    /// checkmark when chosen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = menu.items.first?.title ?? ""
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let all = menu.addItem(withTitle: "All Tables", action: #selector(chooseAll(_:)), keyEquivalent: "")
        all.target = self
        all.state = chosen.isEmpty ? .on : .off
        menu.addItem(.separator())
        for object in searchable {
            let item = menu.addItem(withTitle: object.ref.name, action: #selector(toggleTable(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = object.ref.name
            item.state = chosen.contains(object) ? .on : .off
            item.image = NSImage(systemSymbolName: object.kind == .table ? "tablecells" : "eye", accessibilityDescription: nil)
        }
    }

    @objc private func chooseAll(_ sender: Any?) {
        chosen = []
        updateScopeTitle()
    }

    @objc private func toggleTable(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let object = searchable.first(where: { $0.ref.name == name })
        else { return }
        if let i = chosen.firstIndex(of: object) { chosen.remove(at: i) } else { chosen.append(object) }
        updateScopeTitle()
    }

    /// Searches only these (the harness, or a caller choosing for the user).
    func choose(_ objects: [DatabaseObject]) {
        chosen = objects
        updateScopeTitle()
    }

    // MARK: - Searching

    @objc private func startOrStop(_ sender: Any?) {
        isSearching ? stop() : start(sender)
    }

    @objc func start(_ sender: Any?) {
        let term = field.stringValue
        guard !term.isEmpty else { return }
        stop()
        // All Tables leaves views out: their rows are their tables' rows again.
        let scope = chosen.isEmpty ? searchable.filter { $0.kind == .table } : chosen
        let op = DatabaseSearch.Operator.allCases[max(0, operatorPopup.indexOfSelectedItem)]
        let request = DatabaseSearch.Request(term: term, op: op, tables: scope.map(\.ref))
        self.request = request
        let byRef = Dictionary(scope.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        results = []
        list.reloadData()
        guard let openSession else { return statusLabel.stringValue = "Search needs a session of its own, which this connection can't open." }
        setSearching(true)
        statusLabel.stringValue = "Connecting…"
        var failures: [String] = []
        task = Task {
            var session: (any DatabaseConnection)?
            defer {
                if let session { Task { await session.close() } }
            }
            do {
                session = try await openSession()
            } catch {
                setSearching(false)
                statusLabel.stringValue = "Couldn't open a session: \(error)"
                return
            }
            for await event in DatabaseSearch.run(request, on: session!) {
                switch event {
                case .searching(let table, let i, let n):
                    statusLabel.stringValue = "Searching \(table.name) (\(i + 1) of \(n))…"
                case .found(let hit):
                    results.append(Result(object: byRef[hit.table] ?? DatabaseObject(hit.table, kind: .table), count: hit.count))
                    list.reloadData()
                case .failed(let table, let message):
                    failures.append("\(table.name): \(message)")
                }
            }
            guard !Task.isCancelled else { return }
            setSearching(false)
            let rows = results.reduce(0) { $0 + $1.count }
            var text = rows == 0 ? "No rows match “\(term)”." :
                "\(rows.formatted()) \(rows == 1 ? "row" : "rows") in \(results.count) \(results.count == 1 ? "table" : "tables")."
            if !failures.isEmpty { text += "\nSkipped: " + failures.joined(separator: "; ") }
            statusLabel.stringValue = text
        }
    }

    /// Stops the search; the running statement is cancelled.
    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        setSearching(false)
        statusLabel.stringValue = "Stopped."
    }

    private func setSearching(_ on: Bool) {
        isSearching = on
        startButton.title = on ? "Stop" : "Search"
        if !on { task = nil }
    }

    // MARK: - Results

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let id = NSUserInterfaceItemIdentifier("Result")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        let isTable = result.object.kind == .table
        cell.show(result.object.ref.name, symbol: isTable ? "tablecells" : "eye", tint: isTable ? .systemBlue : .systemPurple,
                  detail: result.count.formatted())
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GreySelectionRowView() }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        results[row].object.ref.name
    }

    /// Selection that follows the selected tab, which opens nothing.
    private let quiet = QuietSelection()

    /// Selects the result the selected tab shows: its table, filtered by the search. Any other
    /// tab clears the selection. Opens nothing.
    func reveal(_ object: DatabaseObject?, filteredBy conditions: [FilterCondition]) {
        guard isViewLoaded else { return }
        let row = request.flatMap { request in
            object.flatMap { o in conditions.contains(request.condition) ? results.firstIndex { $0.object == o } : nil }
        }
        quiet.select(row, in: list)
    }

    /// A click (or arrow key) shows the table's matching rows in the preview tab; the focus stays
    /// in the list, so arrows go through the results.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !quiet.isActive, list.selectedRow >= 0 else { return }
        open(results[list.selectedRow], intent: .preview)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard list.clickedRow >= 0 else { return }
        open(results[list.clickedRow], intent: .regular)
    }

    /// Opens the table filtered by the search.
    func open(_ result: Result, intent: TabPlacement.Intent) {
        guard let request else { return }
        onOpenRows?(result.object, [request.condition], intent)
    }
}
