import CryptoKit
import DBKit
import Foundation
import SQLScript
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

    /// How the database's SQL is split into statements.
    public var lexer: LexerDialect {
        switch self {
        case .sqlite: .sqlite
        case .postgres: .postgres
        case .mysql, .mariadb: .mysql
        }
    }

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

/// A tag's colour, which marks its connections in the list and on their workspace windows.
public enum ConnectionColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    public var title: String { rawValue.capitalized }
}

/// What a connection is for, with the colour that marks it. The store keeps the list
/// (`ConnectionStore.tags`); connections name theirs with `tagID`.
public struct ConnectionTag: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ConnectionColor

    public init(id: UUID = UUID(), name: String, color: ConnectionColor) {
        self.id = id
        self.name = name
        self.color = color
    }

    public static let local = builtIn("local", .gray)
    public static let testing = builtIn("testing", .purple)
    public static let development = builtIn("development", .blue)
    public static let staging = builtIn("staging", .orange)
    public static let production = builtIn("production", .red)

    /// The tags a store starts with. Their ids come from the names earlier versions saved in
    /// connections, so those connections keep their tag.
    public static let defaults: [ConnectionTag] = [.local, .testing, .development, .staging, .production]

    private static func builtIn(_ name: String, _ color: ConnectionColor) -> ConnectionTag {
        ConnectionTag(id: ConnectionConfig.stableID(for: "tag:" + name), name: name.capitalized, color: color)
    }

    private enum CodingKeys: String, CodingKey { case id, name, color }

    /// A colour a newer version may add falls back to gray.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Tag"
        color = (try? c.decodeIfPresent(ConnectionColor.self, forKey: .color)) ?? .gray
    }
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
    /// The server name sent in TLS's SNI and checked by VERIFY_IDENTITY, for proxies that route
    /// by it; empty uses the host. The form offers it for MySQL and MariaDB.
    public var tlsServerName: String
    /// Postgres 17+: start TLS at once instead of asking first (`sslnegotiation=direct`). Only
    /// when the TLS mode requires TLS.
    public var tlsDirect: Bool
    public var readOnly: Bool
    /// Servers: reach the database through an SSH server. `host` and `port` are then as that
    /// server sees them (127.0.0.1 is the SSH server itself).
    public var overSSH: Bool
    /// The SSH server: a host name, an IP or an alias from ~/.ssh/config.
    public var sshHost: String
    /// Nil leaves it to ssh (its config, else 22).
    public var sshPort: Int?
    /// Empty leaves it to ssh (its config, else the Mac's login name).
    public var sshUser: String
    public var sshPasswordMode: PasswordMode
    /// A private key file; empty lets ssh choose (~/.ssh/config, the agent, the default keys).
    public var sshKeyPath: String
    /// What the workspace asks before sending statements.
    public var safeMode: SafeMode
    /// The tag (`ConnectionStore.tags`); one the store no longer has counts as none.
    public var tagID: UUID?
    /// The welcome window's group (`ConnectionStore.groups`); nil when ungrouped.
    public var groupID: UUID?
    /// Where the saved queries live: a folder name inside the app's `Queries` folder, or a path
    /// (starting with `/` or `~`) to any folder. Connections with the same folder share their
    /// queries. Empty uses the connection's name (`SavedQueries.directory(root:for:)`).
    public var queriesFolder: String
    /// SQL every session runs right after connecting (and after reconnecting), before anything
    /// else: session settings such as `SET search_path` or `SET time_zone`.
    public var bootstrapSQL: String
    /// MySQL / MariaDB: the user chose to keep the type although the server is the other kind.
    /// Changing the host or port forgets it.
    public var keepsDriverForOtherServer: Bool
    /// SQLite over SSH: the server's sqlite3, a name on its PATH or a path; empty is `sqlite3`.
    public var sqliteCommand: String

    public init(
        id: UUID = UUID(), name: String = "", driver: DriverKind = .sqlite,
        filePath: String = "", host: String = "", port: Int? = nil, user: String = "", database: String = "",
        passwordMode: PasswordMode = .keychain, tlsMode: TLSMode? = nil,
        tlsCAPath: String = "", tlsCertPath: String = "", tlsKeyPath: String = "",
        tlsServerName: String = "", tlsDirect: Bool = false, readOnly: Bool = false,
        overSSH: Bool = false, sshHost: String = "", sshPort: Int? = nil, sshUser: String = "",
        sshPasswordMode: PasswordMode = .keychain, sshKeyPath: String = "",
        safeMode: SafeMode = .silent, tagID: UUID? = nil, groupID: UUID? = nil, queriesFolder: String = "",
        bootstrapSQL: String = "", keepsDriverForOtherServer: Bool = false, sqliteCommand: String = ""
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
        self.tlsServerName = tlsServerName
        self.tlsDirect = tlsDirect
        self.readOnly = readOnly
        self.overSSH = overSSH
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshPasswordMode = sshPasswordMode
        self.sshKeyPath = sshKeyPath
        self.safeMode = safeMode
        self.tagID = tagID
        self.groupID = groupID
        self.queriesFolder = queriesFolder
        self.bootstrapSQL = bootstrapSQL
        self.keepsDriverForOtherServer = keepsDriverForOtherServer
        self.sqliteCommand = sqliteCommand
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, driver, filePath, host, port, user, database, passwordMode
        case tlsMode, tlsCAPath, tlsCertPath, tlsKeyPath, tlsServerName, tlsDirect, readOnly
        case overSSH, sshHost, sshPort, sshUser, sshPasswordMode, sshKeyPath
        case safeMode, groupID, queriesFolder
        case tagID = "tag"
        case bootstrapSQL = "bootstrap"
        case keepsDriverForOtherServer, sqliteCommand
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
        tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName) ?? ""
        tlsDirect = try c.decodeIfPresent(Bool.self, forKey: .tlsDirect) ?? false
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        overSSH = try c.decodeIfPresent(Bool.self, forKey: .overSSH) ?? false
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort)
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
        sshPasswordMode = try c.decodeIfPresent(PasswordMode.self, forKey: .sshPasswordMode) ?? .keychain
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? ""
        // Values a newer version may add don't fail the file. An unknown safe mode errs on the
        // side of asking.
        safeMode = c.contains(.safeMode) ? (try? c.decode(SafeMode.self, forKey: .safeMode)) ?? .alert : .silent
        // Earlier versions saved a tag's name (and a colour of the connection's own, now dropped:
        // the tag carries the colour).
        if let id = try? c.decodeIfPresent(UUID.self, forKey: .tagID) {
            tagID = id
        } else {
            let name = (try? c.decodeIfPresent(String.self, forKey: .tagID)) ?? nil
            tagID = name.flatMap { n in ConnectionTag.defaults.first { $0.name.lowercased() == n.lowercased() }?.id }
        }
        groupID = try? c.decodeIfPresent(UUID.self, forKey: .groupID)
        queriesFolder = try c.decodeIfPresent(String.self, forKey: .queriesFolder) ?? ""
        bootstrapSQL = try c.decodeIfPresent(String.self, forKey: .bootstrapSQL) ?? ""
        keepsDriverForOtherServer = try c.decodeIfPresent(Bool.self, forKey: .keepsDriverForOtherServer) ?? false
        sqliteCommand = try c.decodeIfPresent(String.self, forKey: .sqliteCommand) ?? ""
    }

    /// The type to suggest when a MySQL connection reached a MariaDB server or the other way
    /// round (`server` is what the server says it is); nil when they agree or the user kept it.
    public func suggestedDriver(forServer server: DriverKind?) -> DriverKind? {
        guard let server, server != driver, [.mysql, .mariadb].contains(driver), [.mysql, .mariadb].contains(server),
              !keepsDriverForOtherServer else { return nil }
        return server
    }

    /// `bootstrapSQL` as statements, split as the query editor splits them (MySQL's `DELIMITER`
    /// included); comment-only statements are dropped.
    public var bootstrapStatements: [String] {
        SQLSplitter.split(bootstrapSQL, dialect: driver.lexer).map(\.text)
    }

    /// Whether connecting goes through SSH (servers only).
    public var usesSSH: Bool { driver.isServer && overSSH }

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
    public var summary: String { summary(file: (expandedFilePath as NSString).abbreviatingWithTildeInPath) }

    /// `summary` with only the database file's name, not its folder (the workspace's title).
    public var shortSummary: String { summary(file: (expandedFilePath as NSString).lastPathComponent) }

    /// The host (or socket) and the database, e.g. `db.local · shop`, or the database file's name:
    /// the connection list's second line.
    public var place: String {
        guard driver.isServer else { return (expandedFilePath as NSString).lastPathComponent }
        let server = host.isEmpty ? "localhost" : host
        return database.isEmpty ? server : server + " · " + database
    }

    private func summary(file: String) -> String {
        var parts = [driver.displayName]
        if driver.isServer {
            var target = user.isEmpty ? "" : user + "@"
            target += host.isEmpty ? "localhost" : host
            if !usesSocket, port != nil { target += ":\(effectivePort)" }
            if !database.isEmpty { target += "/" + database }
            parts.append(target)
            if usesSSH { parts.append("via SSH " + (sshUser.isEmpty ? "" : sshUser + "@") + sshHost) }
        } else if !filePath.isEmpty {
            parts.append(file)
        }
        if readOnly { parts.append("read-only") }
        if safeMode != .silent { parts.append("safe mode") }
        return parts.joined(separator: " · ")
    }

    /// An unsaved connection to a database file, for the dev harnesses, which name their
    /// database on the command line. The id comes from the path, so two harness workspaces on
    /// the same file share it.
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
    /// Also reads `name`, `tag` (or `env`: one of `tags`, by name) and `safeMode` (a level name, or
    /// `safeModeLevel` 0–4). Returns the connection (not saved) and the password in the URL, if any.
    public static func parse(url text: String, tags: [ConnectionTag] = ConnectionTag.defaults)
        -> (ConnectionConfig, password: String?)? {
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
        func item(_ names: String...) -> String? {
            u.queryItems?.first { names.contains($0.name.lowercased()) }?.value
        }
        if let name = item("name") { c.name = name }
        if let tag = item("tag", "env", "environment") {
            c.tagID = tags.first { $0.name.localizedCaseInsensitiveCompare(tag) == .orderedSame }?.id
        }
        if let level = item("safemode", "safemodelevel") {
            c.safeMode = Int(level).flatMap(SafeMode.init(level:)) ?? SafeMode(rawValue: level) ?? c.safeMode
        }
        let password = u.password
        c.passwordMode = password == nil ? .none : .keychain
        return (c, password)
    }

    /// Routes the connection through `ssh://user:password@host:port`. Returns the SSH password
    /// in the URL, if any.
    public mutating func applySSH(url text: String) throws -> String? {
        guard let u = URLComponents(string: text), u.scheme?.lowercased() == "ssh", let host = u.host, !host.isEmpty else {
            throw DatabaseError("Not an SSH URL: \(text)")
        }
        overSSH = true
        sshHost = host
        sshPort = u.port
        sshUser = u.user ?? ""
        sshPasswordMode = u.password == nil ? .none : .keychain
        return u.password
    }
}
