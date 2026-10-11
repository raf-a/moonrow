import Foundation

/// Something ssh asks while logging in, read from the text it hands to SSH_ASKPASS.
public enum SSHPrompt: Sendable, Hashable {
    /// `user@host's password:`; `account` is the `user@host` part.
    case password(account: String)
    /// `Enter passphrase for key '/path':`
    case keyPassphrase(keyPath: String)
    /// An unknown host key: the whole message, fingerprint included. Answered yes or no.
    case hostKey(message: String)
    /// Anything else, such as a keyboard-interactive question (a one-time code); shown as is.
    case other(message: String)

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("continue connecting"), trimmed.contains("authenticity of host") || trimmed.contains("fingerprint") {
            self = .hostKey(message: trimmed)
        } else if trimmed.hasSuffix("'s password:"), !trimmed.contains("\n") {
            self = .password(account: String(trimmed.dropLast("'s password:".count)))
        } else if trimmed.hasPrefix("Enter passphrase for key '"), trimmed.hasSuffix("':") {
            let path = trimmed.dropFirst("Enter passphrase for key '".count).dropLast(2)
            self = .keyPassphrase(keyPath: String(path))
        } else {
            self = .other(message: trimmed)
        }
    }

    /// Whether the answer is secret (typed into a secure field).
    public var isSecret: Bool {
        switch self {
        case .password, .keyPassphrase, .other: true
        case .hostKey: false
        }
    }

    /// The host key's fingerprint (`SHA256:…`), for host-key prompts.
    public var fingerprint: String? {
        guard case .hostKey(let message) = self else { return nil }
        return message.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
    }
}

/// A prompt handed to the app.
public struct SSHPromptRequest: Sendable {
    public var prompt: SSHPrompt
    /// The same question was already answered during this login, so that answer was wrong.
    public var isRetry: Bool
    /// The SSH server, `user@host:port`, for the sheet's title.
    public var server: String
    /// Whether the answer may be kept (a "Save in Keychain" choice).
    public var offersSave: Bool

    public init(prompt: SSHPrompt, isRetry: Bool, server: String, offersSave: Bool? = nil) {
        self.prompt = prompt
        self.isRetry = isRetry
        self.server = server
        switch prompt {
        case .password, .keyPassphrase: self.offersSave = offersSave ?? true
        case .hostKey, .other: self.offersSave = false
        }
    }
}

public struct SSHAnswer: Sendable, Hashable {
    /// The reply. For host-key prompts any answer means "trust it".
    public var text: String
    /// Keep it (password or key passphrase) once the login worked.
    public var save: Bool

    public init(_ text: String, save: Bool = false) {
        self.text = text
        self.save = save
    }
}

/// Asks the user. Nil cancels the login.
public typealias SSHPromptResponder = @Sendable (SSHPromptRequest) async -> SSHAnswer?

/// Which saved secret an answer replaces.
public enum SSHSecret: Sendable, Hashable {
    case password, keyPassphrase
}
