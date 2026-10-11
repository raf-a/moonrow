import CryptoKit
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
    /// Rows per page in table grids; 0 shows every row.
    public var rowsPerPage: Int

    public init(
        id: UUID = UUID(), name: String = "", driver: DriverKind = .sqlite,
        filePath: String = "", readOnly: Bool = false, rowsPerPage: Int = Paging.defaultPageSize
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.filePath = filePath
        self.readOnly = readOnly
        self.rowsPerPage = max(0, rowsPerPage)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, driver, filePath, readOnly, rowsPerPage
    }

    // Fields added in later versions get defaults, so older files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decode(DriverKind.self, forKey: .driver)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        rowsPerPage = max(0, try c.decodeIfPresent(Int.self, forKey: .rowsPerPage) ?? Paging.defaultPageSize)
    }

    /// The grid's page size: nil for every row.
    public var pageSize: Int? { rowsPerPage > 0 ? rowsPerPage : nil }

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
    /// The id comes from the path, so the file's query history and saved queries are there
    /// again the next time it's opened.
    public static func sqliteFile(_ url: URL) -> ConnectionConfig {
        let path = url.standardizedFileURL.path
        return ConnectionConfig(id: stableID(for: "sqlite:" + path), name: url.lastPathComponent, driver: .sqlite, filePath: path)
    }

    /// A name-based UUID (version 5 layout, SHA-1 of the name).
    static func stableID(for name: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
