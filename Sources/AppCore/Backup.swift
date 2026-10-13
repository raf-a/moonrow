import DBKit
import DriverMySQL
import DriverPostgres
import Foundation
import SSHTunnel
import WireSupport

// Backup and restore with the databases' own tools (pg_dump / pg_restore / psql, mysqldump /
// mysql or MariaDB's), run as child processes: never through a shell, the password handed over
// in the environment (Postgres) or a private option file (MySQL), and over SSH through a local
// port carried by the connection's tunnel.

public struct BackupOptions: Codable, Hashable, Sendable {
    public enum PostgresFormat: String, Codable, Sendable, CaseIterable {
        /// pg_dump's own compressed archive, for pg_restore.
        case custom
        /// A SQL script, for psql (or Tabula's SQL import).
        case plain
        case tar
        /// A folder of files, one per table.
        case directory

        public var title: String {
            switch self {
            case .custom: "Custom archive (.dump)"
            case .plain: "SQL script (.sql)"
            case .tar: "Tar archive (.tar)"
            case .directory: "Directory"
            }
        }

        /// Empty for a directory.
        public var fileExtension: String {
            switch self {
            case .custom: "dump"
            case .plain: "sql"
            case .tar: "tar"
            case .directory: ""
            }
        }
    }

    public enum Content: String, Codable, Sendable, CaseIterable {
        case all, schemaOnly, dataOnly

        public var title: String {
            switch self {
            case .all: "Structure and data"
            case .schemaOnly: "Structure only"
            case .dataOnly: "Data only"
            }
        }
    }

    public var postgresFormat: PostgresFormat = .custom
    public var content: Content = .all
    /// Gzip a SQL script (Postgres plain format, MySQL).
    public var gzip = false
    // Postgres
    public var noOwner = false
    public var noPrivileges = false
    /// DROP … IF EXISTS before each CREATE.
    public var clean = false
    /// CREATE DATABASE and a connect to it at the top.
    public var createDatabase = false
    // MySQL
    public var singleTransaction = true
    public var routines = true
    public var events = false
    public var triggers = true
    public var addDropTable = true
    /// Leaves out tablespace statements, which need the PROCESS privilege to dump.
    public var noTablespaces = true
    /// More arguments for the tool, split like a shell would (quotes keep spaces).
    public var otherArguments = ""

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = BackupOptions()
        postgresFormat = value(.postgresFormat, d.postgresFormat)
        content = value(.content, d.content)
        gzip = value(.gzip, d.gzip)
        noOwner = value(.noOwner, d.noOwner)
        noPrivileges = value(.noPrivileges, d.noPrivileges)
        clean = value(.clean, d.clean)
        createDatabase = value(.createDatabase, d.createDatabase)
        singleTransaction = value(.singleTransaction, d.singleTransaction)
        routines = value(.routines, d.routines)
        events = value(.events, d.events)
        triggers = value(.triggers, d.triggers)
        addDropTable = value(.addDropTable, d.addDropTable)
        noTablespaces = value(.noTablespaces, d.noTablespaces)
        otherArguments = value(.otherArguments, d.otherArguments)
    }

    /// The file extension a backup gets; empty for a Postgres directory.
    public func fileExtension(_ family: DumpTool.Family) -> String {
        switch family {
        case .postgres:
            postgresFormat == .plain && gzip ? "sql.gz" : postgresFormat.fileExtension
        case .mysql:
            gzip ? "sql.gz" : "sql"
        }
    }
}

public struct RestoreOptions: Codable, Hashable, Sendable {
    public var content: BackupOptions.Content = .all
    // pg_restore
    public var clean = false
    public var noOwner = false
    public var noPrivileges = false
    /// One transaction (pg_restore, psql): all or nothing.
    public var singleTransaction = false
    /// Stop at the first error; otherwise errors are reported and the rest goes on
    /// (mysql --force, psql without ON_ERROR_STOP, pg_restore without --exit-on-error).
    public var stopOnError = true
    public var otherArguments = ""

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = RestoreOptions()
        content = value(.content, d.content)
        clean = value(.clean, d.clean)
        noOwner = value(.noOwner, d.noOwner)
        noPrivileges = value(.noPrivileges, d.noPrivileges)
        singleTransaction = value(.singleTransaction, d.singleTransaction)
        stopOnError = value(.stopOnError, d.stopOnError)
        otherArguments = value(.otherArguments, d.otherArguments)
    }
}

/// What a backup file holds, from its first bytes (or, for a folder, its table of contents).
// MARK: - Options as flags

/// The Backup and Restore windows show the tool's flags as tokens. Options that are a flag of
/// their own become that flag (on when it's there); `--format=`, `--schema-only` and the like
/// typed as tokens move to the window's popups; anything else is passed on as typed.
public enum ToolFlags {
    /// A flag an option stands for, and how to read and set it.
    struct Flag<Options> {
        let flag: String
        let get: (Options) -> Bool
        let set: (inout Options, Bool) -> Void
    }

