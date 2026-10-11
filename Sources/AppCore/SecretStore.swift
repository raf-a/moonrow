import Foundation
import Security

/// Where connection passwords are kept, one per connection id.
public protocol SecretStore: Sendable {
    func password(for id: UUID) throws -> String?
    /// Nil removes it.
    func setPassword(_ password: String?, for id: UUID) throws
}

public struct SecretStoreError: Error, CustomStringConvertible {
    public var description: String
}

/// Generic-password Keychain items: service `app.tabula.connection`, account = connection id.
public struct KeychainSecretStore: SecretStore {
    public static let service = "app.tabula.connection"

    public init() {}

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func password(for id: UUID) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw error(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        guard let password else {
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
            return
        }
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw error(update) }
        var add = query(id)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Tabula connection"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    private func error(_ status: OSStatus) -> SecretStoreError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return SecretStoreError(description: "Keychain: \(text)")
    }
}

/// A JSON file of passwords, for development runs with `TABULA_STORE` so they never touch the
/// login Keychain. Plain text: not for real credentials.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func password(for id: UUID) throws -> String? {
        try lock.withLock { try read()[id.uuidString] }
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        try lock.withLock {
            var all = try read()
            all[id.uuidString] = password
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
    private var values: [UUID: String] = [:]

    public init() {}

    public func password(for id: UUID) throws -> String? { lock.withLock { values[id] } }
    public func setPassword(_ password: String?, for id: UUID) throws { lock.withLock { values[id] = password } }
}
