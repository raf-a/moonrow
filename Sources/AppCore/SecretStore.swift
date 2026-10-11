import Foundation
import Security

/// The secrets a connection can have saved.
public enum SecretKind: String, Sendable, CaseIterable {
    /// The database login.
    case database
    /// The SSH server login.
    case sshPassword
    /// The passphrase of the SSH private key.
    case sshKeyPassphrase

    /// The item's account name: the connection id, with a suffix for the SSH ones.
    func account(_ id: UUID) -> String {
        switch self {
        case .database: id.uuidString
        case .sshPassword: id.uuidString + ".ssh"
        case .sshKeyPassphrase: id.uuidString + ".ssh-key"
        }
    }
}

/// Where connection secrets are kept, per connection id and kind.
public protocol SecretStore: Sendable {
    func secret(_ kind: SecretKind, for id: UUID) throws -> String?
    /// Nil removes it.
    func setSecret(_ value: String?, _ kind: SecretKind, for id: UUID) throws
}

extension SecretStore {
    /// The database password.
    public func password(for id: UUID) throws -> String? { try secret(.database, for: id) }
    public func setPassword(_ password: String?, for id: UUID) throws { try setSecret(password, .database, for: id) }

    /// Forgets every secret of a deleted connection.
    public func removeAll(for id: UUID) {
        for kind in SecretKind.allCases { try? setSecret(nil, kind, for: id) }
    }

    /// Gives a duplicated connection the original's secrets.
    public func copyAll(from id: UUID, to copy: UUID) {
        for kind in SecretKind.allCases {
            if let value = try? secret(kind, for: id) { try? setSecret(value, kind, for: copy) }
        }
    }
}

public struct SecretStoreError: Error, CustomStringConvertible {
    public var description: String
}

/// Generic-password Keychain items: service `app.tabula.connection`, account = connection id
/// (plus `.ssh` / `.ssh-key` for the SSH secrets).
public struct KeychainSecretStore: SecretStore {
    public static let service = "app.tabula.connection"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func secret(_ kind: SecretKind, for id: UUID) throws -> String? {
        var q = query(kind.account(id))
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw error(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, _ kind: SecretKind, for id: UUID) throws {
        let account = kind.account(id)
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw error(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = kind == .database ? "Tabula connection" : "Tabula connection (SSH)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    private func error(_ status: OSStatus) -> SecretStoreError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return SecretStoreError(description: "Keychain: \(text)")
    }
}

/// A JSON file of secrets, for development runs with `TABULA_STORE` so they never touch the
/// login Keychain. Plain text: not for real credentials.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func secret(_ kind: SecretKind, for id: UUID) throws -> String? {
        try lock.withLock { try read()[kind.account(id)] }
    }

    public func setSecret(_ value: String?, _ kind: SecretKind, for id: UUID) throws {
        try lock.withLock {
            var all = try read()
            all[kind.account(id)] = value
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: url, options: .atomic)
        }
    }

    private func read() throws -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

/// In memory only; for tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func secret(_ kind: SecretKind, for id: UUID) throws -> String? { lock.withLock { values[kind.account(id)] } }
    public func setSecret(_ value: String?, _ kind: SecretKind, for id: UUID) throws {
        lock.withLock { values[kind.account(id)] = value }
    }
}
