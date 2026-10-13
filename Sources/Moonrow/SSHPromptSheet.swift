import AppCore
import AppKit

/// A window that background work can hold without keeping it open.
@MainActor
final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow?) {
        self.window = window
    }
}

/// Shows ssh's questions while a tunnel logs in: a secure field for passwords, passphrases and
/// one-time codes, Trust / Cancel for an unknown host key. A sheet on `window`, or a modal
/// alert without one.
@MainActor
enum SSHPromptSheet {
    static func ask(_ request: SSHPromptRequest, in window: WeakWindow) async -> SSHAnswer? {
        await ask(request, in: window.window)
    }

    static func ask(_ request: SSHPromptRequest, in window: NSWindow?) async -> SSHAnswer? {
        let alert = NSAlert()
        var field: NSSecureTextField?
        var saveBox: NSButton?
        switch request.prompt {
        case .hostKey(let message):
            alert.messageText = "Trust the SSH server \(request.server)?"
            alert.informativeText = "Moonrow hasn't connected to this server before, so it can't confirm the server is "
                + "the one you mean. Check the fingerprint with the server's administrator.\n\n"
                + hostKeyDetails(message)
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
        case .password(let account):
            alert.messageText = request.isRetry ? "That password didn't work" : "SSH password for \(account)"
            alert.informativeText = request.isRetry ? "Enter the SSH password for \(account) again." : "Connecting through \(request.server)."
        case .keyPassphrase(let keyPath):
            alert.messageText = request.isRetry ? "That passphrase didn't work" : "Passphrase for your SSH key"
            alert.informativeText = (keyPath as NSString).abbreviatingWithTildeInPath
        case .other(let message):
            alert.messageText = "The SSH server \(request.server) asks:"
            alert.informativeText = message
        }
        if request.prompt.isSecret {
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field = input
            if request.offersSave {
                let box = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
                box.state = .on
                saveBox = box
                let stack = NSStackView(views: [input, box])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
                alert.accessoryView = stack
            } else {
                alert.accessoryView = input
            }
            alert.window.initialFirstResponder = input
        }
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        guard let field else { return SSHAnswer("yes") }
        return SSHAnswer(field.stringValue, save: saveBox?.state == .on)
    }

    /// ssh's key type and fingerprint line, without its question.
    private static func hostKeyDetails(_ message: String) -> String {
        message.split(whereSeparator: \.isNewline).filter { $0.contains("fingerprint is") }.joined(separator: "\n")
    }
}
