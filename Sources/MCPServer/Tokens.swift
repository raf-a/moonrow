import CryptoKit
import Foundation
import Security

/// What an access token may do.
public enum MCPPermission: String, Codable, Sendable, CaseIterable {
    /// Reads: list connections, read-only statements, resources.
    case readOnly
    /// Reads, plus statements that may change something.
    case readWrite
    /// Everything, opening and closing connections too.
    case fullAccess

    public var title: String {
        switch self {
        case .readOnly: "Read Only"
        case .readWrite: "Read & Write"
        case .fullAccess: "Full Access"
        }
    }

    public var scopes: Set<MCPScope> {
        switch self {
        case .readOnly: [.toolsRead, .resourcesRead]
        case .readWrite: [.toolsRead, .toolsWrite, .resourcesRead]
        case .fullAccess: Set(MCPScope.allCases)
        }
    }

    /// The name pairing requests use (`read`, `write`, `full`), or a raw value.
    public init?(requested text: String) {
        switch text.lowercased() {
        case "read", "readonly", "read-only", "read_only": self = .readOnly
        case "write", "readwrite", "read-write", "read_write": self = .readWrite
        case "full", "fullaccess", "full-access", "full_access", "admin": self = .fullAccess
        default: return nil
        }
    }
}

public enum MCPScope: String, Codable, Sendable, CaseIterable {
    case toolsRead = "tools:read"
    case toolsWrite = "tools:write"
    case toolsControl = "tools:control"
    case resourcesRead = "resources:read"
}

/// The connections a token reaches.
public enum MCPConnectionAccess: Codable, Sendable, Hashable {
    case all
    case only(Set<UUID>)

    public func allows(_ id: UUID) -> Bool {
        switch self {
        case .all: true
        case .only(let ids): ids.contains(id)
        }
    }

    private enum CodingKeys: String, CodingKey { case all, connections }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let ids = try c.decodeIfPresent([UUID].self, forKey: .connections) {
            self = .only(Set(ids))
        } else {
            self = .all
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all: try c.encode(true, forKey: .all)
        case .only(let ids): try c.encode(ids.sorted { $0.uuidString < $1.uuidString }, forKey: .connections)
        }
    }
}

/// An access token's record. The token itself is never kept, only a salted hash of it.
public struct MCPToken: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The token's first characters, to tell tokens apart (`mr_AbC12x`).
    public var prefix: String
    var hash: String
    var salt: String
    public var permission: MCPPermission
    public var access: MCPConnectionAccess
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var expiresAt: Date?
    /// False once revoked; a revoked token is kept, for the activity log, until deleted.
    public var isActive: Bool
    /// The app that paired for it, so pairing again replaces it.
    public var client: String?
    /// Made at each start for moonrow-mcp, and replaced then.
    public var isAutomatic: Bool

    public var isUsable: Bool { isActive && !(expiresAt.map { $0 <= Date() } ?? false) }

    public var status: String {
        if !isActive { return "Revoked" }
        if let expiresAt, expiresAt <= Date() { return "Expired" }
        return "Active"
    }
}

/// Where the token records (or the TLS certificate) are kept: one blob of JSON.
public protocol MCPTokenStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// A generic-password item in the login Keychain: service `app.moonrow.mcp`, account `tokens`
/// for the tokens, `certificate` for the TLS certificate and key.
public struct KeychainTokenStorage: MCPTokenStorage {
    public static let service = "app.moonrow.mcp"
    public let account: String
    let label: String

    public init(account: String = "tokens", label: String = "Moonrow MCP access tokens") {
        self.account = account
        self.label = label
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status) }
        return data
    }

    public func save(_ data: Data) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    var status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var description: String {
        "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
    }
}

/// A file, for development runs under `MOONROW_STORE` and for tests.
public struct FileTokenStorage: MCPTokenStorage {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Data? {
        do { return try Data(contentsOf: url) } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public final class MemoryTokenStorage: MCPTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func load() throws -> Data? { lock.withLock { data } }
    public func save(_ data: Data) throws { lock.withLock { self.data = data } }
}

/// The access tokens. Safe to use from any thread.
public final class MCPTokenStore: @unchecked Sendable {
    /// Posted after tokens are added, changed or removed (not for last-used times).
    public static let didChange = Notification.Name("MCPTokenStore.didChange")