    static func backupFlags(_ family: DumpTool.Family) -> [Flag<BackupOptions>] {
        switch family {
        case .postgres: [
            Flag(flag: "--no-owner", get: \.noOwner, set: { $0.noOwner = $1 }),
            Flag(flag: "--no-privileges", get: \.noPrivileges, set: { $0.noPrivileges = $1 }),
            Flag(flag: "--clean", get: \.clean, set: { $0.clean = $1 }),
            Flag(flag: "--create", get: \.createDatabase, set: { $0.createDatabase = $1 }),
        ]
        case .mysql: [
            Flag(flag: "--single-transaction", get: \.singleTransaction, set: { $0.singleTransaction = $1 }),
            Flag(flag: "--routines", get: \.routines, set: { $0.routines = $1 }),
            Flag(flag: "--triggers", get: \.triggers, set: { $0.triggers = $1 }),
            Flag(flag: "--events", get: \.events, set: { $0.events = $1 }),
            Flag(flag: "--add-drop-table", get: \.addDropTable, set: { $0.addDropTable = $1 }),
            Flag(flag: "--databases", get: \.createDatabase, set: { $0.createDatabase = $1 }),
        ]
        }
    }

    static func restoreFlags(_ family: DumpTool.Family) -> [Flag<RestoreOptions>] {
        switch family {
        case .postgres: [
            Flag(flag: "--clean", get: \.clean, set: { $0.clean = $1 }),
            Flag(flag: "--no-owner", get: \.noOwner, set: { $0.noOwner = $1 }),
            Flag(flag: "--no-privileges", get: \.noPrivileges, set: { $0.noPrivileges = $1 }),
            Flag(flag: "--single-transaction", get: \.singleTransaction, set: { $0.singleTransaction = $1 }),
            Flag(flag: "--exit-on-error", get: \.stopOnError, set: { $0.stopOnError = $1 }),
        ]
        case .mysql: [
            Flag(flag: "--force", get: { !$0.stopOnError }, set: { $0.stopOnError = !$1 }),
        ]
        }
    }

    /// What Add Option… offers for a backup: the options' flags, then a few the tool takes as is.
    public static func backupMenu(_ family: DumpTool.Family) -> [String] {
        backupFlags(family).map(\.flag) + (family == .postgres
            ? ["--no-comments", "--no-publications", "--no-subscriptions", "--quote-all-identifiers"]
            : ["--hex-blob", "--complete-insert", "--skip-extended-insert", "--compress"])
    }

    public static func restoreMenu(_ family: DumpTool.Family) -> [String] {
        restoreFlags(family).map(\.flag) + (family == .postgres
            ? ["--disable-triggers", "--no-comments", "--no-data-for-failed-tables"]
            : ["--binary-mode", "--compress"])
    }

    /// The tokens for the options: their flags in the menu's order, then the other arguments.
    static func tokens<O>(_ o: O, _ flags: [Flag<O>], other: String) -> [String] {
        let rest = (try? ToolCommand.splitArguments(other)) ?? [other]
        return flags.filter { $0.get(o) }.map(\.flag) + rest.map(ToolCommand.shellQuoted)
    }

    /// Reads tokens back: each is split as a shell would; known flags set their options, the
    /// rest becomes the other arguments. `special` takes the flags that move to a popup.
    static func apply<O>(_ tokens: [String], to o: inout O, _ flags: [Flag<O>], other: inout String,
                         special: (String, inout O) -> Bool) throws {
        var arguments: [String] = []
        for token in tokens { arguments += try ToolCommand.splitArguments(token) }
        var on = Set<String>()
        var rest: [String] = []
        for a in arguments {
            if flags.contains(where: { $0.flag == a }) {
                on.insert(a)
            } else if !special(a, &o) {
                rest.append(a)
            }
        }
        for f in flags { f.set(&o, on.contains(f.flag)) }
        other = rest.map(ToolCommand.shellQuoted).joined(separator: " ")
    }
}

extension BackupOptions {
    public func tokens(_ family: DumpTool.Family) -> [String] {
        ToolFlags.tokens(self, ToolFlags.backupFlags(family), other: otherArguments)
    }

    /// Sets the options from the window's tokens. Throws on an unclosed quote.
    public mutating func setTokens(_ tokens: [String], _ family: DumpTool.Family) throws {
        var other = ""
        try ToolFlags.apply(tokens, to: &self, ToolFlags.backupFlags(family), other: &other) { a, o in
            switch (family, a) {
            case (.postgres, "--schema-only"), (.mysql, "--no-data"): o.content = .schemaOnly
            case (.postgres, "--data-only"), (.mysql, "--no-create-info"): o.content = .dataOnly
            case (.postgres, _) where a.hasPrefix("--format="):
                guard let f = PostgresFormat(flag: String(a.dropFirst("--format=".count))) else { return false }
                o.postgresFormat = f
            default: return false
            }
            return true
        }
        otherArguments = other
    }
}

