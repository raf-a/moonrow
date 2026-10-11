import CryptoKit
import Foundation
import SQLScript

/// How careful a workspace is before it sends the user's statements.
public enum SafeMode: String, Codable, Sendable, CaseIterable {
    /// Send everything without asking.
    case silent
    /// Ask before sending anything.
    case alert
    /// Ask before sending anything but reads (SELECT, EXPLAIN, SHOW, …).
    case alertWrites
    /// Ask for the password before sending anything.
    case password
    /// Ask for the password before sending anything but reads.
    case passwordWrites

    public var title: String {
        switch self {
        case .silent: "Off"
        case .alert: "Confirm Every Statement"
        case .alertWrites: "Confirm Changes"
        case .password: "Password for Every Statement"
        case .passwordWrites: "Password for Changes"
        }
    }

    public var detail: String {
        switch self {
        case .silent: "Statements are sent without asking."
        case .alert: "Every statement is shown for confirmation before it is sent."
        case .alertWrites: "Statements that may change something are shown for confirmation; reads are sent right away."
        case .password: "Every statement needs the database password before it is sent."
        case .passwordWrites: "Statements that may change something need the database password; reads are sent right away."
        }
    }

    public var requiresPassword: Bool { self == .password || self == .passwordWrites }

    /// What sending `statements` takes at this level.
    public func requirement(for statements: [String], dialect: LexerDialect) -> SafetyRequirement {
        switch self {
        case .silent: return .none
        case .alert, .password: break
        case .alertWrites, .passwordWrites:
            guard statements.contains(where: { SQLClassifier.kind(of: $0, dialect: dialect) == .write }) else { return .none }
        }
        return requiresPassword ? .password : .confirmation
    }

    /// Whether switching to `other` can happen without the password. Leaving a password level
    /// for a weaker one needs it, or safe mode would be one click away.
    public func canChange(to other: SafeMode) -> Bool {
        !requiresPassword || other == self || other == .password
    }

    /// Integer levels used in connection URLs (`safeModeLevel=0…4`).
    public init?(level: Int) {
        let all = Self.allCases
        guard all.indices.contains(level) else { return nil }
        self = all[level]
    }
}

public enum SafetyRequirement: Sendable, Hashable {
    case none
    case confirmation
    case password
}

/// What the password levels compare against: the database password the workspace logged in
/// with, or, for connections without one, the connection's name.
public struct SafetyCredential: Sendable {
    public enum Kind: Sendable, Hashable { case password, connectionName }

    public let kind: Kind
    private let digest: SHA256.Digest

    public init(password: String?, connectionName: String) {
        if let password, !password.isEmpty {
            kind = .password
            digest = SHA256.hash(data: Data(password.utf8))
        } else {
            kind = .connectionName
            digest = SHA256.hash(data: Data(connectionName.utf8))
        }
    }

    /// Compares digests, so the time taken doesn't depend on how much of the answer was right.
    public func matches(_ typed: String) -> Bool {
        SHA256.hash(data: Data(typed.utf8)) == digest
    }

    /// What the prompt asks for.
    public func prompt(for connection: String) -> String {
        switch kind {
        case .password: "Enter the database password for \(connection) to send these statements."
        case .connectionName: "\(connection) has no database password. Type its name, \(connection), to send these statements."
        }
    }
}
