import AppCore
import AppKit
import MCPServer

/// Settings ▸ MCP: the server, how clients reach it, and the access tokens.
@MainActor
final class MCPPreferences: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: SettingsStore
    private let store: ConnectionStore
    private let service: () -> MCPService
    /// Settings ▸ MCP ▸ Activity…
    var onShowActivity: (() -> Void)?

    let enableCheckbox = NSButton(checkboxWithTitle: "Enable MCP server", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let portField = NSTextField()
    let remoteCheckbox = NSButton(checkboxWithTitle: "Allow connections from other computers, over TLS", target: nil, action: nil)
    private let remoteHint = NSTextField(wrappingLabelWithString: "")
    let exportButton = NSButton(title: "Export Certificate…", target: nil, action: nil)
    let approvalCheckbox = NSButton(checkboxWithTitle: "Ask before running statements that may change data", target: nil, action: nil)
    let autoTokenCheckbox = NSButton(checkboxWithTitle: "Make an access token for moonrow-mcp", target: nil, action: nil)
    let clientSegment = NSSegmentedControl(labels: ["Claude Code", "Codex", "JSON", "HTTP"], trackingMode: .selectOne, target: nil, action: nil)
    let setupText = NSTextView()
    let tokenTable = NSTableView()
    let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private(set) var tokens: [MCPToken] = []
    /// The Add… sheet while it's open, for the dev harness.
    private(set) var tokenSheet: MCPTokenSheet?

    init(settings: SettingsStore, store: ConnectionStore, service: @escaping () -> MCPService) {
        self.settings = settings
        self.store = store
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func hint(_ text: String, width: CGFloat = 470) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = width
        return f
    }

    override func loadView() {
        for b in [enableCheckbox, remoteCheckbox, approvalCheckbox, autoTokenCheckbox] {
            b.target = self
            b.action = #selector(changed(_:))
        }
        statusLabel.textColor = .secondaryLabelColor
        let port = NumberFormatter()
        port.allowsFloats = false
        port.usesGroupingSeparator = false
        port.minimum = NSNumber(value: AppSettings.mcpPorts.lowerBound)
        port.maximum = NSNumber(value: AppSettings.mcpPorts.upperBound)
        portField.formatter = port
        portField.alignment = .right
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        portField.target = self
        portField.action = #selector(changed(_:))
        exportButton.target = self
        exportButton.action = #selector(exportCertificate(_:))
        remoteHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remoteHint.textColor = .secondaryLabelColor
        remoteHint.preferredMaxLayoutWidth = 470
        remoteHint.isSelectable = true
        clientSegment.target = self
        clientSegment.action = #selector(clientChanged(_:))
        clientSegment.selectedSegment = UserDefaults.standard.integer(forKey: "MCPClientSetup")

        setupText.isEditable = false
        setupText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        setupText.textContainerInset = NSSize(width: 6, height: 6)
        setupText.isHorizontallyResizable = false
        let setupScroll = NSScrollView()
        setupScroll.documentView = setupText
        setupScroll.hasVerticalScroller = true
        setupScroll.borderType = .bezelBorder
        setupScroll.translatesAutoresizingMaskIntoConstraints = false
        setupScroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        setupScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        setupText.autoresizingMask = [.width]
        let copy = NSButton(title: "Copy", target: self, action: #selector(copySetup(_:)))
        let setupHeader = NSStackView(views: [clientSegment, copy])
        setupHeader.spacing = 8

        for (id, title, width) in [("name", "Name", 110.0), ("prefix", "Prefix", 90.0), ("permission", "Permission", 100.0),
                                   ("connections", "Connections", 110.0), ("status", "Status", 60.0), ("used", "Last Used", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tokenTable.addTableColumn(column)
        }
        tokenTable.dataSource = self
        tokenTable.delegate = self
        tokenTable.usesAlternatingRowBackgroundColors = true
        tokenTable.allowsMultipleSelection = false
        tokenTable.style = .inset
        tokenTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let tableScroll = NSScrollView()
        tableScroll.documentView = tokenTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.widthAnchor.constraint(equalToConstant: 652).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let add = NSButton(title: "Add…", target: self, action: #selector(addToken(_:)))
        revokeButton.target = self
        revokeButton.action = #selector(revokeToken(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteToken(_:))
        let activity = NSButton(title: "Activity…", target: self, action: #selector(showActivity(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tokenButtons = NSStackView(views: [add, revokeButton, deleteButton, spacer, activity])
        tokenButtons.spacing = 8

        let serverRow = NSStackView(views: [enableCheckbox, statusLabel])
        serverRow.spacing = 12
        let remoteRow = NSStackView(views: [remoteCheckbox, exportButton])
        remoteRow.spacing = 12
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server"), serverRow],
            [NSTextField(labelWithString: "Preferred port"), portField],
            [NSGridCell.emptyContentView, Self.hint("When the port is busy, the next free one is used. Statements run on the connections open in Moonrow, with each connection's safe mode.")],
            [NSTextField(labelWithString: "Remote access"), remoteRow],
            [NSGridCell.emptyContentView, remoteHint],
            [NSTextField(labelWithString: "Approval"), approvalCheckbox],
            [NSGridCell.emptyContentView, Self.hint("A statement from a client waits for Allow in its workspace, and is denied after 30 seconds. Safe mode asks as well, when it's on.")],
            [NSTextField(labelWithString: "moonrow-mcp"), autoTokenCheckbox],
            [NSGridCell.emptyContentView, Self.hint("The bridge for clients that start their MCP servers as programs. With this on, it finds a Full Access token by itself; otherwise set MOONROW_MCP_ACCESS_TOKEN in the client's configuration.")],
            [NSTextField(labelWithString: "Client setup"), setupHeader],
            [NSGridCell.emptyContentView, setupScroll],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let tokensLabel = NSTextField(labelWithString: "Access tokens")
        tokensLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [grid, tokensLabel, tableScroll, tokenButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            tokenButtons.widthAnchor.constraint(equalTo: tableScroll.widthAnchor),
        ])
        root.widthAnchor.constraint(equalToConstant: 700).isActive = true
        view = root
        NotificationCenter.default.addObserver(forName: MCPService.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: MCPTokenStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTokens() }
        }
        refresh()
        reloadTokens()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        reloadTokens()
    }

    func refresh() {
        let s = settings.settings
        enableCheckbox.state = s.mcpEnabled ? .on : .off
        portField.integerValue = s.mcpPort
        remoteCheckbox.state = s.mcpRemote ? .on : .off
        approvalCheckbox.state = s.mcpApproval ? .on : .off
        autoTokenCheckbox.state = s.mcpAutoToken ? .on : .off
        let state = service().state
        switch state {
        case .stopped: statusLabel.stringValue = s.mcpEnabled ? "Starting…" : "Stopped"
        case .running(let port, let tls, _): statusLabel.stringValue = "Running on \(tls ? "every interface" : "127.0.0.1"), port \(port)"
        case .failed(let message): statusLabel.stringValue = "Couldn't start: \(message)"
        }
        statusLabel.textColor = if case .failed = state { .systemRed } else { .secondaryLabelColor }
        exportButton.isEnabled = s.mcpRemote
        if case .running(_, true, let fingerprint?) = state {
            remoteHint.stringValue = "Clients on other computers need the certificate (Export Certificate…) or its SHA-256 fingerprint: \(fingerprint)"
        } else {
            remoteHint.stringValue = "Listens on every network interface instead of this Mac only. The server's certificate is self-signed; clients pin it."
        }
        setupText.string = setupSnippet()
    }

    // MARK: - Client setup

    /// moonrow-mcp's path: next to the app's executable.
    static var bridgePath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "moonrow-mcp").path
            ?? "/Applications/Moonrow.app/Contents/MacOS/moonrow-mcp"
    }

    func setupSnippet() -> String {
        let s = settings.settings
        let path = Self.bridgePath
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let port: Int = if case .running(let p, _, _) = service().state { p } else { s.mcpPort }
        let scheme = s.mcpRemote ? "https" : "http"
        switch clientSegment.selectedSegment {
        case 1:
            return s.mcpAutoToken ? "codex mcp add moonrow -- \(quoted)"
                : "codex mcp add moonrow --env MOONROW_MCP_ACCESS_TOKEN=YOUR_TOKEN -- \(quoted)"
        case 2:
            var server: JSONValue = ["command": .string(path)]
            if !s.mcpAutoToken { server = ["command": .string(path), "env": ["MOONROW_MCP_ACCESS_TOKEN": "YOUR_TOKEN"]] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let json: JSONValue = ["mcpServers": ["moonrow": server]]
            return (try? String(decoding: encoder.encode(json), as: UTF8.self)) ?? ""
        case 3:
            return """
                URL: \(scheme)://127.0.0.1:\(port)/mcp
                Transport: Streamable HTTP
                Header: Authorization: Bearer YOUR_TOKEN
                claude mcp add --transport http moonrow \(scheme)://127.0.0.1:\(port)/mcp --header "Authorization: Bearer YOUR_TOKEN"
                """
        default:
            return s.mcpAutoToken ? "claude mcp add moonrow -- \(quoted)"
                : "claude mcp add moonrow -e MOONROW_MCP_ACCESS_TOKEN=YOUR_TOKEN -- \(quoted)"
        }
    }

    @objc private func clientChanged(_ sender: Any?) {
        UserDefaults.standard.set(clientSegment.selectedSegment, forKey: "MCPClientSetup")
        setupText.string = setupSnippet()
    }

    @objc private func copySetup(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupSnippet(), forType: .string)
    }

    // MARK: - Settings

    @objc private func changed(_ sender: Any?) {
        let enabled = enableCheckbox.state == .on
        let port = portField.stringValue.isEmpty ? AppSettings().mcpPort : portField.integerValue
        let remote = remoteCheckbox.state == .on
        let approval = approvalCheckbox.state == .on
        let auto = autoTokenCheckbox.state == .on
        do {
            try settings.update {
                $0.mcpEnabled = enabled
                $0.mcpPort = AppSettings.mcpPorts.contains(port) ? port : AppSettings().mcpPort
                $0.mcpRemote = remote
                $0.mcpApproval = approval
                $0.mcpAutoToken = auto
            }
        } catch {
            report(error, title: "Couldn't save the setting", in: view.window)
        }
        refresh()
    }

    @objc private func exportCertificate(_ sender: Any?) {
        guard let window = view.window else { return }
        let pem: String
        do { pem = try service().certificatePEM() } catch {
            return report(error, title: "Couldn't make the certificate", in: window)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "moonrow-mcp.pem"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try pem.write(to: url, atomically: true, encoding: .utf8) } catch {
                report(error, title: "Couldn't save the certificate", in: window)
            }
        }
    }

    @objc private func showActivity(_ sender: Any?) { onShowActivity?() }

    // MARK: - Tokens

    func reloadTokens() {
        tokens = service().tokens.tokens.sorted { $0.createdAt > $1.createdAt }
        tokenTable.reloadData()
        updateTokenButtons()
    }

    private var selectedToken: MCPToken? { tokens.indices.contains(tokenTable.selectedRow) ? tokens[tokenTable.selectedRow] : nil }

    private func updateTokenButtons() {
        revokeButton.isEnabled = selectedToken?.isActive == true
        deleteButton.isEnabled = selectedToken != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tokens.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateTokenButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let t = tokens[row]
        let text: String = switch id {
        case "name": t.name
        case "prefix": t.prefix + "…"
        case "permission": t.permission.title
        case "connections": MCPService.describe(t.access).capitalizedFirst
        case "status": t.status
        default: t.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
        }
        let cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = tableColumn!.identifier
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        cell.stringValue = text
        cell.font = id == "prefix" ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        cell.textColor = t.isUsable ? .labelColor : .secondaryLabelColor
        return cell
    }

    @objc func addToken(_ sender: Any?) {
        guard let window = view.window else { return }
        let sheet = MCPTokenSheet(store: store) { [weak self] name, permission, access in
            guard let self else { throw CancellationError() }
            return try await self.service().createToken(name: name, permission: permission, access: access).1
        }
        tokenSheet = sheet
        sheet.onClose = { [weak self] in self?.tokenSheet = nil }
        window.beginSheet(sheet.window!)
    }

    @objc private func revokeToken(_ sender: Any?) {
        guard let token = selectedToken, let window = view.window else { return }
        confirm("Revoke “\(token.name)”?", "Clients using it are disconnected and can't connect with it again. It stays listed until you delete it.",
                button: "Revoke", in: window) { [weak self] in
            guard let self else { return }
            Task { do { try await self.service().revokeToken(id: token.id) } catch { report(error, title: "Couldn't revoke the token", in: window) } }
        }
    }

    @objc private func deleteToken(_ sender: Any?) {
        guard let token = selectedToken, let window = view.window else { return }
        confirm("Delete “\(token.name)”?", "Clients using it are disconnected and can't connect with it again.",
                button: "Delete", in: window) { [weak self] in
            guard let self else { return }
            Task { do { try await self.service().deleteToken(id: token.id) } catch { report(error, title: "Couldn't delete the token", in: window) } }
        }
    }

    private func confirm(_ title: String, _ detail: String, button: String, in window: NSWindow, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
    }
}

