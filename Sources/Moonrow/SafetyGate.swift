import AppCore
import AppKit
import LocalAuthentication
import SQLScript

/// Touch ID for safe mode (Settings ▸ General).
@MainActor
enum BiometricUnlock {
    /// For the dev harness: answers in place of Touch ID, and makes it count as available.
    static var override: ((String) async -> Bool)?

    /// Touch ID is set up on this Mac.
    static var isAvailable: Bool {
        if override != nil { return true }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Whether password prompts offer Touch ID: turned on, and there is Touch ID.
    static var isOffered: Bool { AppStyle.settings.safeModeTouchID && isAvailable }

    /// Asks for a fingerprint; `reason` completes "Moonrow is trying to …". False when it fails or
    /// is cancelled.
    static func authenticate(reason: String) async -> Bool {
        if let override { return await override(reason) }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}

/// A workspace's safe mode: decides whether statements the user sends need a confirmation or
/// the password first, and asks with a sheet on the workspace window.
///
/// Every path that sends the user's statements goes through `approve`: query tabs, grid
/// commits, structure changes, the sidebar's rename / truncate / delete, imports. The app's own
/// reads (browsing, counting, introspection, completion) and the schema switcher don't.
@MainActor
final class SafetyGate {
    /// Posted (object: the gate) when the level changes.
    static let levelDidChange = Notification.Name("SafetyGate.levelDidChange")

    private(set) var level: SafeMode
    let credential: SafetyCredential
    let connectionName: String
    private let dialect: LexerDialect
    weak var window: NSWindow?
    /// The level was changed from the toolbar; saves it with the connection.
    var onLevelChange: ((SafeMode) -> Void)?
    /// The sheet on screen, for the dev harness.
    private(set) var prompt: SafetyPrompt?

    init(level: SafeMode, credential: SafetyCredential, connectionName: String, dialect: LexerDialect) {
        self.level = level
        self.credential = credential
        self.connectionName = connectionName
        self.dialect = dialect
    }

    func requirement(for statements: [String]) -> SafetyRequirement {
        level.requirement(for: statements, dialect: dialect)
    }

    /// True when the statements may be sent: safe mode doesn't ask, or the user confirmed (and
    /// gave the password, where the level wants it). `client` names an MCP client sending them.
    func approve(_ statements: [String], from client: String? = nil) async -> Bool {
        let requirement = requirement(for: statements)
        guard requirement != .none else { return true }
        guard let window else { return false }
        let writes = statements.filter { SQLClassifier.kind(of: $0, dialect: dialect) == .write }.count
        var message = level.detail
        if level == .alertWrites || level == .passwordWrites, statements.count > 1 {
            message += " \(writes) of \(statements.count) statements may modify data."
        }
        let sql = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        let prompt = SafetyPrompt(
            title: client.map { "Run these statements from \($0)?" } ?? "Run these statements?",
            message: message, sql: sql,
            credential: requirement == .password ? credential : nil, connectionName: connectionName, confirm: "Run")
        return await show(prompt, in: window)
    }

    /// Changes the level; leaving a password level asks for the password first.
    func change(to new: SafeMode) async {
        guard new != level else { return }
        if !level.canChange(to: new) {
            guard let window else { return }
            let prompt = SafetyPrompt(
                title: "Change safe mode to “\(new.title)”?", message: new.detail, sql: nil,
                credential: credential, connectionName: connectionName, confirm: "Change")
            guard await show(prompt, in: window) else { return }
        }
        level = new
        onLevelChange?(new)
        NotificationCenter.default.post(name: Self.levelDidChange, object: self)
    }

    /// Takes the level the saved connection now has (edited in its form, which asks nothing).
    func follow(_ saved: SafeMode) {
        guard saved != level else { return }
        level = saved
        NotificationCenter.default.post(name: Self.levelDidChange, object: self)
    }

    private func show(_ prompt: SafetyPrompt, in window: NSWindow) async -> Bool {
        self.prompt = prompt
        defer { if self.prompt === prompt { self.prompt = nil } }
        return await prompt.run(on: window)
    }
}

/// The sheet: what's about to be sent, and the password field when one is needed. A wrong
/// password keeps the sheet open.
@MainActor
final class SafetyPrompt: NSObject, NSTextFieldDelegate {
    let sheet: NSWindow
    let passwordField = NSSecureTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let credential: SafetyCredential?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Shown when Touch ID may answer for the password.
    let touchIDButton = NSButton(title: "Use Touch ID", target: nil, action: nil)
    private let usesTouchID: Bool
    private let touchIDReason: String

    init(title: String, message: String, sql: String?, credential: SafetyCredential?, connectionName: String, confirm: String) {
        self.credential = credential
        usesTouchID = credential != nil && BiometricUnlock.isOffered
        touchIDReason = "unlock safe mode for “\(connectionName)”"
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        sheet.title = title

        let icon = NSImageView(image: NSImage(systemSymbolName: credential == nil ? "exclamationmark.shield" : "lock.shield",
                                              accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .systemOrange
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [heading, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let header = NSStackView(views: [icon, text])
        header.alignment = .top
        header.spacing = 12

        var views: [NSView] = [header]
        if let sql {
            let scroll = NSTextView.scrollableTextView()
            let view = scroll.documentView as! NSTextView
            view.string = sql
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 4, height: 4)
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(equalToConstant: min(220, max(70, CGFloat(sql.split(separator: "\n", omittingEmptySubsequences: false).count) * 15 + 14))).isActive = true
            views.append(scroll)
        }
        if let credential {
            let label = NSTextField(wrappingLabelWithString: credential.prompt(for: connectionName))
            label.font = .systemFont(ofSize: 12)
            passwordField.placeholderString = credential.kind == .password ? "Database password" : connectionName
            passwordField.delegate = self
            errorLabel.textColor = .systemRed
            errorLabel.font = .systemFont(ofSize: 11)
            errorLabel.isHidden = true
            views += [label, passwordField, errorLabel]
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: confirm, target: self, action: #selector(confirm(_:)))
        ok.keyEquivalent = "\r"
        touchIDButton.target = self
        touchIDButton.action = #selector(useTouchID(_:))
        touchIDButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        touchIDButton.imagePosition = .imageLeading
        touchIDButton.isHidden = !usesTouchID
        let buttons = NSStackView(views: [touchIDButton, NSView(), cancel, ok])
        buttons.spacing = 8
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        for v in views where v !== header { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        detail.preferredMaxLayoutWidth = 420
        heading.preferredMaxLayoutWidth = 420
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        sheet.contentView = stack
        sheet.initialFirstResponder = credential == nil ? ok : passwordField
    }

    /// Shows the sheet until it's answered. With Touch ID offered, it's asked for at once; the
    /// password field stays for when it fails or is cancelled.
    func run(on window: NSWindow) async -> Bool {
        await withCheckedContinuation { c in
            continuation = c
            window.beginSheet(sheet)
            // Once the sheet is up, so Touch ID's own panel comes over it.
            if usesTouchID { DispatchQueue.main.async { self.useTouchID(nil) } }
        }
    }

    @objc func useTouchID(_ sender: Any?) {
        touchIDButton.isEnabled = false
        Task {
            let ok = await BiometricUnlock.authenticate(reason: touchIDReason)
            touchIDButton.isEnabled = true
            if ok, continuation != nil { finish(true) }
        }
    }

    /// Confirms with `password` (for the dev harness and tests of the flow).
    func respond(password: String?) {
        if let password { passwordField.stringValue = password }
        confirm(nil)
    }

    @objc func cancel(_ sender: Any?) { finish(false) }

    @objc func confirm(_ sender: Any?) {
        if let credential, !credential.matches(passwordField.stringValue) {
            errorLabel.stringValue = credential.kind == .password ? "Incorrect password." : "The name doesn’t match."
            errorLabel.isHidden = false
            passwordField.selectText(nil)
            return
        }
        finish(true)
    }

    var errorShown: Bool { !errorLabel.isHidden }

    private func finish(_ result: Bool) {
        sheet.sheetParent?.endSheet(sheet)
        continuation?.resume(returning: result)
        continuation = nil
    }
}
