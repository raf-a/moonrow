import CryptoKit
import Foundation

/// An app asking for a token through `moonrow://integrations/pair?…`.
public struct MCPPairingRequest: Sendable, Hashable {
    public var client: String
    public var permission: MCPPermission
    public var access: MCPConnectionAccess
    public var redirect: URL
    /// base64url(SHA-256(code_verifier)), from the client.
    public var codeChallenge: String
    public var state: String?

    public enum ParseError: Error, Sendable, Hashable, LocalizedError {
        case missing(String)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let name): "The pairing request has no \(name)."
            case .invalid(let what): "The pairing request's \(what) isn't valid."
            }
        }
    }

    /// Reads the request from the URL's query: client, permission (read, write, full; read when
    /// absent), connections (UUIDs separated by commas; all when absent), redirect_uri,
    /// code_challenge, code_challenge_method (S256 only) and state.
    public init(url: URL) throws(ParseError) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let client = value("client") ?? value("client_name") else { throw .missing("client") }
        self.client = String(client.prefix(80))
        if let p = value("permission") ?? value("scope") {
            guard let permission = MCPPermission(requested: p) else { throw .invalid("permission") }
            self.permission = permission
        } else {
            permission = .readOnly
        }
        if let list = value("connections"), list.lowercased() != "all" {
            var ids = Set<UUID>()
            for part in list.split(separator: ",") {
                guard let id = UUID(uuidString: part.trimmingCharacters(in: .whitespaces)) else { throw .invalid("connections") }
                ids.insert(id)
            }
            access = .only(ids)
        } else {
            access = .all
        }
        guard let r = value("redirect_uri") else { throw .missing("redirect_uri") }
        guard let redirect = URL(string: r), Self.isAllowedRedirect(redirect) else { throw .invalid("redirect_uri") }
        self.redirect = redirect
        guard let challenge = value("code_challenge") else { throw .missing("code_challenge") }
        guard (value("code_challenge_method") ?? "S256") == "S256", challenge.count >= 43, challenge.count <= 128 else {
            throw .invalid("code_challenge")
        }
        codeChallenge = challenge
        state = value("state")
    }

    /// Schemes the system's own apps answer: opening one runs, calls, mounts or configures
    /// something. The app also refuses any redirect a system app would receive.
    static let systemSchemes: Set<String> = [
        "file", "javascript", "data", "about", "blob", "moonrow", "ftp", "sftp", "mailto", "tel", "sms", "imessage",
        "facetime", "facetime-audio", "callto", "shortcuts", "ssh", "telnet", "vnc", "smb", "afp", "nfs", "cifs", "webcal",
        "feed", "itms", "itms-apps", "itms-services", "macappstore", "applescript", "x-man-page", "x-apple.systempreferences",
        "x-apple-systempreferences", "x-apple-helpbasic", "x-apple-help", "prefs", "cmd",
    ]

    /// Loopback only: http(s) to this Mac, or a third-party app's own scheme (`raycast://`).
    static func isAllowedRedirect(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return isLoopback(url)
        default:
            return !systemSchemes.contains(scheme)
        }
    }

    /// http(s) to localhost, 127.0.0.1 or ::1.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// Where the browser goes back to: the redirect with `code` (or `error`) and `state`.
    public func redirect(code: String?) -> URL {
        var c = URLComponents(url: redirect, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = c.queryItems ?? []
        if let code { items.append(URLQueryItem(name: "code", value: code)) } else {
            items.append(URLQueryItem(name: "error", value: "user_denied"))
        }
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        c.queryItems = items
        return c.url ?? redirect
    }

    /// How the request reads in the alert: "Read & Write access to 2 connections".
    public func describe(connectionNames: [String]) -> String {
        let what: String = switch access {
        case .all: "all connections"
        case .only(let ids) where ids.count == 1: connectionNames.first.map { "“\($0)”" } ?? "1 connection"
        case .only(let ids): "\(ids.count) connections"
        }
        return "\(permission.title) access to \(what)"
    }
}

/// One-time codes for tokens the user allowed, until the client exchanges them.
public actor MCPPairing {
    public static let lifetime: TimeInterval = 5 * 60
    public static let maxPending = 16

    public enum ExchangeError: Error, Sendable, Hashable, LocalizedError {
        case notFound, expired, challengeMismatch

        public var errorDescription: String? {
            switch self {
            case .notFound: "Pairing code not found"
            case .expired: "Pairing code expired"
            case .challengeMismatch: "Challenge mismatch"
            }
        }
    }

    private struct Pending {
        var token: String
        var challenge: String
        var expires: Date
    }

    private var pending: [String: Pending] = [:]

    public init() {}

    /// Keeps the token under a new code and returns the code.
    public func add(token: String, challenge: String, now: Date = Date()) -> String {
        pending = pending.filter { $0.value.expires > now }
        while pending.count >= Self.maxPending, let oldest = pending.min(by: { $0.value.expires < $1.value.expires }) {
            pending[oldest.key] = nil
        }
        let code = MCPTokenStore.randomBase64URL(24)
        pending[code] = Pending(token: token, challenge: challenge, expires: now.addingTimeInterval(Self.lifetime))
        return code
    }

    /// The token, once; the code is gone afterwards, whatever the outcome.
    public func exchange(code: String, verifier: String, now: Date = Date()) throws(ExchangeError) -> String {
        guard let p = pending.removeValue(forKey: code) else { throw .notFound }
        guard p.expires > now else { throw .expired }
        guard Self.challenge(for: verifier) == p.challenge else { throw .challengeMismatch }
        return p.token
    }

    /// S256: base64url(SHA-256(verifier)), without padding.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}