    /// Tokens start with this, so they're recognisable in config files and logs.
    public static let tokenPrefix = "mr_"

    private let storage: any MCPTokenStorage
    private let lock = NSLock()
    private var records: [MCPToken] = []
    private var lastPersisted = Date.distantPast

    /// Throws when the stored records can't be read or understood, so they're never written over.
    public init(storage: any MCPTokenStorage) throws {
        self.storage = storage
        if let data = try storage.load() {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([MCPToken].self, from: data)
        }
    }

    public var tokens: [MCPToken] { lock.withLock { records } }

    public func token(id: UUID) -> MCPToken? { lock.withLock { records.first { $0.id == id } } }

    /// Makes a token and returns its record and the token itself, which is shown once.
    @discardableResult
    public func create(
        name: String, permission: MCPPermission, access: MCPConnectionAccess = .all,
        client: String? = nil, automatic: Bool = false, expiresAt: Date? = nil
    ) throws -> (MCPToken, String) {
        let secret = Self.tokenPrefix + Self.randomBase64URL(32)
        let salt = Self.randomBase64URL(16)
        let record = MCPToken(
            id: UUID(), name: name.isEmpty ? "Untitled Token" : name,
            prefix: String(secret.prefix(Self.tokenPrefix.count + 6)),
            hash: Self.hash(secret, salt: salt), salt: salt, permission: permission, access: access,
            createdAt: Date(), lastUsedAt: nil, expiresAt: expiresAt, isActive: true, client: client,
            isAutomatic: automatic)
        try change { $0.append(record) }
        return (record, secret)
    }

    /// The usable token `secret` is, if any; marks it used.
    public func verify(_ secret: String) -> MCPToken? {
        guard secret.hasPrefix(Self.tokenPrefix) else { return nil }
        var save: Data?
        let found: MCPToken? = lock.withLock {
            // Every record is checked, so the time taken doesn't say which one matched.
            var match: Int?
            for (i, r) in records.enumerated() where Self.equal(Self.hash(secret, salt: r.salt), r.hash) { match = i }
            guard let i = match, records[i].isUsable else { return nil }
            records[i].lastUsedAt = Date()
            // Last-used times are saved at most once a minute.
            if Date().timeIntervalSince(lastPersisted) > 60 {
                lastPersisted = Date()
                save = encoded()
            }
            return records[i]
        }
        if let save { try? storage.save(save) }
        return found
    }

    public func revoke(id: UUID) throws {
        try change { records in
            for i in records.indices where records[i].id == id { records[i].isActive = false }
        }
    }

    public func delete(id: UUID) throws {
        try change { $0.removeAll { $0.id == id } }
    }

    public func rename(id: UUID, to name: String) throws {
        try change { records in
            for i in records.indices where records[i].id == id { records[i].name = name }
        }
    }

    /// Removes the tokens made for moonrow-mcp, and those a client paired for, before a new one.
    public func removeAutomatic() throws {
        try change { $0.removeAll(where: \.isAutomatic) }
    }

    public func revoke(client: String) throws {
        try change { records in
            for i in records.indices where records[i].client == client { records[i].isActive = false }
        }
    }

    /// Drops a deleted connection from the tokens that list it.
    public func forget(connection id: UUID) throws {
        try change { records in
            for i in records.indices {
                if case .only(var ids) = records[i].access, ids.remove(id) != nil { records[i].access = .only(ids) }
            }
        }
    }

    private func change(_ body: (inout [MCPToken]) -> Void) throws {
        let data: Data = lock.withLock {
            body(&records)
            lastPersisted = Date()
            return encoded()
        }
        try storage.save(data)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(records)) ?? Data("[]".utf8)
    }

    static func hash(_ secret: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + ":" + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func randomBase64URL(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
