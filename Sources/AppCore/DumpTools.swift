import DBKit
import Foundation

/// The command-line tools backup and restore run: PostgreSQL's and MySQL's or MariaDB's.
public enum DumpTool: String, Sendable, CaseIterable, Codable {
    case pgDump = "pg_dump"
    case pgRestore = "pg_restore"
    case psql
    case mysqldump
    case mysql
    case mariadbDump = "mariadb-dump"
    case mariadb

    public var family: Family { [.pgDump, .pgRestore, .psql].contains(self) ? .postgres : .mysql }

    public enum Family: String, Sendable, Codable {
        case postgres, mysql

        public var title: String { self == .postgres ? "PostgreSQL" : "MySQL / MariaDB" }
    }
}

/// One tool a backup or restore runs.
public struct ToolInfo: Sendable, Hashable {
    public var tool: DumpTool
    public var path: String
    /// `pg_dump 17.6`.
    public var versionText: String
    /// The release, e.g. [17, 6] or [8, 0, 43].
    public var version: [Int]
    /// MariaDB's client (whatever its file is called).
    public var isMariaDB: Bool

    public init(tool: DumpTool, path: String, versionText: String, version: [Int], isMariaDB: Bool) {
        self.tool = tool
        self.path = path
        self.versionText = versionText
        self.version = version
        self.isMariaDB = isMariaDB
    }

    public var major: Int { version.first ?? 0 }
    public var versionString: String { version.map(String.init).joined(separator: ".") }
}

/// The client tools of one release that ship with the app, in a folder named after its `id`:
/// `postgresql-17` holds pg_dump, pg_restore and psql.
public struct ToolKit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// PostgreSQL, MySQL or MariaDB.
    public var product: String
    /// The release, e.g. [17, 6].
    public var version: [Int]
    public var family: DumpTool.Family
    public var tools: [DumpTool]

    public init(id: String, product: String, version: [Int], family: DumpTool.Family, tools: [DumpTool]) {
        self.id = id
        self.product = product
        self.version = version
        self.family = family
        self.tools = tools
    }

    public var isMariaDB: Bool { product == "MariaDB" }
    public var major: Int { version.first ?? 0 }
    public var versionString: String { version.map(String.init).joined(separator: ".") }
    /// `PostgreSQL 17.6`.
    public var title: String { "\(product) \(versionString)" }
}

/// The backup and restore tools inside the app, one kit per server version: tools installed on
/// the Mac are never used. The kits are listed in `tools.json`.
public struct BundledTools: Sendable {
    public var kits: [ToolKit]
    /// The folder holding a folder per kit.
    public var root: URL

    public init(kits: [ToolKit], root: URL) {
        self.kits = kits
        self.root = root
    }

    /// The kits `manifest` lists, in `root`; none when it can't be read.
    public init(manifest: URL, root: URL) {
        let kits = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([ToolKit].self, from: $0) } ?? []
        self.init(kits: kits, root: root)
    }

    /// A folder laid out as the tools build leaves them: `tools.json` beside the kits.
    public init(folder: URL) {
        self.init(manifest: folder.appending(path: "tools.json"), root: folder)
    }

    /// The app's: `Contents/Helpers/tools`, listed in `Contents/Resources/tools.json`.
    /// `MOONROW_TOOLS` names a tools folder instead (tests, and running outside the app).
    public static let app: BundledTools = {
        if let folder = ProcessInfo.processInfo.environment["MOONROW_TOOLS"], !folder.isEmpty {
            return BundledTools(folder: URL(filePath: (folder as NSString).expandingTildeInPath))
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        return BundledTools(manifest: contents.appending(path: "Resources/tools.json"), root: contents.appending(path: "Helpers/tools"))
    }()

    /// A family's kits as the version menu lists them: newest first, MariaDB's before MySQL's.
    public func kits(for family: DumpTool.Family) -> [ToolKit] {
        kits.filter { $0.family == family }.sorted { a, b in
            a.isMariaDB != b.isMariaDB ? a.isMariaDB : b.version.lexicographicallyPrecedes(a.version)
        }
    }

    /// The kit for a server: the oldest whose major version isn't older than the server's, else
    /// the newest (and the newest when the version isn't known). A MariaDB server gets MariaDB's
    /// kit, a MySQL server MySQL's, when there is one.
    public func defaultKit(for family: DumpTool.Family, serverMajor: Int?, mariaDBServer: Bool) -> ToolKit? {
        var candidates = kits(for: family)
        if family == .mysql {
            let sameKind = candidates.filter { $0.isMariaDB == mariaDBServer }
            if !sameKind.isEmpty { candidates = sameKind }
        }
        guard let serverMajor else { return candidates.first }
        return candidates.last { $0.major >= serverMajor } ?? candidates.first
    }

    /// Why `kit` may not suit the server, if it may not.
    public func warning(_ kit: ToolKit, role: Role, serverMajor: Int?, mariaDBServer: Bool) -> String? {
        if kit.family == .mysql, kit.isMariaDB != mariaDBServer {
            let server = mariaDBServer ? "MariaDB" : "MySQL"
            return "These are \(kit.product)'s tools; \(server)'s own suit a \(server) server better."
        }
        if role.isBackup, let serverMajor, kit.major < serverMajor {
            return "\(role.tool(in: kit).rawValue) \(kit.versionString) is older than the server (\(serverMajor))"
                + (kit.family == .postgres ? " and refuses to back it up." : ".")
        }
        return nil
    }

    /// The tool `role` runs from `kit`; nil when the kit has no such file.
    public func tool(for role: Role, in kit: ToolKit) -> ToolInfo? {
        let tool = role.tool(in: kit)
        guard kit.family == tool.family, kit.tools.contains(tool) else { return nil }
        let path = root.appending(path: kit.id).appending(path: tool.rawValue).path
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return ToolInfo(tool: tool, path: path, versionText: "\(tool.rawValue) \(kit.versionString)", version: kit.version,
                        isMariaDB: kit.isMariaDB)
    }

    /// The tool `role` runs from the server's default kit, and why it may not suit the server.
    public func choose(_ role: Role, serverMajor: Int?, mariaDBServer: Bool) -> (ToolInfo?, warning: String?) {
        guard let kit = defaultKit(for: role.family, serverMajor: serverMajor, mariaDBServer: mariaDBServer) else { return (nil, nil) }
        return (tool(for: role, in: kit), warning(kit, role: role, serverMajor: serverMajor, mariaDBServer: mariaDBServer))
    }

    public enum Role: Sendable {
        case backupPostgres, restorePostgresArchive, restorePostgresScript, backupMySQL, restoreMySQL

        public var family: DumpTool.Family { [.backupMySQL, .restoreMySQL].contains(self) ? .mysql : .postgres }
        public var isBackup: Bool { self == .backupPostgres || self == .backupMySQL }

        /// The tool this role runs from `kit`.
        public func tool(in kit: ToolKit) -> DumpTool {
            switch self {
            case .backupPostgres: .pgDump
            case .restorePostgresArchive: .pgRestore
            case .restorePostgresScript: .psql
            case .backupMySQL: kit.isMariaDB ? .mariadbDump : .mysqldump
            case .restoreMySQL: kit.isMariaDB ? .mariadb : .mysql
            }
        }
    }
}