extension BackupOptions.PostgresFormat {
    /// pg_dump's names and letters for its formats.
    init?(flag: String) {
        switch flag.lowercased() {
        case "c", "custom": self = .custom
        case "p", "plain": self = .plain
        case "t", "tar": self = .tar
        case "d", "directory": self = .directory
        default: return nil
        }
    }
}

extension RestoreOptions {
    public func tokens(_ family: DumpTool.Family) -> [String] {
        ToolFlags.tokens(self, ToolFlags.restoreFlags(family), other: otherArguments)
    }

    public mutating func setTokens(_ tokens: [String], _ family: DumpTool.Family) throws {
        var other = ""
        try ToolFlags.apply(tokens, to: &self, ToolFlags.restoreFlags(family), other: &other) { a, o in
            guard family == .postgres else { return false }
            switch a {
            case "--schema-only": o.content = .schemaOnly
            case "--data-only": o.content = .dataOnly
            default: return false
            }
            return true
        }
        otherArguments = other
    }
}

public enum BackupFileKind: Sendable, Equatable {
    case postgresArchive
    case postgresTar
    case postgresDirectory
    case sql
    case sqlGzip

    public var title: String {
        switch self {
        case .postgresArchive: "pg_dump custom archive"
        case .postgresTar: "pg_dump tar archive"
        case .postgresDirectory: "pg_dump directory"
        case .sql: "SQL script"
        case .sqlGzip: "SQL script (gzip)"
        }
    }

    public var isPostgresArchive: Bool { [.postgresArchive, .postgresTar, .postgresDirectory].contains(self) }

    public static func detect(_ url: URL) throws -> BackupFileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DatabaseError("There is no file at \(url.path).")
        }
        if isDirectory.boolValue {
            guard FileManager.default.fileExists(atPath: url.appending(path: "toc.dat").path) else {
                throw DatabaseError("The folder isn't a pg_dump directory (it has no toc.dat).")
            }
            return .postgresDirectory
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 512) ?? Data()
        if head.starts(with: Data("PGDMP".utf8)) { return .postgresArchive }
        if GzipReader.isGzip(head) { return .sqlGzip }
        if head.count >= 262, head[257..<262] == Data("ustar".utf8) { return .postgresTar }
        return .sql
    }
}

/// Where a tool connects: the database's host and port, or a local port when tunnelled.
public struct ToolEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    /// A Unix socket (MySQL: the file; Postgres: the folder holding `.s.PGSQL.<port>`).
    public var socket: String?
    /// When tunnelled, 127.0.0.1: TLS still checks the certificate against `host`.
    public var hostAddress: String?

    public init(host: String, port: Int, socket: String? = nil, hostAddress: String? = nil) {
        self.host = host
        self.port = port
        self.socket = socket
        self.hostAddress = hostAddress
    }

    /// The connection's own host, port or socket.
    public static func direct(_ c: ConnectionConfig) -> ToolEndpoint {
        let host = c.host.trimmingCharacters(in: .whitespaces)
        if c.usesSocket {
            var path = (host as NSString).expandingTildeInPath
            if c.driver == .postgres {
                // libpq takes the socket's folder, and the port names the file in it.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    path = (path as NSString).deletingLastPathComponent
                }
            }
            return ToolEndpoint(host: host, port: c.effectivePort, socket: path)
        }
        return ToolEndpoint(host: host.isEmpty ? "127.0.0.1" : host, port: c.effectivePort)
    }
}

/// A tool run: what to start, what it reads and where its output goes.
public struct ToolCommand: Sendable {
    public enum Input: Sendable {
        case none
        case file(URL)
        /// The file decompressed on the way in.
        case gunzip(URL)
    }

    public enum Output: Sendable {
        /// Lines go to the log.
        case log
        /// Standard output written to the file.
        case file(URL)
        /// Standard output gzipped into the file.
        case gzip(URL)
    }

    public var tool: ToolInfo
    public var arguments: [String]
    /// Added to a minimal environment (PATH, HOME, LANG, TMPDIR).
    public var environment: [String: String]
    public var input: Input = .none
    public var output: Output = .log
    /// Files holding secrets, removed when the run ends.
    public var secretFiles: [URL] = []

    /// The command line as a shell would take it, for the log. Passwords never appear in it.
    public var display: String {
        ([tool.path] + arguments).map(Self.shellQuoted).joined(separator: " ")
            + {
                switch input {
                case .none: ""
                case .file(let u): " < " + Self.shellQuoted(u.path)
                case .gunzip(let u): " < " + Self.shellQuoted(u.path) + " (decompressed)"
                }
            }()
            + {
                switch output {
                case .log: ""
                case .file(let u): " > " + Self.shellQuoted(u.lastPathComponent)
                case .gzip(let u): " | gzip > " + Self.shellQuoted(u.lastPathComponent)
                }
            }()
    }

