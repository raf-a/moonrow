import AppCore
import AppKit
import WireSupport

/// Creates or edits a saved connection: a file for SQLite, a server for the others.
@MainActor
final class ConnectionFormWindowController: NSWindowController, NSWindowDelegate {
    private(set) var config: ConnectionConfig
    private let isNew: Bool
    private let store: ConnectionStore
    private let secrets: any SecretStore
    /// Where the app keeps its data; queries folders given by name are in its `Queries`.
    private let dataRoot: URL

    /// Asked to connect with the saved config and the password typed in the form.
    var onConnect: ((ConnectionConfig, String?) -> Void)?
    /// How Test logs in to the SSH server, given the SSH password and key passphrase typed.
    var sshLogin: ((ConnectionConfig, String?, String?) -> SSHLogin)?
    var onClose: (() -> Void)?
    /// Whether a workspace on the connection is open; the form then says when edits apply.
    var isOpenInWorkspace: ((UUID) -> Bool)? {
        didSet { showOpenNote() }
    }
    let openNote = NSTextField(wrappingLabelWithString: "")
    /// Before an edited connection that uses another queries folder is saved: moves or copies
    /// the old folder's queries (or leaves them, nil) and switches its open workspaces over.
    var onQueriesFolderChange: ((ConnectionConfig, SavedQueries.FolderChange, SavedQueries.Transfer?) throws -> Void)?

    private let driverPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let pathField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let passwordModePopup = NSPopUpButton()
    private let databaseField = NSTextField()
    private let tlsPopup = NSPopUpButton()
    private let negotiationPopup = NSPopUpButton()
    private let serverNameField = NSTextField()
    private let caField = NSTextField()
    private let certField = NSTextField()
    private let keyField = NSTextField()
    let tagPopup = NSPopUpButton()
    /// The tag picked in `tagPopup`; kept apart so Edit Tags… doesn't change it.
    private var tagID: UUID?
    /// Edit Tags…, while it's open.
    private(set) var tagsSheet: TagsSheet?
    private let safeModePopup = NSPopUpButton()
    private let safeModeHint = NSTextField(wrappingLabelWithString: "")
    private let readOnlyBox = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    let queriesField = NSTextField()
    /// The bootstrap SQL as last typed in its popover.
    private var bootstrapSQL = ""
    private let bootstrapLabel = NSTextField(labelWithString: "")
    private(set) var bootstrapPopover: NSPopover?
    private let sshBox = NSButton(checkboxWithTitle: "Connect through an SSH server", target: nil, action: nil)
    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshUserField = NSTextField()
    private let sshPasswordField = NSSecureTextField()
    private let sshPasswordModePopup = NSPopUpButton()
    private let sshKeyBox = NSButton(checkboxWithTitle: "Use a private key", target: nil, action: nil)
    private let sshKeyField = NSTextField()
    private let sshPassphraseField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    /// Shown after Test when the server is the other kind of the MySQL family.
    let changeTypeButton = NSButton(title: "", target: nil, action: nil)
    private var suggestedDriver: DriverKind?
    private let spinner = NSProgressIndicator()
    private let grid = NSGridView()
    private var fileRows: [Int] = []
    private var serverRows: [Int] = []
    private var postgresRows: [Int] = []
    private var mysqlRows: [Int] = []
    private var sshRows: [Int] = []
    private var sshKeyRows: [Int] = []
    private var testTask: Task<Void, Never>?