/// The app's error alert (a view controller's own `present` would hide it).
@MainActor
private func report(_ error: any Error, title: String, in window: NSWindow?) {
    present(error, title: title, in: window)
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Add…: a token's name, permission and connections, then the token, shown once.
@MainActor
final class MCPTokenSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConnectionStore
    private let create: (String, MCPPermission, MCPConnectionAccess) async throws -> String
    var onClose: (() -> Void)?

    let nameField = NSTextField()
    let permissionPopup = NSPopUpButton()
    let allButton = NSButton(radioButtonWithTitle: "All connections", target: nil, action: nil)
    let someButton = NSButton(radioButtonWithTitle: "These connections:", target: nil, action: nil)
    let connectionTable = NSTableView()
    let generateButton = NSButton(title: "Generate Token", target: nil, action: nil)
    let tokenField = NSTextField(labelWithString: "")
    private let form = NSStackView()
    private let result = NSStackView()
    private(set) var chosen: Set<UUID> = []
    private var connections: [ConnectionConfig] { store.connections }

    init(store: ConnectionStore, create: @escaping (String, MCPPermission, MCPConnectionAccess) async throws -> String) {
        self.store = store
        self.create = create
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "New Access Token"
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        nameField.placeholderString = "Untitled Token"
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        permissionPopup.addItems(withTitles: MCPPermission.allCases.map(\.title))
        permissionPopup.selectItem(at: 0)
        let permissionHint = NSTextField(wrappingLabelWithString:
            "Read Only runs reads and reads resources. Read & Write also runs statements that may change data. Full Access also opens and closes connections.")
        permissionHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionHint.textColor = .secondaryLabelColor
        permissionHint.preferredMaxLayoutWidth = 360
        for b in [allButton, someButton] {
            b.target = self
            b.action = #selector(accessChanged(_:))
        }
        allButton.state = .on
        let check = NSTableColumn(identifier: .init("check"))
        check.width = 24
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 250
        let place = NSTableColumn(identifier: .init("place"))
        place.width = 150
        for c in [check, name, place] { connectionTable.addTableColumn(c) }
        connectionTable.headerView = nil
        connectionTable.dataSource = self
        connectionTable.delegate = self
        connectionTable.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = connectionTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Permission"), permissionPopup],
            [NSGridCell.emptyContentView, permissionHint],
            [NSTextField(labelWithString: "Connections"), allButton],
            [NSGridCell.emptyContentView, someButton],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        generateButton.target = self
        generateButton.action = #selector(generate(_:))
        generateButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, generateButton])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        for v in [grid, scroll, buttons] as [NSView] { form.addArrangedSubview(v) }
        buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        tokenField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tokenField.isSelectable = true
        tokenField.lineBreakMode = .byCharWrapping
        let note = NSTextField(wrappingLabelWithString: "Copy the token now: it isn't shown again. Moonrow keeps only a hash of it.")
        note.preferredMaxLayoutWidth = 460
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyToken(_:)))
        let done = NSButton(title: "Done", target: self, action: #selector(cancel(_:)))
        done.keyEquivalent = "\r"
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        let resultButtons = NSStackView(views: [copy, spacer2, done])
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 12
        for v in [note, tokenField, resultButtons] as [NSView] { result.addArrangedSubview(v) }
        resultButtons.widthAnchor.constraint(equalToConstant: 460).isActive = true
        result.isHidden = true

        let root = NSStackView(views: [form, result])
        root.orientation = .vertical
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = root
        updateTable()
    }

    private func updateTable() {
        connectionTable.isEnabled = someButton.state == .on
        connectionTable.alphaValue = someButton.state == .on ? 1 : 0.5
        generateButton.isEnabled = allButton.state == .on || !chosen.isEmpty
    }

    @objc private func accessChanged(_ sender: Any?) { updateTable() }

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = connections[row]
        switch tableColumn?.identifier.rawValue {
        case "check":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.tag = row
            box.state = chosen.contains(c.id) ? .on : .off
            return box
        case "name":
            let group = c.groupID.flatMap { id in store.groups.first { $0.id == id }?.name }
            return NSTextField(labelWithString: group.map { "\($0) ▸ \(c.displayName)" } ?? c.displayName)
        default:
            let f = NSTextField(labelWithString: c.driver.displayName + " · " + c.place)
            f.textColor = .secondaryLabelColor
            f.lineBreakMode = .byTruncatingTail
            return f
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        let id = connections[sender.tag].id
        if sender.state == .on { chosen.insert(id) } else { chosen.remove(id) }
        updateTable()
    }

    /// For the dev harness.
    func choose(_ ids: Set<UUID>) {
        chosen = ids
        someButton.state = .on
        connectionTable.reloadData()
        updateTable()
    }

    @objc func generate(_ sender: Any?) {
        let permission = MCPPermission.allCases[max(0, permissionPopup.indexOfSelectedItem)]
        let access: MCPConnectionAccess = allButton.state == .on ? .all : .only(chosen)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        generateButton.isEnabled = false
        Task {
            do {
                let token = try await create(name, permission, access)
                tokenField.stringValue = token
                form.isHidden = true
                result.isHidden = false
                window?.title = "Access Token"
            } catch {
                generateButton.isEnabled = true
                present(error, title: "Couldn't make the token", in: window)
            }
        }
    }

    @objc private func copyToken(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tokenField.stringValue, forType: .string)
    }

    @objc func cancel(_ sender: Any?) {
        if let window { window.sheetParent?.endSheet(window) }
        onClose?()
    }
}