    static func shellQuoted(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@,+%".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits extra arguments the way a shell would: spaces separate, quotes keep them, a
    /// backslash escapes the next character.
    public static func splitArguments(_ text: String) throws -> [String] {
        var out: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\", quote != "'" {
                escaped = true
                inWord = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c.isWhitespace {
                if inWord { out.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
        }
        if quote != nil { throw DatabaseError("A quote in the extra options isn't closed.") }
        if inWord { out.append(current) }
        return out
    }
}

/// Builds the tools' command lines.
public enum BackupCommands {
    /// What every tool run needs to log in.
    public struct Login: Sendable {
        public var config: ConnectionConfig
        public var password: String?
        public var endpoint: ToolEndpoint
        public var database: String

        public init(config: ConnectionConfig, password: String?, endpoint: ToolEndpoint, database: String) {
            self.config = config
            self.password = password
            self.endpoint = endpoint
            self.database = database
        }

        var user: String {
            let u = config.user.trimmingCharacters(in: .whitespaces)
            return u.isEmpty ? (config.driver == .postgres ? NSUserName() : "root") : u
        }
    }

    // MARK: Postgres

    /// libpq's connection settings: host, port, user and database as arguments; the password,
    /// TLS and a tunnelled host address in the environment.
    static func postgresConnection(_ login: Login, databaseFlag: String = "--dbname") -> ([String], [String: String]) {
        let e = login.endpoint
        let args = ["--host=\(e.socket ?? e.host)", "--port=\(e.port)", "--username=\(login.user)", "\(databaseFlag)=\(login.database)", "--no-password"]
        var env: [String: String] = ["PGCONNECT_TIMEOUT": "15", "PGAPPNAME": "Tabula"]
        if let p = login.password { env["PGPASSWORD"] = p }
        if let a = e.hostAddress { env["PGHOSTADDR"] = a }
        if e.socket == nil {
            let mode: String = switch login.config.tlsMode {
            case .disable: "disable"
            case .allow: "allow"
            case .prefer: "prefer"
            case .require: "require"
            case .verifyCA: "verify-ca"
            case .verifyFull: "verify-full"
            }
            env["PGSSLMODE"] = mode
            for (key, path) in [("PGSSLROOTCERT", login.config.tlsCAPath), ("PGSSLCERT", login.config.tlsCertPath), ("PGSSLKEY", login.config.tlsKeyPath)] {
                let p = path.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { env[key] = (p as NSString).expandingTildeInPath }
            }
            // libpq checks the certificate in `require` mode too when ~/.postgresql/root.crt
            // exists; the connection's own sessions don't, so neither do its tools.
            if !login.config.tlsMode.verifiesCertificate { env["PGSSLROOTCERT"] = "/nonexistent/tabula-no-root-certificate" }
        }
        return (args, env)
    }

    /// `pg_dump` into `destination` (a file, or a folder for the directory format).
    public static func pgDump(_ tool: ToolInfo, _ login: Login, _ o: BackupOptions, destination: URL) throws -> ToolCommand {
        var (args, env) = postgresConnection(login)
        args.append("--format=\(o.postgresFormat.rawValue)")
        args.append("--verbose")
        switch o.content {
        case .all: break
        case .schemaOnly: args.append("--schema-only")
        case .dataOnly: args.append("--data-only")
        }
        if o.noOwner { args.append("--no-owner") }
        if o.noPrivileges { args.append("--no-privileges") }
        if o.clean, o.content != .dataOnly { args += ["--clean", "--if-exists"] }
        if o.createDatabase { args.append("--create") }
        if o.postgresFormat == .plain, o.gzip { args.append("--compress=6") }
        args += try ToolCommand.splitArguments(o.otherArguments)
        args.append("--file=\(destination.path)")
        return ToolCommand(tool: tool, arguments: args, environment: env)
    }

    /// `pg_restore` of an archive (custom, tar or directory) into the login's database.
    public static func pgRestore(_ tool: ToolInfo, _ login: Login, _ o: RestoreOptions, source: URL) throws -> ToolCommand {
        var (args, env) = postgresConnection(login)
        args.append("--verbose")
        switch o.content {
        case .all: break
        case .schemaOnly: args.append("--schema-only")
        case .dataOnly: args.append("--data-only")
        }
        if o.clean { args += ["--clean", "--if-exists"] }
        if o.noOwner { args.append("--no-owner") }
        if o.noPrivileges { args.append("--no-privileges") }
        if o.singleTransaction { args.append("--single-transaction") }
        if o.stopOnError { args.append("--exit-on-error") }
        args += try ToolCommand.splitArguments(o.otherArguments)
        args.append(source.path)
        return ToolCommand(tool: tool, arguments: args, environment: env)
    }

    /// `psql` running a SQL script (gzipped ones decompressed on the way in).
    public static func psql(_ tool: ToolInfo, _ login: Login, _ o: RestoreOptions, source: URL, gzipped: Bool) throws -> ToolCommand {
        var (args, env) = postgresConnection(login)
        args += ["--no-psqlrc", "--echo-errors"]
        if o.stopOnError { args += ["--set=ON_ERROR_STOP=1"] }
        if o.singleTransaction { args.append("--single-transaction") }
        args += try ToolCommand.splitArguments(o.otherArguments)
        var command = ToolCommand(tool: tool, arguments: args, environment: env)
        if gzipped {
            command.arguments.append("--file=-")
            command.input = .gunzip(source)
        } else {
            command.arguments.append("--file=\(source.path)")
        }
        return command
    }

    // MARK: MySQL / MariaDB

    /// The option file holding the password (`[client] password=…`), readable only by the user.
    static func optionFile(password: String?, in folder: URL, write: Bool = true) throws -> URL {
        let url = folder.appending(path: "client.cnf")
        guard write else { return url }
        var text = "[client]\n"
        if let password {
            let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            text += "password=\"\(escaped)\"\n"
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw DatabaseError("Couldn't write the client option file.")
        }
        return url
    }

    /// A private folder (0700) for the option file.
    public static func privateFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tabula-tool-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Login and TLS arguments; the option file must come first.
    static func mysqlConnection(_ tool: ToolInfo, _ login: Login, optionFile: URL) -> [String] {
        let e = login.endpoint
        var args = ["--defaults-extra-file=\(optionFile.path)"]
        if let socket = e.socket {
            args += ["--protocol=socket", "--socket=\(socket)"]
        } else {
            args += ["--protocol=tcp", "--host=\(e.hostAddress ?? e.host)", "--port=\(e.port)"]
        }
        args.append("--user=\(login.user)")
        guard e.socket == nil else { return args }
        let c = login.config
        if tool.isMariaDB {
            switch c.tlsMode {
            case .disable: args.append("--skip-ssl")
            case .allow, .prefer, .require: args += ["--ssl", "--skip-ssl-verify-server-cert"]
            case .verifyCA: args += ["--ssl", "--skip-ssl-verify-server-cert"]
            case .verifyFull: args += ["--ssl", "--ssl-verify-server-cert"]
            }
        } else {
            let mode: String = switch c.tlsMode {
            case .disable: "DISABLED"
            case .allow, .prefer: "PREFERRED"
            case .require: "REQUIRED"
            case .verifyCA: "VERIFY_CA"
            case .verifyFull: "VERIFY_IDENTITY"
            }
            args.append("--ssl-mode=\(mode)")
        }
        for (flag, path) in [("--ssl-ca", c.tlsCAPath), ("--ssl-cert", c.tlsCertPath), ("--ssl-key", c.tlsKeyPath)] {
            let p = path.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { args.append("\(flag)=\((p as NSString).expandingTildeInPath)") }
        }
        return args
    }

    /// `mysqldump` (or MariaDB's) of one database; its output goes to the file, gzipped or not.
    /// `serverIsMariaDB` turns off what MySQL's tool asks only MySQL servers about.
    public static func mysqldump(
        _ tool: ToolInfo, _ login: Login, _ o: BackupOptions, destination: URL, folder: URL, serverIsMariaDB: Bool, write: Bool = true
    ) throws -> ToolCommand {
        let option = try optionFile(password: login.password, in: folder, write: write)
        var args = mysqlConnection(tool, login, optionFile: option)
        args.append("--verbose")
        if o.singleTransaction { args.append("--single-transaction") }
        if o.routines { args.append("--routines") }
        if o.events { args.append("--events") }
        args.append(o.triggers ? "--triggers" : "--skip-triggers")
        args.append(o.addDropTable ? "--add-drop-table" : "--skip-add-drop-table")
        if o.noTablespaces { args.append("--no-tablespaces") }
        switch o.content {
        case .all: break
        case .schemaOnly: args.append("--no-data")
        case .dataOnly: args.append("--no-create-info")
        }
        if !tool.isMariaDB, serverIsMariaDB || tool.major >= 8 {
            // MySQL 8's tool reads column statistics MariaDB doesn't have, and GTIDs a dump
            // restored elsewhere shouldn't carry.
            if serverIsMariaDB { args.append("--column-statistics=0") }
            args.append("--set-gtid-purged=OFF")
        }
        args += try ToolCommand.splitArguments(o.otherArguments)
        if o.createDatabase { args.append("--databases") }
        args.append(login.database)
        var command = ToolCommand(tool: tool, arguments: args, environment: [:], secretFiles: [option])
        command.output = o.gzip ? .gzip(destination) : .file(destination)
        return command
    }

    /// `mysql` (or `mariadb`) reading a script into the login's database.
    public static func mysqlRestore(_ tool: ToolInfo, _ login: Login, _ o: RestoreOptions, source: URL, gzipped: Bool, folder: URL,
                                    write: Bool = true) throws -> ToolCommand {
        let option = try optionFile(password: login.password, in: folder, write: write)
        var args = mysqlConnection(tool, login, optionFile: option)
        args.append("--verbose")
        if !o.stopOnError { args.append("--force") }
        args += try ToolCommand.splitArguments(o.otherArguments)
        args.append(login.database)
        var command = ToolCommand(tool: tool, arguments: args, environment: [:], secretFiles: [option])
        command.input = gzipped ? .gunzip(source) : .file(source)
        return command
    }
}

// MARK: - Running

/// Runs a tool to the end, its messages going to `log` a line at a time. Cancelling the task
/// stops it (SIGTERM, then SIGKILL after three seconds). A failure throws the tool's last
/// messages.
public enum ToolRunner {
    public static func run(_ command: ToolCommand, log: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(filePath: command.tool.path)
        process.arguments = command.arguments
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"].contains($0.key) }
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env.merge(command.environment) { $1 }
        process.environment = env

        // Each pipe read to its end before the run counts as finished.
        let drained = DispatchGroup()
        func read(_ pipe: Pipe, _ take: @escaping @Sendable (Data) -> Void, end: @escaping @Sendable () -> Void = {}) {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    end()
                    drained.leave()
                } else {
                    take(data)
                }
            }
        }

        let errors = LineCollector(log: log)
        let errPipe = Pipe()
        process.standardError = errPipe
        read(errPipe, { errors.add($0) }, end: { errors.flush() })

        // Standard input.
        var feed: Thread?
        let feeder = FeedState()
        switch command.input {
        case .none:
            process.standardInput = FileHandle.nullDevice
        case .file(let url):
            process.standardInput = try FileHandle(forReadingFrom: url)
        case .gunzip(let url):
            let reader = try GzipReader(url: url)
            let inPipe = Pipe()
            process.standardInput = inPipe
            let writer = inPipe.fileHandleForWriting
            // A tool that stops reading makes the write fail instead of signalling the app.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            let box = UncheckedBox(reader)
            feed = Thread {
                do {
                    while let piece = try box.value.next() {
                        if feeder.stopped { break }
                        try writer.write(contentsOf: piece)
                    }
                } catch {
                    feeder.fail(error)
                }
                try? writer.close()
            }
        }

        // Standard output.
        var outputDone: (() throws -> Void)?
        switch command.output {
        case .log:
            let lines = LineCollector(log: log)
            let outPipe = Pipe()
            process.standardOutput = outPipe
            read(outPipe, { lines.add($0) }, end: { lines.flush() })
        case .file(let url):
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw DatabaseError("Couldn't create \(url.lastPathComponent).")
            }
            let handle = try FileHandle(forWritingTo: url)
            process.standardOutput = handle
            outputDone = { try handle.close() }
        case .gzip(let url):
            let gzip = try GzipWriter(url: url)
            let outPipe = Pipe()
            process.standardOutput = outPipe
            let sink = GzipPump(gzip)
            read(outPipe, { sink.add($0) }, end: { sink.finish() })
            outputDone = { try sink.wait() }
        }

