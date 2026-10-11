import Foundation

public enum DriverKind: String, Codable, Sendable, CaseIterable {
    case sqlite

    public var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        }
    }
}

/// A saved connection. Secrets never live here; they go to the Keychain once drivers need them.
public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var driver: DriverKind
    /// SQLite: path to the database file. A leading `~` is expanded when connecting.
    public var filePath: String
    public var readOnly: Bool

    public init(
        id: UUID = UUID(), name: String = "", driver: DriverKind = .sqlite,
        filePath: String = "", readOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.filePath = filePath
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, driver, filePath, readOnly
    }

    // Fields added in later versions get defaults, so older files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decode(DriverKind.self, forKey: .driver)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    public var expandedFilePath: String { (filePath as NSString).expandingTildeInPath }

    /// The name, or the file name when the connection has none.
    public var displayName: String {
        if !name.isEmpty { return name }
        let file = (filePath as NSString).lastPathComponent
        return file.isEmpty ? "Untitled" : file
    }

    /// One line describing where the connection points, e.g. `SQLite · ~/data/app.db`.
    public var summary: String {
        var parts = [driver.displayName]
        if !filePath.isEmpty { parts.append((expandedFilePath as NSString).abbreviatingWithTildeInPath) }
        if readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    /// A connection for a file opened directly (Finder, ⌘O); not saved unless the user asks.
    public static func sqliteFile(_ url: URL) -> ConnectionConfig {
        ConnectionConfig(name: url.lastPathComponent, driver: .sqlite, filePath: url.path)
    }
}
