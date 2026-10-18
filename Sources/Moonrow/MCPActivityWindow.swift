import AppCore
import AppKit
import MCPServer

/// MCP Activity: what clients did (filtered by time, token and text), or the clients connected
/// now; the selected entry's details below.
@MainActor
final class MCPActivityWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum View: Int { case activity, clients }

    private let service: MCPService
    let viewSegment = NSSegmentedControl(labels: ["Activity", "Clients"], trackingMode: .selectOne, target: nil, action: nil)
    let rangePopup = NSPopUpButton()
    let tokenPopup = NSPopUpButton()
    let searchField = NSSearchField()
    let clearPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let table = NSTableView()
    let details = NSTextView()
    private(set) var entries: [MCPActivity] = []
    private(set) var clients: [MCPSessionInfo] = []
    private var load: Task<Void, Never>?
    private var tokenIDs: [UUID?] = [nil]
    private var split: NSSplitView?
    private var placedDivider = false

    static let ranges: [(String, TimeInterval?)] = [
        ("Last 24 Hours", 86_400), ("Last 7 Days", 7 * 86_400), ("Last 30 Days", 30 * 86_400), ("All Time", nil),
    ]

    init(service: MCPService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "MCP Activity"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 360)
        window.setFrameAutosaveName("MCPActivity")
        super.init(window: window)
        build()
        for name in [MCPActivityLog.didChange, MCPTokenStore.didChange, MCPService.stateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The details start at about a quarter of the height.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !placedDivider, let split else { return }
        placedDivider = true
        split.layoutSubtreeIfNeeded()
        split.setPosition(max(120, split.bounds.height - 170), ofDividerAt: 0)
    }

    private func build() {
        viewSegment.selectedSegment = 0
        viewSegment.target = self
        viewSegment.action = #selector(filterChanged(_:))
        rangePopup.addItems(withTitles: Self.ranges.map(\.0))
        rangePopup.selectItem(at: 1)
        rangePopup.target = self
        rangePopup.action = #selector(filterChanged(_:))
        tokenPopup.target = self
        tokenPopup.action = #selector(filterChanged(_:))
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        clearPopup.addItem(withTitle: "Clear")
        for (title, days) in [("Older Than 1 Day", 1), ("Older Than 7 Days", 7), ("Older Than 30 Days", 30), ("Everything", 0)] {
            let item = NSMenuItem(title: title, action: #selector(clear(_:)), keyEquivalent: "")
            item.target = self
            item.tag = days
            clearPopup.menu?.addItem(item)
        }
        exportButton.target = self
        exportButton.action = #selector(exportCSV(_:))
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [viewSegment, rangePopup, tokenPopup, searchField, spacer, disconnectButton, clearPopup, exportButton])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.textContainerInset = NSSize(width: 8, height: 8)
        let detailScroll = NSScrollView()
        detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true
        details.autoresizingMask = [.width]
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailScroll)
        // The table takes what the window gains; the details keep their height.
        split.setHoldingPriority(.init(240), forSubviewAt: 0)
        split.setHoldingPriority(.init(260), forSubviewAt: 1)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        self.split = split
        let root = NSStackView(views: [bar, split])
        root.orientation = .vertical
        root.spacing = 0
        window?.contentView = root
        configureColumns()
    }

    private func configureColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        let columns: [(String, String, CGFloat)] = view == .activity
            ? [("status", "Status", 64), ("time", "Time", 150), ("category", "Category", 70), ("action", "Action", 170),
               ("token", "Token", 120), ("client", "Client", 100), ("address", "Address", 80), ("details", "Details", 300)]
            : [("client", "Client", 160), ("version", "Version", 80), ("token", "Token", 140), ("prefix", "Prefix", 100),
               ("address", "Address", 110), ("connected", "Connected", 150), ("last", "Last Activity", 150)]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
    }

    var view: View { View(rawValue: viewSegment.selectedSegment) ?? .activity }

    @objc private func filterChanged(_ sender: Any?) {
        if sender as? NSSegmentedControl === viewSegment {
            configureColumns()
            table.reloadData()
        }
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { scheduleReload() }

    private func scheduleReload() {
        load?.cancel()
        load = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        let tokens = service.tokens.tokens.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedToken = tokenIDs.indices.contains(tokenPopup.indexOfSelectedItem) ? tokenIDs[tokenPopup.indexOfSelectedItem] : nil
        tokenPopup.removeAllItems()
        tokenPopup.addItem(withTitle: "All Tokens")
        tokenIDs = [nil] + tokens.map(\.id)
        for t in tokens { tokenPopup.addItem(withTitle: "\(t.name) (\(t.prefix)…)") }
        tokenPopup.selectItem(at: tokenIDs.firstIndex(of: selectedToken) ?? 0)
        let range = Self.ranges[max(0, rangePopup.indexOfSelectedItem)].1
        let filter = MCPActivityLog.Filter(since: range.map { Date().addingTimeInterval(-$0) }, tokenID: selectedToken,
                                           search: searchField.stringValue)
        rangePopup.isHidden = view == .clients
        searchField.isHidden = view == .clients
        clearPopup.isHidden = view == .clients
        exportButton.isHidden = view == .clients
        disconnectButton.isHidden = view != .clients
        let service = service
        Task {
            if view == .activity {
                entries = (try? await service.log.entries(filter)) ?? []
            } else {
                clients = await service.sessions.all.filter { selectedToken == nil || $0.tokenID == selectedToken }
            }
            table.reloadData()
            showDetails()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { view == .activity ? entries.count : clients.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        var color = NSColor.labelColor
        // The view can change before its rows are loaded.
        guard view == .activity ? entries.indices.contains(row) : clients.indices.contains(row) else { return nil }
        if view == .activity {
            let e = entries[row]
            switch id {
            case "status":
                text = e.status.rawValue.capitalizedFirst
                color = switch e.status { case .success: .systemGreen; case .denied: .systemOrange; case .error: .systemRed }
            case "time": text = e.timestamp.formatted(date: .abbreviated, time: .standard)
            case "category": text = e.category.rawValue
            case "action": text = e.action
            case "token": text = e.tokenName.map { "\($0) (\(e.tokenPrefix ?? "")…)" } ?? ""
            case "client": text = e.client ?? ""
            case "address": text = e.clientAddress ?? ""
            default: text = [e.query, e.details].compactMap { $0 }.joined(separator: " — ").replacingOccurrences(of: "\n", with: " ")
            }
        } else {
            let c = clients[row]
            text = switch id {
            case "client": c.clientName.isEmpty ? "Unknown" : c.clientName
            case "version": c.clientVersion
            case "token": c.tokenName
            case "prefix": c.tokenPrefix + "…"
            case "address": c.clientAddress
            case "connected": c.createdAt.formatted(date: .abbreviated, time: .standard)
            default: c.lastActivity.formatted(date: .abbreviated, time: .standard)
            }
        }
        let cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = tableColumn!.identifier
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        cell.stringValue = text
        cell.textColor = color
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showDetails() }

    private func showDetails() {
        let row = table.selectedRow
        disconnectButton.isEnabled = view == .clients && clients.indices.contains(row)
        guard view == .activity, entries.indices.contains(row) else {
            details.string = ""
            return
        }
        let e = entries[row]
        var lines = [
            "\(e.action) — \(e.status.rawValue)",
            "Time: \(e.timestamp.formatted(date: .complete, time: .standard))",
        ]
        if let t = e.tokenName { lines.append("Token: \(t) (\(e.tokenPrefix ?? "")…)") }
        if let c = e.client, !c.isEmpty { lines.append("Client: \(c)") }
        if let a = e.clientAddress { lines.append("Address: \(a)") }
        if let id = e.connectionID {
            lines.append("Connection: " + ((NSApp.delegate as? AppDelegate)?.store.connection(id: id)?.displayName ?? id.uuidString))
        }
        if let d = e.details { lines.append("\n" + d) }
        if let q = e.query { lines.append("\n" + q) }
        details.string = lines.joined(separator: "\n")
    }

    @objc private func clear(_ sender: NSMenuItem) {
        let days = sender.tag
        let log = service.log
        Task {
            _ = try? await log.clear(olderThan: days == 0 ? nil : Date().addingTimeInterval(-Double(days) * 86_400))
            reload()
        }
    }

    @objc private func exportCSV(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = "moonrow-activity-\(stamp.string(from: Date())).csv"
        let csv = MCPActivityLog.csv(entries)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch {
                present(error, title: "Couldn't export the activity", in: window)
            }
        }
    }

    @objc private func disconnect(_ sender: Any?) {
        guard clients.indices.contains(table.selectedRow) else { return }
        let id = clients[table.selectedRow].id
        let sessions = service.sessions
        Task {
            await sessions.end(id, .disconnected)
            reload()
        }
    }
}