        log("$ " + command.display)
        defer {
            for f in command.secretFiles { try? FileManager.default.removeItem(at: f) }
        }
        let exit = ExitWaiter()
        process.terminationHandler = { exit.done($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw DatabaseError("Couldn't start \(command.tool.path): \(error.localizedDescription)")
        }
        feed?.start()
        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            feeder.stop()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // The pipes end once the tool and anything it started are gone.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            drained.notify(queue: .global()) { c.resume() }
        }
        let outputError: (any Error)? = {
            do { try outputDone?(); return nil } catch { return error }
        }()
        if Task.isCancelled { throw CancellationError() }
        if status != 0 {
            let tail = errors.tail.isEmpty ? "" : ": " + errors.tail.joined(separator: "\n")
            throw DatabaseError("\(command.tool.tool.rawValue) failed (exit status \(status))\(tail)")
        }
        if let failure = feeder.failure { throw failure }
        if let outputError { throw outputError }
    }
}

/// Splits output into lines for the log, keeping the last few for an error message.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var last: [String] = []
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    func add(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var out: [String] = []
            while let nl = pending.firstIndex(of: 10) {
                out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
            remember(out)
            return out
        }
        lines.forEach(log)
    }

    func flush() {
        let line: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending = Data() }
            let s = String(decoding: pending, as: UTF8.self)
            remember([s])
            return s
        }
        if let line { log(line) }
    }

    private func remember(_ lines: [String]) {
        last += lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if last.count > 8 { last.removeFirst(last.count - 8) }
    }

    /// The last messages, for an error.
    var tail: [String] { lock.withLock { last } }
}

