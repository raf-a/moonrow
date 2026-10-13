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

/// One copy of a tool found on this Mac.
public struct ToolInfo: Sendable, Hashable {
    public var tool: DumpTool
    public var path: String
    /// As the tool prints it (`pg_dump (PostgreSQL) 18.1`).
    public var versionText: String
    /// Major and minor, e.g. [18, 1] or [9, 5, 0].
    public var version: [Int]
    /// MariaDB's client (whatever its file is called).
    public var isMariaDB: Bool

    public var major: Int { version.first ?? 0 }
    public var versionString: String { version.map(String.init).joined(separator: ".") }

    /// The version in `--version` output: after "Distrib " (old MariaDB tools), "from "
    /// (new MariaDB tools), else the first number with a dot.
    public static func parse(_ output: String) -> (version: [Int], mariaDB: Bool) {
        let mariaDB = output.contains("MariaDB")
        let text = output.firstMatch(of: /(?:Distrib|from)\s+(\d+(?:\.\d+)+)/).map { String($0.1) }
            ?? output.firstMatch(of: /\d+\.\d+(?:\.\d+)?/).map { String($0.0) } ?? ""
        return (text.split(separator: ".").compactMap { Int($0) }, mariaDB)
    }
}

/// Finds the tools: in the folder chosen in Settings ▸ Locations when there is one (and only
/// there), else on PATH and in the usual install places (Homebrew, Postgres.app, the EDB and
/// MySQL installers, MacPorts). A GUI app's PATH is short, hence the list.
public struct ToolLocator: Sendable {
    /// Settings ▸ Locations, per family; empty means look everywhere.
    public var folders: [DumpTool.Family: String]
    public var path: String
    /// Runs `<tool> --version`; replaceable for tests.
    public var versionOf: @Sendable (String) -> String?

    public init(folders: [DumpTool.Family: String] = [:], path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                versionOf: @escaping @Sendable (String) -> String? = ToolLocator.runVersion) {
        self.folders = folders
        self.path = path
        self.versionOf = versionOf
    }

    public static let usualFolders: [DumpTool.Family: [String]] = [
        .postgres: [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin",
            "/opt/homebrew/opt/postgresql@*/bin", "/usr/local/opt/postgresql@*/bin", "/opt/homebrew/opt/libpq@*/bin",
            "/Applications/Postgres.app/Contents/Versions/*/bin", "/Library/PostgreSQL/*/bin", "/opt/local/lib/postgresql*/bin",
        ],
        .mysql: [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/opt/homebrew/opt/mysql-client/bin", "/usr/local/opt/mysql-client/bin", "/opt/homebrew/opt/mysql-client@*/bin",
            "/opt/homebrew/opt/mysql/bin", "/opt/homebrew/opt/mysql@*/bin", "/opt/homebrew/opt/mariadb/bin", "/opt/homebrew/opt/mariadb@*/bin",
            "/usr/local/mysql/bin", "/opt/local/lib/mysql*/bin", "/opt/local/lib/mariadb*/bin",
        ],
    ]

    /// Where to look for a family, in order.
    public func searchFolders(_ family: DumpTool.Family) -> [String] {
        if let chosen = folders[family]?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            return [(chosen as NSString).expandingTildeInPath]
        }
        let fromPath = path.split(separator: ":").map(String.init)
        return Self.unique(fromPath + (Self.usualFolders[family] ?? []).flatMap(Self.expand))
    }

    /// Every copy of `tool` found, newest version first; the same file reached twice counts once.
    public func find(_ tool: DumpTool) -> [ToolInfo] {
        var seen = Set<String>()
        var out: [ToolInfo] = []
        for folder in searchFolders(tool.family) {
            let candidate = (folder as NSString).appendingPathComponent(tool.rawValue)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let real = (candidate as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted, let output = versionOf(candidate) else { continue }
            let (version, mariaDB) = ToolInfo.parse(output)
            out.append(ToolInfo(tool: tool, path: candidate, versionText: output.trimmingCharacters(in: .whitespacesAndNewlines),
                                version: version, isMariaDB: mariaDB || tool == .mariadb || tool == .mariadbDump))
        }
        // Newest first; equal versions keep the search order.
        return out.enumerated().sorted { a, b in
            a.element.version != b.element.version ? a.element.version.lexicographicallyPrecedes(b.element.version) == false
                : a.offset < b.offset
        }.map(\.element)
    }

    /// The tool a backup or restore uses, and a warning when it may not suit the server.
    ///
    /// - Postgres: the newest copy (pg_dump refuses servers newer than itself; pg_restore and
    ///   psql come from the same folder as each other when they can).
    /// - MySQL family: a MariaDB server gets MariaDB's tools (`mariadb-dump`, `mariadb`, or a
    ///   `mysqldump` that is MariaDB's) when there are any; a MySQL server gets MySQL's.
    public func choose(_ role: Role, serverMajor: Int?, mariaDBServer: Bool) -> (ToolInfo?, warning: String?) {
        switch role {
        case .backupPostgres, .restorePostgresArchive, .restorePostgresScript:
            let tool: DumpTool = role == .backupPostgres ? .pgDump : role == .restorePostgresArchive ? .pgRestore : .psql
            let found = find(tool)
            guard let best = found.first else { return (nil, nil) }
            if let serverMajor, best.major < serverMajor, role == .backupPostgres {
                return (best, "\(tool.rawValue) \(best.versionString) is older than the server (\(serverMajor)); it refuses newer servers. Install PostgreSQL \(serverMajor)'s client tools.")
            }
            return (best, nil)
        case .backupMySQL, .restoreMySQL:
            let names: [DumpTool] = role == .backupMySQL ? [.mariadbDump, .mysqldump] : [.mariadb, .mysql]
            let found = names.flatMap(find)
            let preferred = found.filter { $0.isMariaDB == mariaDBServer }
            guard let best = preferred.first ?? found.first else { return (nil, nil) }
            if best.isMariaDB != mariaDBServer {
                let mine = mariaDBServer ? "MariaDB" : "MySQL"
                return (best, "Only \(best.isMariaDB ? "MariaDB" : "MySQL")'s \(best.tool.rawValue) was found; \(mine)'s own client tools suit a \(mine) server better.")
            }
            return (best, nil)
        }
    }

    public enum Role: Sendable {
        case backupPostgres, restorePostgresArchive, restorePostgresScript, backupMySQL, restoreMySQL
    }

    /// A folder pattern with one `*` in one of its parts (`/opt/homebrew/opt/postgresql@*/bin`),
    /// matched against what's there, newest-looking names first.
    static func expand(_ pattern: String) -> [String] {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let i = parts.firstIndex(where: { $0.contains("*") }) else { return [pattern] }
        let parent = parts[..<i].joined(separator: "/")
        let wildcard = parts[i].split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let below = parts[(i + 1)...].joined(separator: "/")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return entries.filter { $0.hasPrefix(wildcard[0]) && $0.hasSuffix(wildcard.count > 1 ? wildcard[1] : "") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { parent + "/" + $0 + (below.isEmpty ? "" : "/" + below) }
    }

    static func unique(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `<tool> --version`, or nil if it doesn't run within a few seconds.
    public static func runVersion(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
