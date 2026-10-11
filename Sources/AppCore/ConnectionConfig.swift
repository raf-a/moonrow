import CryptoKit
import Foundation
import WireSupport

public enum DriverKind: String, Codable, Sendable, CaseIterable {
    case sqlite
    case postgres
    case mysql
    case mariadb

    public var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        }
    }

    public var isServer: Bool { self != .sqlite }

    public var defaultPort: Int {
        switch self {
        case .sqlite: 0
        case .postgres: 5432
        case .mysql, .mariadb: 3306
        }
    }

    /// TLS modes the form offers, in menu order; the first is the default.
    public var tlsModes: [TLSMode] {
        switch self {
        case .sqlite: []
        case .postgres: [.prefer, .disable, .require, .allow, .verifyCA, .verifyFull]
        case .mysql, .mariadb: [.prefer, .disable, .require, .verifyCA, .verifyFull]
        }
    }

    /// What the vendor's own tools call a TLS mode.
    public func label(for mode: TLSMode) -> String {
        switch (self, mode) {
        case (.postgres, .disable): "DISABLE"
        case (.postgres, .allow): "ALLOW"
        case (.postgres, .prefer): "PREFER"
        case (.postgres, .require): "REQUIRE"
        case (.postgres, .verifyCA): "VERIFY-CA"
        case (.postgres, .verifyFull): "VERIFY-FULL"
        case (_, .disable): "DISABLED"
        case (_, .allow), (_, .prefer): "PREFERRED"
        case (_, .require): "REQUIRED"
        case (_, .verifyCA): "VERIFY_CA"
        case (_, .verifyFull): "VERIFY_IDENTITY"
        }
    }
}

public enum PasswordMode: String, Codable, Sendable, CaseIterable {
    /// Saved in the Keychain (or the dev secrets file); see `SecretStore`.
    case keychain
    /// Asked for on every connect, never saved.
    case ask
    /// The server needs none.
    case none
}

/// A saved connection. Passwords never live here; they go to a `SecretStore`.
public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var driver: DriverKind
    /// SQLite: path to the database file. A leading `~` is expanded when connecting.
    public var filePath: String
    /// Servers: host name or IP. A path starting with `/` or `~` is a Unix socket (Postgres: the
    /// socket's directory or the socket itself; MySQL: the socket file).
    public var host: String
    /// Nil uses the driver's default port.
    public var port: Int?
    public var user: String
    /// Postgres: the database to connect to (default: the user's name). MySQL: the default
    /// database, optional.
    public var database: String
    public var passwordMode: PasswordMode
    public var tlsMode: TLSMode
    /// PEM files; empty uses the system's trust store and no client certificate.
    public var tlsCAPath: String
    public var tlsCertPath: String
    public var tlsKeyPath: String
    public var readOnly: Bool
    /// Rows per page in table grids; 0 shows every row.
    public var rowsPerPage: Int

    public init(
        id: UUID = UUID(), name: String = "", driver: DriverKind = .sqlite,
        filePath: String = "", host: String = "", port: Int? = nil, user: String = "", database: String = "",
        passwordMode: PasswordMode = .keychain, tlsMode: TLSMode? = nil,
        tlsCAPath: String = "", tlsCertPath: String = "", tlsKeyPath: String = "",
        readOnly: Bool = false, rowsPerPage: Int = Paging.defaultPageSize
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.filePath = filePath
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.passwordMode = passwordMode
        self.tlsMode = tlsMode ?? driver.tlsModes.first ?? .disable
        self.tlsCAPath = tlsCAPath
        self.tlsCertPath = tlsCertPath
        self.tlsKeyPath = tlsKeyPath
        self.readOnly = readOnly
        self.rowsPerPage = max(0, rowsPerPage)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, driver, filePath, host, port, user, database, passwordMode
        case tlsMode, tlsCAPath, tlsCertPath, tlsKeyPath, readOnly, rowsPerPage
    }

    // Fields added in later versions get defaults, so older files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decode(DriverKind.self, forKey: .driver)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        passwordMode = try c.decodeIfPresent(PasswordMode.self, forKey: .passwordMode) ?? .keychain
        tlsMode = try c.decodeIfPresent(TLSMode.self, forKey: .tlsMode) ?? driver.tlsModes.first ?? .disable
        tlsCAPath = try c.decodeIfPresent(String.self, forKey: .tlsCAPath) ?? ""
        tlsCertPath = try c.decodeIfPresent(String.self, forKey: .tlsCertPath) ?? ""
        tlsKeyPath = try c.decodeIfPresent(String.self, forKey: .tlsKeyPath) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        rowsPerPage = max(0, try c.decodeIfPresent(Int.self, forKey: .rowsPerPage) ?? Paging.defaultPageSize)
    }

    /// The grid's page size: nil for every row.
    public var pageSize: Int? { rowsPerPage > 0 ? rowsPerPage : nil }

    public var expandedFilePath: String { (filePath as NSString).expandingTildeInPath }

    public var effectivePort: Int { port ?? driver.defaultPort }

    public var usesSocket: Bool { host.hasPrefix("/") || host.hasPrefix("~") }

    /// The name, or something recognisable when the connection has none.
    public var displayName: String {
        if !name.isEmpty { return name }
        if driver.isServer {
            let place = host.isEmpty ? "localhost" : host
            return database.isEmpty ? place : "\(database) on \(place)"
        }
        let file = (filePath as NSString).lastPathComponent
        return file.isEmpty ? "Untitled" : file
    }

    /// One line describing where the connection points, e.g. `PostgreSQL · app@db.local:5432/shop`.
    public var summary: String {
        var parts = [driver.displayName]
        if driver.isServer {
            var target = user.isEmpty ? "" : user + "@"
            target += host.isEmpty ? "localhost" : host
            if !usesSocket, port != nil { target += ":\(effectivePort)" }
            if !database.isEmpty { target += "/" + database }
            parts.append(target)
        } else if !filePath.isEmpty {
            parts.append((expandedFilePath as NSString).abbreviatingWithTildeInPath)
        }
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

extension ConnectionConfig {
    /// `postgres://user:password@host:port/database?sslmode=require`, `mysql://…`, `mariadb://…`.
    /// Returns the connection (not saved) and the password in the URL, if any.
    public static func parse(url text: String) -> (ConnectionConfig, password: String?)? {
        guard let u = URLComponents(string: text), let scheme = u.scheme?.lowercased() else { return nil }
        let driver: DriverKind
        switch scheme {
        case "postgres", "postgresql": driver = .postgres
        case "mysql": driver = .mysql
        case "mariadb": driver = .mariadb
        default: return nil
        }
        var c = ConnectionConfig(driver: driver)
        c.host = u.host ?? ""
        c.port = u.port
        c.user = u.user ?? ""
        c.database = String(u.path.drop { $0 == "/" })
        let mode = u.queryItems?.first { ["sslmode", "ssl-mode", "tlsmode"].contains($0.name.lowercased()) }?.value
        if let mode {
            let modes: [String: TLSMode] = [
                "disable": .disable, "disabled": .disable, "allow": .allow, "prefer": .prefer, "preferred": .prefer,
                "require": .require, "required": .require, "verify-ca": .verifyCA, "verify_ca": .verifyCA,
                "verify-full": .verifyFull, "verify_identity": .verifyFull,
            ]
            if let m = modes[mode.lowercased()] { c.tlsMode = m }
        }
        let password = u.password
        c.passwordMode = password == nil ? .none : .keychain
        return (c, password)
    }
}