/// Feeds a tool's output into a gzip file, in order, off the pipe's handler.
final class GzipPump: @unchecked Sendable {
    private let writer: GzipWriter
    private let queue = DispatchQueue(label: "tabula.gzip")
    private let done = DispatchSemaphore(value: 0)
    private var error: (any Error)?

    init(_ writer: GzipWriter) {
        self.writer = writer
    }

    func add(_ data: Data) {
        queue.async { [self] in
            guard error == nil else { return }
            do { try writer.write(data) } catch { self.error = error }
        }
    }

    func finish() {
        queue.async { [self] in
            do { try writer.close() } catch { if self.error == nil { self.error = error } }
            done.signal()
        }
    }

    func wait() throws {
        done.wait()
        if let error { throw error }
    }
}

final class FeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private var error: (any Error)?

    var stopped: Bool { lock.withLock { isStopped } }
    var failure: (any Error)? { lock.withLock { error } }
    func stop() { lock.withLock { isStopped = true } }
    func fail(_ e: any Error) { lock.withLock { if error == nil { error = e } } }
}

final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func done(_ s: Int32) {
        let w = lock.withLock {
            status = s
            defer { waiters = [] }
            return waiters
        }
        w.forEach { $0.resume(returning: s) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let status {
                lock.unlock()
                c.resume(returning: status)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

// MARK: - Jobs

/// What backup and restore read from a server: its databases and what kind of server it is.
public enum ServerInfo {
    /// Every database on the server, templates and system ones included, by name.
    public static func databases(_ connection: any DatabaseConnection) async throws -> [String] {
        let sql = connection.dialect is PostgresDialect ? "SELECT datname FROM pg_catalog.pg_database ORDER BY datname" : "SHOW DATABASES"
        return try await connection.execute(SQLStatement(sql)).rows.compactMap { $0.first?.string }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The server's major version and whether it's MariaDB.
    public static func version(_ connection: any DatabaseConnection) -> (major: Int?, mariaDB: Bool) {
        if let pg = connection as? PostgresConnection {
            return (Int(pg.serverVersion.prefix { $0.isNumber }), false)
        }
        if let my = connection as? MySQLConnection {
            return (Int(my.serverVersion.prefix { $0.isNumber }), my.isMariaDB)
        }
        return (nil, false)
    }

    /// The CREATE DATABASE a restore into a new database runs first.
    public static func createDatabase(_ name: String, dialect: any Dialect) -> String {
        "CREATE DATABASE \(dialect.quoteIdentifier(name))"
    }
}

/// Opens what a tool needs to reach the server: nothing for a direct connection, else the
/// connection's SSH tunnel and a local port carried through it, closed by `close()`.
public final class ToolAccess: @unchecked Sendable {
    public let endpoint: ToolEndpoint
    private let tunnel: SSHTunnel?
    private let forward: LocalForward?

    private init(endpoint: ToolEndpoint, tunnel: SSHTunnel?, forward: LocalForward?) {
        self.endpoint = endpoint
        self.tunnel = tunnel
        self.forward = forward
    }

    public static func open(_ config: ConnectionConfig, ssh: SSHLogin) async throws -> ToolAccess {
        guard config.usesSSH else { return ToolAccess(endpoint: .direct(config), tunnel: nil, forward: nil) }
        let tunnel = try ConnectionFactory.makeTunnel(config, ssh)
        let target = ConnectionFactory.tunnelTarget(config)
        do {
            let forward = try await tunnel.forward(host: target.host, port: target.port)
            return ToolAccess(endpoint: ToolEndpoint(host: target.host, port: forward.port, hostAddress: "127.0.0.1"),
                              tunnel: tunnel, forward: forward)
        } catch {
            await tunnel.close()
            throw error
        }
    }

    public func close() async {
        forward?.close()
        await tunnel?.close()
    }
}

/// Backs up one database to a file (or a pg_dump directory). The file is written under a
/// temporary name and moved into place when the tool succeeds.
public struct BackupJob: Sendable {
    public var config: ConnectionConfig
    public var password: String?
    public var ssh: SSHLogin
    public var database: String
    public var options: BackupOptions
    public var tool: ToolInfo
    public var serverIsMariaDB: Bool

    public init(config: ConnectionConfig, password: String?, ssh: SSHLogin = SSHLogin(), database: String, options: BackupOptions,
                tool: ToolInfo, serverIsMariaDB: Bool) {
        self.config = config
        self.password = password
        self.ssh = ssh
        self.database = database
        self.options = options
        self.tool = tool
        self.serverIsMariaDB = serverIsMariaDB
    }

    var family: DumpTool.Family { config.driver == .postgres ? .postgres : .mysql }

    /// The file name the pattern gives, with the format's extension.
    public func fileName(_ pattern: FileNamePattern, date: Date = Date()) -> String {
        let name = pattern.render(.init(database: database, connection: config.displayName, tag: config.tag?.rawValue ?? "", date: date),
                                  fallback: database)
        let ext = options.fileExtension(family)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// The command, written to `destination`.
    public func command(endpoint: ToolEndpoint, destination: URL, folder: URL, write: Bool = true) throws -> ToolCommand {
        let login = BackupCommands.Login(config: config, password: password, endpoint: endpoint, database: database)
        switch family {
        case .postgres: return try BackupCommands.pgDump(tool, login, options, destination: destination)
        case .mysql: return try BackupCommands.mysqldump(tool, login, options, destination: destination, folder: folder,
                                                         serverIsMariaDB: serverIsMariaDB, write: write)
        }
    }

    /// The command line, written nowhere: for the log sheet's first line.
    public func previewCommand(destination: URL) throws -> String {
        let endpoint = config.usesSSH ? ToolEndpoint(host: ConnectionFactory.tunnelTarget(config).host, port: 0, hostAddress: "127.0.0.1")
            : ToolEndpoint.direct(config)
        let command = try command(endpoint: endpoint, destination: destination, folder: URL(filePath: "/tmp/…"), write: false)
        return command.display.replacingOccurrences(of: "--port=0", with: "--port=<tunnel>")
    }

    /// Writes the backup to `destination`, replacing what's there only once the tool succeeds;
    /// a failure or a stop leaves nothing behind.
    public func run(to destination: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let access = try await ToolAccess.open(config, ssh: ssh)
        let secrets = try BackupCommands.privateFolder()
        defer { try? FileManager.default.removeItem(at: secrets) }
        do {
            let pending = PendingFile(destination)
            let command = try command(endpoint: access.endpoint, destination: pending.temporary, folder: secrets)
            try await pending.write { _ in try await ToolRunner.run(command, log: log) }
        } catch {
            await access.close()
            throw error
        }
        await access.close()
    }
}

/// Restores one backup file into one database: pg_restore for pg_dump archives, psql for SQL
/// scripts on Postgres, mysql (or mariadb) on MySQL and MariaDB.
public struct RestoreJob: Sendable {
    public var config: ConnectionConfig
    public var password: String?
    public var ssh: SSHLogin
    public var database: String
    public var file: URL
    public var kind: BackupFileKind
    public var options: RestoreOptions
    public var tool: ToolInfo

    public init(config: ConnectionConfig, password: String?, ssh: SSHLogin = SSHLogin(), database: String, file: URL,
                kind: BackupFileKind, options: RestoreOptions, tool: ToolInfo) {
        self.config = config
        self.password = password
        self.ssh = ssh
        self.database = database
        self.file = file
        self.kind = kind
        self.options = options
        self.tool = tool
    }

    /// Which tool a file needs on a connection; nil when it can't be restored there.
    public static func role(for kind: BackupFileKind, driver: DriverKind) -> ToolLocator.Role? {
        switch (driver, kind) {
        case (.postgres, let k) where k.isPostgresArchive: .restorePostgresArchive
        case (.postgres, .sql), (.postgres, .sqlGzip): .restorePostgresScript
        case (.mysql, .sql), (.mysql, .sqlGzip), (.mariadb, .sql), (.mariadb, .sqlGzip): .restoreMySQL
        default: nil
        }
    }

    public func command(endpoint: ToolEndpoint, folder: URL, write: Bool = true) throws -> ToolCommand {
        let login = BackupCommands.Login(config: config, password: password, endpoint: endpoint, database: database)
        switch Self.role(for: kind, driver: config.driver) {
        case .restorePostgresArchive: return try BackupCommands.pgRestore(tool, login, options, source: file)
        case .restorePostgresScript: return try BackupCommands.psql(tool, login, options, source: file, gzipped: kind == .sqlGzip)
        case .restoreMySQL: return try BackupCommands.mysqlRestore(tool, login, options, source: file, gzipped: kind == .sqlGzip, folder: folder, write: write)
        default: throw DatabaseError("A \(kind.title) can't be restored into \(config.driver.displayName).")
        }
    }

    /// The command line, written nowhere: for the window's preview.
    public func previewCommand() throws -> String {
        let endpoint = config.usesSSH ? ToolEndpoint(host: ConnectionFactory.tunnelTarget(config).host, port: 0, hostAddress: "127.0.0.1")
            : ToolEndpoint.direct(config)
        return try command(endpoint: endpoint, folder: URL(filePath: "/tmp/…"), write: false).display
            .replacingOccurrences(of: "--port=0", with: "--port=<tunnel>")
    }

    public func run(log: @escaping @Sendable (String) -> Void) async throws {
        let access = try await ToolAccess.open(config, ssh: ssh)
        let secrets = try BackupCommands.privateFolder()
        do {
            try await ToolRunner.run(try command(endpoint: access.endpoint, folder: secrets), log: log)
        } catch {
            try? FileManager.default.removeItem(at: secrets)
            await access.close()
            throw error
        }
        try? FileManager.default.removeItem(at: secrets)
        await access.close()
    }
}
