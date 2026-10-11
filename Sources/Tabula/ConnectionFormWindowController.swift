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

    /// Asked to connect with the saved config and the password typed in the form.
    var onConnect: ((ConnectionConfig, String?) -> Void)?
    /// How Test logs in to the SSH server, given the SSH password and key passphrase typed.
    var sshLogin: ((ConnectionConfig, String?, String?) -> SSHLogin)?
    var onClose: (() -> Void)?

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
    private let caField = NSTextField()
    private let certField = NSTextField()
    private let keyField = NSTextField()
    private let readOnlyBox = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    private let pageSizeField = NSTextField()
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
    private let spinner = NSProgressIndicator()
    private let grid = NSGridView()
    private var fileRows: [Int] = []
    private var serverRows: [Int] = []
    private var sshRows: [Int] = []
    private var sshKeyRows: [Int] = []
    private var testTask: Task<Void, Never>?

    init(config: ConnectionConfig, isNew: Bool, store: ConnectionStore, secrets: any SecretStore) {
        self.config = config
        self.isNew = isNew
        self.store = store
        self.secrets = secrets
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        show(config)
        window.center()
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
        let sshHint = NSTextField(wrappingLabelWithString:
            "Without a key file, ssh uses your ~/.ssh/config, the SSH agent and your default keys. "
            + "Host and port above are as the SSH server sees them.")
        sshHint.textColor = .secondaryLabelColor
        sshHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sshHint.preferredMaxLayoutWidth = 360

        let hostRow = row(hostField, NSTextField(labelWithString: "Port"), portField)
        let passwordRow = row(passwordField, passwordModePopup)
        passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let rows: [(String, NSView, Kind)] = [
            ("Type", driverPopup, .both),
            ("Name", nameField, .both),
            ("Database file", row(pathField, button("Choose…", #selector(chooseFile(_:)))), .file),
            ("Host", hostRow, .server),
            ("User", userField, .server),
            ("Password", passwordRow, .server),
            ("Database", databaseField, .server),
            ("TLS", tlsPopup, .server),
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
            ("", readOnlyBox, .both),
            ("Rows per page", pageSizeRow(), .both),
        ]
        for (i, (title, view, kind)) in rows.enumerated() {
            grid.addRow(with: [title.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: title), view])
            if kind == .file { fileRows.append(i) }
            if kind == .server { serverRows.append(i) }
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
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 6

        let test = NSButton(title: "Test", target: self, action: #selector(testClicked(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectClicked(_:)))
        connect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [test, NSView(), cancel, save, connect])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        // Holds the grid inside the right inset too; a leading-aligned stack only pins the left.
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true

        let root = NSView()
        root.addSubview(stack)
        stack.pin(to: root)
        return root
    }

    private enum Kind { case both, file, server, ssh, sshKey }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        return s
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func pageSizeRow() -> NSView {
        pageSizeField.placeholderString = "All"
        pageSizeField.alignment = .right
        pageSizeField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let hint = NSTextField(labelWithString: "Empty or 0 shows every row")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return row(pageSizeField, hint)
    }

    /// Shows the fields the driver uses and fits the window to them.
    private func layoutForDriver() {
        let d = driver
        for i in fileRows { grid.row(at: i).isHidden = d.isServer }
        for i in serverRows { grid.row(at: i).isHidden = !d.isServer }
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
        passwordField.isEnabled = passwordModePopup.indexOfSelectedItem != 2
        sshPasswordField.isEnabled = sshPasswordModePopup.indexOfSelectedItem == 0
        window?.title = (isNew ? "New \(d.displayName) Connection" : "Edit \(config.displayName)")
        if let window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = window.frame.origin
            frame.origin.y += window.frame.height - frame.height
            window.setFrame(frame, display: true)
        }
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
        readOnlyBox.state = c.readOnly ? .on : .off
        pageSizeField.stringValue = c.rowsPerPage > 0 ? String(c.rowsPerPage) : ""
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
        c.readOnly = readOnlyBox.state == .on
        c.rowsPerPage = Int(pageSizeField.stringValue.filter(\.isNumber)) ?? 0
        c.overSSH = sshBox.state == .on
        c.sshHost = text(sshHostField)
        c.sshPort = Int(text(sshPortField))
        c.sshUser = text(sshUserField)
        c.sshPasswordMode = PasswordMode.allCases[max(0, sshPasswordModePopup.indexOfSelectedItem)]
        c.sshKeyPath = sshKeyBox.state == .on ? text(sshKeyField) : ""
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

    @discardableResult
    private func saveEdits() -> Bool {
        let c = edited()
        if !c.driver.isServer, c.filePath.isEmpty {
            setStatus("Choose a database file first.", ok: false)
            return false
        }
        do {
            // Only a Keychain-mode password is kept; switching modes forgets it.
            let keep = c.driver.isServer && c.passwordMode == .keychain && !passwordField.stringValue.isEmpty
            try secrets.setPassword(keep ? passwordField.stringValue : nil, for: c.id)
            try secrets.setSecret(c.usesSSH ? typedSSHPassword : nil, .sshPassword, for: c.id)
            try secrets.setSecret(c.usesSSH ? typedPassphrase : nil, .sshKeyPassphrase, for: c.id)
            try store.save(c)
            config = c
            return true
        } catch {
            setStatus("Couldn't save: \(error)", ok: false)
            return false
        }
    }

    // MARK: - Actions

    @objc private func driverChanged(_ sender: Any?) {
        status.stringValue = ""
        layoutForDriver()
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
        testTask = Task {
            defer { spinner.stopAnimation(nil) }
            do {
                try await ConnectionFactory.test(c, password: password, ssh: ssh)
                guard !Task.isCancelled else { return }
                setStatus("Connection works.", ok: true)
            } catch {
                guard !Task.isCancelled else { return }
                setStatus("\(error)", ok: false)
            }
        }
    }

    @objc private func saveClicked(_ sender: Any?) {
        if saveEdits() { close() }
    }

    /// Connect saves first, so a connection that worked is never lost.
    @objc private func connectClicked(_ sender: Any?) {
        let password = typedPassword
        guard saveEdits() else { return }
        onConnect?(config, password)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