    init(config: ConnectionConfig, isNew: Bool, store: ConnectionStore, secrets: any SecretStore, dataRoot: URL) {
        self.config = config
        self.isNew = isNew
        self.store = store
        self.secrets = secrets
        self.dataRoot = dataRoot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Only workspace windows merge into native tabs.
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        show(config)
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: ConnectionStore.didChange, object: store)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        testTask?.cancel()
        onClose?()
    }

    private var driver: DriverKind { DriverKind.allCases[max(0, driverPopup.indexOfSelectedItem)] }

    // MARK: - Layout

    private func makeContent() -> NSView {
        driverPopup.addItems(withTitles: DriverKind.allCases.map(\.displayName))
        driverPopup.target = self
        driverPopup.action = #selector(driverChanged(_:))
        nameField.placeholderString = "Optional"
        pathField.placeholderString = "/path/to/database.sqlite"
        pathField.lineBreakMode = .byTruncatingMiddle
        hostField.placeholderString = "127.0.0.1, or a socket path"
        portField.alignment = .right
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        passwordModePopup.addItems(withTitles: ["Save in Keychain", "Ask every time", "No password"])
        passwordModePopup.target = self
        passwordModePopup.action = #selector(passwordModeChanged(_:))
        tlsPopup.target = self
        tlsPopup.action = #selector(tlsModeChanged(_:))
        negotiationPopup.addItems(withTitles: ["PostgreSQL", "Direct"])
        negotiationPopup.toolTip = "Direct starts TLS at once, without asking the server first (PostgreSQL 17 and later)."
        serverNameField.placeholderString = "Same as the host"
        for f in [caField, certField, keyField] {
            f.placeholderString = "None"
            f.lineBreakMode = .byTruncatingMiddle
        }

        sshBox.target = self
        sshBox.action = #selector(sshChanged(_:))
        sshHostField.placeholderString = "Host name, IP or ~/.ssh/config alias"
        sshPortField.alignment = .right
        sshPortField.placeholderString = "22"
        sshPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        sshUserField.placeholderString = NSUserName()
        sshPasswordModePopup.addItems(withTitles: ["Save in Keychain", "Ask every time", "No password"])
        sshPasswordModePopup.target = self
        sshPasswordModePopup.action = #selector(passwordModeChanged(_:))
        sshPasswordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sshKeyBox.target = self
        sshKeyBox.action = #selector(sshChanged(_:))
        sshKeyField.placeholderString = "~/.ssh/id_ed25519"
        sshKeyField.lineBreakMode = .byTruncatingMiddle
        sshPassphraseField.placeholderString = "Asked for when needed"
        queriesField.placeholderString = "Same as the name"
        queriesField.lineBreakMode = .byTruncatingMiddle
        let sshHint = NSTextField(wrappingLabelWithString:
            "Without a key file, ssh uses your ~/.ssh/config, the SSH agent and your default keys. "
            + "Host and port above are as the SSH server sees them.")
        sshHint.textColor = .secondaryLabelColor
        sshHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sshHint.preferredMaxLayoutWidth = 360

        tagPopup.target = self
        tagPopup.action = #selector(tagChanged(_:))
        safeModePopup.addItems(withTitles: SafeMode.allCases.map(\.title))
        safeModePopup.target = self
        safeModePopup.action = #selector(safeModeChanged(_:))
        safeModeHint.textColor = .secondaryLabelColor
        safeModeHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        safeModeHint.preferredMaxLayoutWidth = 360

        let hostRow = row(hostField, NSTextField(labelWithString: "Port"), portField)
        let passwordRow = row(passwordField, passwordModePopup)
        passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let rows: [(String, NSView, Kind)] = [
            ("Type", driverPopup, .both),
            ("Name", nameField, .both),
            ("Tag", tagPopup, .both),
            ("Database file", row(pathField, button("Choose…", #selector(chooseFile(_:)))), .file),
            ("Host", hostRow, .server),
            ("User", userField, .server),
            ("Password", passwordRow, .both),
            ("Database", databaseField, .server),
            ("TLS", tlsPopup, .server),
            ("TLS negotiation", negotiationPopup, .postgres),
            ("SNI server name", serverNameField, .mysql),
            ("CA certificate", row(caField, button("Choose…", #selector(chooseCA(_:)))), .server),
            ("Client certificate", row(certField, button("Choose…", #selector(chooseCert(_:)))), .server),
            ("Client key", row(keyField, button("Choose…", #selector(chooseKey(_:)))), .server),
            ("SSH", sshBox, .server),
            ("SSH server", row(sshHostField, NSTextField(labelWithString: "Port"), sshPortField), .ssh),
            ("SSH user", sshUserField, .ssh),
            ("SSH password", row(sshPasswordField, sshPasswordModePopup), .ssh),
            ("", sshKeyBox, .ssh),
            ("Key file", row(sshKeyField, button("Choose…", #selector(chooseSSHKey(_:)))), .sshKey),
            ("Passphrase", sshPassphraseField, .sshKey),
            ("", sshHint, .ssh),
            ("Safe mode", safeModePopup, .both),
            ("", safeModeHint, .both),
            ("", readOnlyBox, .both),
            ("Queries folder", row(queriesField, button("Choose…", #selector(chooseQueriesFolder(_:)))), .both),
            ("Bootstrap", row(bootstrapLabel, button("Edit…", #selector(editBootstrap(_:)))), .both),
        ]
        for (i, (title, view, kind)) in rows.enumerated() {
            grid.addRow(with: [title.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: title), view])
            if kind == .file { fileRows.append(i) }
            if kind == .server || kind == .postgres || kind == .mysql { serverRows.append(i) }
            if kind == .postgres { postgresRows.append(i) }
            if kind == .mysql { mysqlRows.append(i) }
            if kind == .ssh || kind == .sshKey { sshRows.append(i) }
            if kind == .sshKey { sshKeyRows.append(i) }
        }
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        changeTypeButton.target = self
        changeTypeButton.action = #selector(changeType(_:))
        changeTypeButton.controlSize = .small
        changeTypeButton.isHidden = true
        let statusRow = NSStackView(views: [spinner, status, changeTypeButton])
        statusRow.spacing = 6

        let test = NSButton(title: "Test", target: self, action: #selector(testClicked(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectClicked(_:)))
        connect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [test, NSView(), cancel, save, connect])
        buttons.spacing = 8

        openNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        openNote.textColor = .secondaryLabelColor
        openNote.isHidden = true
        let stack = NSStackView(views: [grid, openNote, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        // Holds the grid inside the right inset too; a leading-aligned stack only pins the left.
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        openNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let root = NSView()
        root.addSubview(stack)
        stack.pin(to: root)
        return root
    }

    /// An edited connection with an open workspace: its name, tag, safe mode and queries folder
    /// follow at once, the rest at its next connect.
    private func showOpenNote() {
        let open = !isNew && (isOpenInWorkspace?(config.id) ?? false)
        openNote.stringValue = open
            ? "\(config.displayName) is open. Its name, tag, safe mode and queries folder change there at once; other changes apply the next time it connects."
            : ""
        openNote.isHidden = !open
        if let window, let content = window.contentView { window.fit(to: content) }
    }

    private enum Kind { case both, file, server, postgres, mysql, ssh, sshKey, sqliteSSH }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        return s
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    /// Shows the fields the driver uses and fits the window to them.
    private func layoutForDriver() {
        let d = driver
        for i in fileRows { grid.row(at: i).isHidden = d.isServer }
        for i in serverRows { grid.row(at: i).isHidden = !d.isServer }
        for i in postgresRows { grid.row(at: i).isHidden = d != .postgres }
        for i in mysqlRows { grid.row(at: i).isHidden = d != .mysql && d != .mariadb }
        let ssh = d.isServer && sshBox.state == .on
        for i in sshRows { grid.row(at: i).isHidden = !ssh }
        for i in sshKeyRows where ssh { grid.row(at: i).isHidden = sshKeyBox.state != .on }
        hostField.placeholderString = ssh ? "127.0.0.1 (the SSH server itself)" : "127.0.0.1, or a socket path"
        portField.placeholderString = d.isServer ? String(d.defaultPort) : ""
        userField.placeholderString = d == .postgres ? NSUserName() : "root"
        databaseField.placeholderString = d == .postgres ? "Defaults to the user name" : "Optional"
        let selected = tlsPopup.indexOfSelectedItem >= 0 ? currentTLSModes[safe: tlsPopup.indexOfSelectedItem] : nil
        currentTLSModes = d.tlsModes
        tlsPopup.removeAllItems()
        tlsPopup.addItems(withTitles: d.tlsModes.map { d.label(for: $0) })
        if let selected, let i = d.tlsModes.firstIndex(of: selected) { tlsPopup.selectItem(at: i) }
        updateNegotiation()
        passwordField.isEnabled = passwordModePopup.indexOfSelectedItem != 2
        sshPasswordField.isEnabled = sshPasswordModePopup.indexOfSelectedItem == 0
        // SQLite's is SQLCipher's passphrase, for encrypted databases.
        if let row = grid.cell(for: passwordField)?.row, let label = row.cell(at: 0).contentView as? NSTextField {
            label.stringValue = d.isServer ? "Password" : "Passphrase"
        }
        passwordField.placeholderString = d.isServer ? nil : "Encrypted files only"
        window?.title = (isNew ? "New \(d.displayName) Connection" : "Edit \(config.displayName)")
        if let window, let content = window.contentView { window.fit(to: content) }
    }

    private var currentTLSModes: [TLSMode] = []

    // MARK: - Model

    private func show(_ c: ConnectionConfig) {
        driverPopup.selectItem(at: DriverKind.allCases.firstIndex(of: c.driver) ?? 0)
        nameField.stringValue = c.name
        pathField.stringValue = c.filePath
        hostField.stringValue = c.host
        portField.stringValue = c.port.map(String.init) ?? ""
        userField.stringValue = c.user
        databaseField.stringValue = c.database
        passwordModePopup.selectItem(at: PasswordMode.allCases.firstIndex(of: c.passwordMode) ?? 0)
        if c.passwordMode == .keychain, !isNew {
            passwordField.stringValue = (try? secrets.password(for: c.id)) ?? ""
        }
        currentTLSModes = c.driver.tlsModes
        tlsPopup.addItems(withTitles: currentTLSModes.map { c.driver.label(for: $0) })
        tlsPopup.selectItem(at: currentTLSModes.firstIndex(of: c.tlsMode) ?? 0)
        caField.stringValue = c.tlsCAPath
        certField.stringValue = c.tlsCertPath
        keyField.stringValue = c.tlsKeyPath
        negotiationPopup.selectItem(at: c.tlsDirect ? 1 : 0)
        serverNameField.stringValue = c.tlsServerName
        tagID = store.tag(id: c.tagID)?.id
        rebuildTagMenu()
        safeModePopup.selectItem(at: SafeMode.allCases.firstIndex(of: c.safeMode) ?? 0)
        safeModeHint.stringValue = c.safeMode.detail
        readOnlyBox.state = c.readOnly ? .on : .off
        queriesField.stringValue = c.queriesFolder
        bootstrapSQL = c.bootstrapSQL
        showBootstrapCount()
        sshBox.state = c.overSSH ? .on : .off
        sshHostField.stringValue = c.sshHost
        sshPortField.stringValue = c.sshPort.map(String.init) ?? ""
        sshUserField.stringValue = c.sshUser
        sshPasswordModePopup.selectItem(at: PasswordMode.allCases.firstIndex(of: c.sshPasswordMode) ?? 0)
        sshKeyBox.state = c.sshKeyPath.isEmpty ? .off : .on
        sshKeyField.stringValue = c.sshKeyPath
        if !isNew {
            if c.sshPasswordMode == .keychain { sshPasswordField.stringValue = (try? secrets.secret(.sshPassword, for: c.id)) ?? "" }
            sshPassphraseField.stringValue = (try? secrets.secret(.sshKeyPassphrase, for: c.id)) ?? ""
        }
        layoutForDriver()
    }

    /// The config as the fields currently describe it.
    private func edited() -> ConnectionConfig {
        func text(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        var c = config
        c.driver = driver
        c.name = text(nameField)
        c.filePath = text(pathField)
        if !c.driver.isServer, c.name.isEmpty { c.name = (c.filePath as NSString).lastPathComponent }
        c.host = text(hostField)
        c.port = Int(text(portField))
        c.user = text(userField)
        c.database = text(databaseField)
        c.passwordMode = PasswordMode.allCases[max(0, passwordModePopup.indexOfSelectedItem)]
        c.tlsMode = currentTLSModes[safe: tlsPopup.indexOfSelectedItem] ?? c.driver.tlsModes.first ?? .disable
        c.tlsCAPath = text(caField)
        c.tlsCertPath = text(certField)
        c.tlsKeyPath = text(keyField)
        c.tlsDirect = c.driver == .postgres && negotiationPopup.indexOfSelectedItem == 1
        c.tlsServerName = c.driver == .mysql || c.driver == .mariadb ? text(serverNameField) : ""
        // Another server (or type) gets checked again.
        if c.driver != config.driver || c.host != config.host || c.port != config.port {
            c.keepsDriverForOtherServer = false
        }
        c.tagID = tagID
        c.safeMode = SafeMode.allCases[max(0, safeModePopup.indexOfSelectedItem)]
        c.readOnly = readOnlyBox.state == .on
        c.overSSH = sshBox.state == .on
        c.sshHost = text(sshHostField)
        c.sshPort = Int(text(sshPortField))
        c.sshUser = text(sshUserField)
        c.sshPasswordMode = PasswordMode.allCases[max(0, sshPasswordModePopup.indexOfSelectedItem)]
        c.sshKeyPath = sshKeyBox.state == .on ? text(sshKeyField) : ""
        // Named after the connection unless given; renaming the connection later keeps it.
        c.queriesFolder = text(queriesField)
        if c.queriesFolder.isEmpty { c.queriesFolder = SavedQueries.defaultFolder(for: c) }
        c.bootstrapSQL = bootstrapSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : bootstrapSQL
        return c
    }

    /// The password to log in with: nil when the connection uses none.
    private var typedPassword: String? {
        edited().passwordMode == .none ? nil : passwordField.stringValue
    }

    /// The SSH password typed in a Keychain-mode connection, nil when empty.
    private var typedSSHPassword: String? {
        edited().sshPasswordMode == .keychain && !sshPasswordField.stringValue.isEmpty ? sshPasswordField.stringValue : nil
    }

    private var typedPassphrase: String? {
        sshKeyBox.state == .on && !sshPassphraseField.stringValue.isEmpty ? sshPassphraseField.stringValue : nil
    }

    private func setStatus(_ text: String, ok: Bool) {
        status.stringValue = text
        status.textColor = ok ? .systemGreen : .systemRed
    }

    /// Saves the edits, then calls `done`. When the queries folder changes and the old one has
    /// queries, it first asks whether to move them (copy, when another connection uses that
    /// folder) or leave them; Cancel saves nothing.
    private func saveEdits(then done: @escaping () -> Void) {
        let c = edited()
        if !c.driver.isServer, c.filePath.isEmpty {
            setStatus("Choose a database file first.", ok: false)
            return
        }
        let change = store.connection(id: c.id).flatMap {
            SavedQueries.folderChange(from: $0, to: c, among: store.connections, root: dataRoot)
        }
        guard let change, change.count > 0, let window else { return commit(c, change, nil, then: done) }
        let shared = !change.sharedWith.isEmpty
        let verb = shared ? "Copy" : "Move"
        let what = change.count == 1 ? "the query" : "the \(change.count) queries"
        let alert = NSAlert()
        alert.messageText = "\(verb) \(what) in “\(folderLabel(change.source))” to “\(folderLabel(change.destination))”?"
        let source = folderLabel(change.source), destination = folderLabel(change.destination)
        var info = "If you don’t \(verb.lowercased()) them, they stay in “\(source)”, and this connection uses the queries in “\(destination)”."
        if shared {
            let names = ListFormatter.localizedString(byJoining: change.sharedWith)
            info = "“\(source)” is also the queries folder of \(names). " + info
        }
        alert.informativeText = info
        alert.addButton(withTitle: "\(verb) Queries")
        alert.addButton(withTitle: "Don’t \(verb)")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.commit(c, change, shared ? .copy : .move, then: done)
            case .alertSecondButtonReturn: self?.commit(c, change, nil, then: done)
            default: break
            }
        }
    }

    private func commit(_ c: ConnectionConfig, _ change: SavedQueries.FolderChange?, _ transfer: SavedQueries.Transfer?,
                        then done: () -> Void) {
        do {
            // Only a Keychain-mode password is kept; switching modes forgets it.
            let keep = c.passwordMode == .keychain && !passwordField.stringValue.isEmpty
            try secrets.setPassword(keep ? passwordField.stringValue : nil, for: c.id)
            try secrets.setSecret(c.usesSSH ? typedSSHPassword : nil, .sshPassword, for: c.id)
            try secrets.setSecret(c.usesSSH ? typedPassphrase : nil, .sshKeyPassphrase, for: c.id)
            if let change { try onQueriesFolderChange?(c, change, transfer) }
            try store.save(c)
            config = c
            queriesField.stringValue = c.queriesFolder
            done()
        } catch {
            setStatus("Couldn’t save: \(error.localizedDescription)", ok: false)
        }
    }

    /// A folder in the app's Queries folder by its name, any other by its path.
    private func folderLabel(_ url: URL) -> String {
        let root = SavedQueries.queriesRoot(dataRoot).standardizedFileURL.path
        return url.deletingLastPathComponent().standardizedFileURL.path == root
            ? url.lastPathComponent : (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    /// Direct negotiation applies only when the mode requires TLS.
    private func updateNegotiation() {
        let mode = currentTLSModes[safe: tlsPopup.indexOfSelectedItem]
        negotiationPopup.isEnabled = mode.map { ![.disable, .allow, .prefer].contains($0) } ?? false
    }

    @objc private func tlsModeChanged(_ sender: Any?) { updateNegotiation() }

    /// Switches the type to what Test found the server to be.
    @objc private func changeType(_ sender: Any?) {
        guard let kind = suggestedDriver, let i = DriverKind.allCases.firstIndex(of: kind) else { return }
        driverPopup.selectItem(at: i)
        driverChanged(nil)
    }

    @objc private func driverChanged(_ sender: Any?) {
        status.stringValue = ""
        suggestedDriver = nil
        changeTypeButton.isHidden = true
        showBootstrapCount()
        layoutForDriver()
    }

    // MARK: Tags

    /// None, the store's tags with their colours, then Edit Tags…; `tagID` selected (None when
    /// that tag is gone).
    private func rebuildTagMenu() {
        if store.tag(id: tagID) == nil { tagID = nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "None", action: nil, keyEquivalent: "")
        for tag in store.tags {
            let item = menu.addItem(withTitle: tag.name, action: nil, keyEquivalent: "")
            item.image = tag.color.dot()
            item.representedObject = tag.id
        }
        menu.addItem(.separator())
        let edit = menu.addItem(withTitle: "Edit Tags…", action: #selector(editTags(_:)), keyEquivalent: "")
        edit.target = self
        tagPopup.menu = menu
        selectTag()
    }

    private func selectTag() {
        let index = tagPopup.itemArray.firstIndex { ($0.representedObject as? UUID) == tagID && tagID != nil } ?? 0
        tagPopup.selectItem(at: index)
    }

    @objc private func tagChanged(_ sender: Any?) {
        tagID = tagPopup.selectedItem?.representedObject as? UUID
    }

    @objc func editTags(_ sender: Any?) {
        selectTag()
        guard let window, tagsSheet == nil else { return }
        let sheet = TagsSheet(store: store)
        tagsSheet = sheet
        sheet.begin(on: window) { [weak self] in self?.tagsSheet = nil }
    }

    /// The tags (or this connection's tag) changed elsewhere: the menu follows.
    @objc private func storeChanged() { rebuildTagMenu() }

    @objc private func safeModeChanged(_ sender: Any?) {
        safeModeHint.stringValue = SafeMode.allCases[max(0, safeModePopup.indexOfSelectedItem)].detail
    }

    @objc private func passwordModeChanged(_ sender: Any?) {
        passwordField.isEnabled = passwordModePopup.indexOfSelectedItem != 2
        sshPasswordField.isEnabled = sshPasswordModePopup.indexOfSelectedItem == 0
    }

    @objc private func sshChanged(_ sender: Any?) {
        status.stringValue = ""
        layoutForDriver()
    }

    @objc private func chooseSSHKey(_ sender: Any?) {
        choose(into: sshKeyField, message: "Choose your SSH private key", showHidden: true)
    }

    @objc private func chooseFile(_ sender: Any?) {
        choose(into: pathField, message: "Choose a SQLite database")
    }

    /// A folder in the app's Queries folder is kept by name, any other by its path.
    @objc private func chooseQueriesFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder for this connection’s saved queries"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SavedQueries.directory(root: dataRoot, for: edited()).deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.queriesField.stringValue = self.folderLabel(url)
            self.status.stringValue = ""
        }
    }

    // MARK: Bootstrap commands

    @objc func editBootstrap(_ sender: Any?) {
        guard let anchor = sender as? NSView ?? bootstrapLabel.superview else { return }
        let controller = BootstrapCommandsController(text: bootstrapSQL, dialect: driver.lexer)
        controller.onChange = { [weak self] text in
            self?.bootstrapSQL = text
            self?.showBootstrapCount()
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        bootstrapPopover = popover
    }

    /// "None", or how many statements the bootstrap holds.
    private func showBootstrapCount() {
        var c = config
        c.driver = driver
        c.bootstrapSQL = bootstrapSQL
        let n = c.bootstrapStatements.count
        bootstrapLabel.stringValue = n == 0 ? "None" : n == 1 ? "1 statement" : "\(n) statements"
        bootstrapLabel.textColor = n == 0 ? .secondaryLabelColor : .labelColor
    }

    @objc private func chooseCA(_ sender: Any?) { choose(into: caField, message: "Choose the CA certificate (PEM)") }
    @objc private func chooseCert(_ sender: Any?) { choose(into: certField, message: "Choose the client certificate (PEM)") }
    @objc private func chooseKey(_ sender: Any?) { choose(into: keyField, message: "Choose the client key (PEM)") }

    private func choose(into field: NSTextField, message: String, showHidden: Bool = false) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = message
        // ~/.ssh is hidden.
        panel.showsHiddenFiles = showHidden
        let current = (field.stringValue as NSString).expandingTildeInPath
        if !current.isEmpty {
            panel.directoryURL = URL(filePath: current).deletingLastPathComponent()
        } else if showHidden {
            panel.directoryURL = URL(filePath: ("~/.ssh" as NSString).expandingTildeInPath)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            field.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self?.status.stringValue = ""
        }
    }

    @objc private func testClicked(_ sender: Any?) {
        let c = edited()
        let password = typedPassword
        let ssh = sshLogin?(c, typedSSHPassword, typedPassphrase) ?? SSHLogin()
        testTask?.cancel()
        spinner.startAnimation(nil)
        status.stringValue = ""
        changeTypeButton.isHidden = true
        testTask = Task {
            defer { spinner.stopAnimation(nil) }
            do {
                let server = try await ConnectionFactory.test(c, password: password, ssh: ssh)
                guard !Task.isCancelled else { return }
                var tested = c
                tested.keepsDriverForOtherServer = false
                if let other = tested.suggestedDriver(forServer: server) {
                    suggestedDriver = other
                    setStatus("Connection works. The server is \(other.displayName), not \(c.driver.displayName).", ok: true)
                    changeTypeButton.title = "Change Type to \(other.displayName)"
                    changeTypeButton.isHidden = false
                    return
                }
                setStatus("Connection works.", ok: true)
            } catch {
                guard !Task.isCancelled else { return }
                setStatus("\(error)", ok: false)
            }
        }
    }

    @objc func saveClicked(_ sender: Any?) {
        saveEdits { [weak self] in self?.close() }
    }

    /// Connect saves first, so a connection that worked is never lost.
    @objc private func connectClicked(_ sender: Any?) {
        let password = typedPassword
        saveEdits { [weak self] in
            guard let self else { return }
            self.onConnect?(self.config, password)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
