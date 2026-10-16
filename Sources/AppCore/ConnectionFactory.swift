import DBKit
import DriverMySQL
import DriverPostgres
import DriverRemoteSQLite
import DriverSQLite
import Foundation
@_exported import SSHTunnel
import WireSupport

/// What logging in to a connection's SSH server takes besides the saved config.
public struct SSHLogin: Sendable {
    /// The saved (or just typed) SSH password and key passphrase; they answer ssh's first
    /// prompt for each.
    public var password: String?
    public var keyPassphrase: String?
    /// Asks the user everything else; nil cancels those prompts.
    public var responder: SSHPromptResponder?
    /// Gets answers the user asked to keep, once the login worked.
    public var onSave: (@Sendable (SSHSecret, String) -> Void)?
    /// Known-hosts files, the first getting accepted keys; empty leaves it to ssh.
    public var knownHostsFiles: [String]
    /// For tests: another ssh config file ("none"), no agent, another askpass helper.
    public var configFile: String?
    public var useAgent: Bool
    public var helperPath: String?

    public init(
        password: String? = nil, keyPassphrase: String? = nil, responder: SSHPromptResponder? = nil,
        onSave: (@Sendable (SSHSecret, String) -> Void)? = nil, knownHostsFiles: [String] = [],
        configFile: String? = nil, useAgent: Bool = true, helperPath: String? = nil
    ) {
        self.password = password
        self.keyPassphrase = keyPassphrase
        self.responder = responder
        self.onSave = onSave
        self.knownHostsFiles = knownHostsFiles
        self.configFile = configFile
        self.useAgent = useAgent
        self.helperPath = helperPath
    }

    /// Our own file next to the connections (accepted keys are written there), then the
    /// user's, which ssh reads but we never write.
    public static func knownHostsFiles(root: URL) -> [String] {
        [root.appending(path: "known_hosts").path, ("~/.ssh/known_hosts" as NSString).expandingTildeInPath]
    }
}

/// Turns a saved connection into a live one.
public enum ConnectionFactory {
    /// Opens the connection and runs one cheap query, so a wrong file or server fails here
    /// rather than on the first click in the workspace. `password` is the one to log in with,
    /// already looked up or asked for according to the connection's password mode.
    ///
    /// Over SSH the connection carries its tunnel: the drivers open every socket through it,
    /// and it ends (ssh processes included) when the connection is released.
    ///
    /// A SQLite file over SSH runs the server's own sqlite3 on the live file; when the server has
    /// none, that fails with `RemoteSQLiteError.noSQLite`, and `remoteCopy` opens a copy of the
    /// file instead, downloaded through the tunnel and never uploaded.
    public static func open(
        _ config: ConnectionConfig, password: String? = nil, ssh: SSHLogin = SSHLogin(), remoteCopy: Bool = false
    ) async throws -> any DatabaseConnection {
        switch config.driver {
        case .sqlite where config.usesSSH:
            if remoteCopy { return try await openRemoteCopy(config, passphrase: password, ssh) }
            return try await openRemoteSQLite(config, ssh)
        case .sqlite:
            return try await openSQLite(config, passphrase: config.passwordMode == .none ? nil : password)
        case .postgres:
            var c = postgresConfiguration(config, password: password)
            if config.usesSSH { c.endpoint = try tunnelEndpoint(config, ssh) }
            return try await PostgresConnection.connect(c)
        case .mysql, .mariadb:
            var c = mysqlConfiguration(config, password: password)
            if config.usesSSH { c.endpoint = try tunnelEndpoint(config, ssh) }
            return try await MySQLConnection.connect(c)
        }
    }

    /// Opens, checks and closes. For the form's Test button. Returns what the server is (MySQL or
    /// MariaDB) for the MySQL family, else nil.
    @discardableResult
    public static func test(_ config: ConnectionConfig, password: String? = nil, ssh: SSHLogin = SSHLogin()) async throws -> DriverKind? {
        let connection = try await open(config, password: password, ssh: ssh)
        let kind = serverKind(of: connection)
        await connection.close()
        return kind
    }

    /// MySQL or MariaDB, as the server reports its version; nil for other databases.
    public static func serverKind(of connection: any DatabaseConnection) -> DriverKind? {
        guard let my = connection as? MySQLConnection else { return nil }
        return my.isMariaDB ? .mariadb : .mysql
    }

    /// The tunnel settings for a connection over SSH.
    public static func tunnelConfiguration(_ c: ConnectionConfig, _ login: SSHLogin) throws -> SSHTunnelConfiguration {
        let host = c.sshHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw DatabaseError("Enter the SSH server to connect through.") }
        let key = c.sshKeyPath.trimmingCharacters(in: .whitespaces)
        return SSHTunnelConfiguration(
            host: host, port: c.sshPort, user: c.sshUser.trimmingCharacters(in: .whitespaces),
            identityFile: key.isEmpty ? nil : (key as NSString).expandingTildeInPath,
            password: c.sshPasswordMode == .none ? nil : login.password, keyPassphrase: login.keyPassphrase,
            knownHostsFiles: login.knownHostsFiles, configFile: login.configFile, useAgent: login.useAgent,
            helperPath: login.helperPath ?? SSHTunnel.defaultHelperPath)
    }

    private static func tunnelEndpoint(_ c: ConnectionConfig, _ login: SSHLogin) throws -> Endpoint {
        let tunnel = try makeTunnel(c, login)
        let host = c.host.trimmingCharacters(in: .whitespaces)
        return tunnel.endpoint(host: host.isEmpty ? "127.0.0.1" : host, port: c.effectivePort)
    }

    /// The database's host and port as the SSH server sees them.
    public static func tunnelTarget(_ c: ConnectionConfig) -> (host: String, port: Int) {
        let host = c.host.trimmingCharacters(in: .whitespaces)
        return (host.isEmpty ? "127.0.0.1" : host, c.effectivePort)
    }

    /// A tunnel for the connection, with the password mode deciding which prompts reach the
    /// user and which answers may be kept. Not logged in yet.
    public static func makeTunnel(_ c: ConnectionConfig, _ login: SSHLogin) throws -> SSHTunnel {
        guard !c.usesSocket else {
            throw DatabaseError(
                "A socket can't be reached over SSH. Enter the database's host and port as the SSH server sees them (127.0.0.1 for the SSH server itself).")
        }
        let mode = c.sshPasswordMode
        // The password mode decides whether ssh's password prompt reaches the user and whether
        // the answer may be kept; a key passphrase may always be kept.
        var responder: SSHPromptResponder?
        if let ask = login.responder {
            responder = { (request: SSHPromptRequest) async -> SSHAnswer? in
                var request = request
                if case .password = request.prompt {
                    if mode == .none { return nil }
                    request.offersSave = mode == .keychain
                }
                return await ask(request)
            }
        }
        var onSave: (@Sendable (SSHSecret, String) -> Void)?
        if let save = login.onSave {
            onSave = { (secret: SSHSecret, value: String) in
                if secret == .password, mode != .keychain { return }
                save(secret, value)
            }
        }
        return try SSHTunnel(tunnelConfiguration(c, login), responder: responder, onSave: onSave)
    }

    static func postgresConfiguration(_ c: ConnectionConfig, password: String?) -> PostgresConfiguration {
        var endpoint = endpoint(c)
        // A socket directory gets libpq's file name for the port.
        if case .unixSocket(let path) = endpoint {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                endpoint = .unixSocket(path: (path as NSString).appendingPathComponent(".s.PGSQL.\(c.effectivePort)"))
            }
        }
        return PostgresConfiguration(
            endpoint: endpoint, user: c.user.isEmpty ? NSUserName() : c.user, password: password,
            database: c.database.isEmpty ? nil : c.database, tls: tls(c), directTLS: c.tlsDirect, readOnly: c.readOnly,
            bootstrap: c.bootstrapStatements)
    }

    static func mysqlConfiguration(_ c: ConnectionConfig, password: String?) -> MySQLConfiguration {
        MySQLConfiguration(
            endpoint: endpoint(c), user: c.user.isEmpty ? "root" : c.user, password: password ?? "",
            database: c.database.isEmpty ? nil : c.database, tls: tls(c), readOnly: c.readOnly,
            bootstrap: c.bootstrapStatements)
    }

    private static func endpoint(_ c: ConnectionConfig) -> Endpoint {
        let host = c.host.trimmingCharacters(in: .whitespaces)
        if c.usesSocket { return .unixSocket(path: (host as NSString).expandingTildeInPath) }
        return .tcp(host: host.isEmpty ? "127.0.0.1" : host, port: c.effectivePort)
    }

    private static func tls(_ c: ConnectionConfig) -> TLSSettings {
        func path(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (t as NSString).expandingTildeInPath
        }
        let name = c.tlsServerName.trimmingCharacters(in: .whitespaces)
        return TLSSettings(
            mode: c.tlsMode, caCertificatePath: path(c.tlsCAPath),
            clientCertificatePath: path(c.tlsCertPath), clientKeyPath: path(c.tlsKeyPath),
            serverName: name.isEmpty ? nil : name)
    }

    /// The file's own sqlite3 on the SSH server, one process per session. Encrypted files can't
    /// be opened this way (the server's sqlite3 has no SQLCipher), so the passphrase isn't used.
    private static func openRemoteSQLite(_ config: ConnectionConfig, _ login: SSHLogin) async throws -> any DatabaseConnection {
        let path = config.filePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw DatabaseError("Enter the database file's path on the SSH server.") }
        let tunnel = try makeTunnel(config, login)
        let command = RemoteSQLiteConfiguration.command(sqlite3: config.remoteSQLiteCommand, path: path, readOnly: config.readOnly)
        let remote = RemoteSQLiteConfiguration(
            endpoint: tunnel.commandEndpoint(command, description: path), path: path, bootstrap: config.bootstrapStatements,
            interrupt: { pid in _ = try? await tunnel.run("kill -INT \(pid)") })
        do {
            return try await RemoteSQLiteConnection.connect(remote)
        } catch RemoteSQLiteError.noSQLite {
            await tunnel.close()
            throw RemoteSQLiteError.noSQLite(config.remoteSQLiteCommand)
        } catch {
            await tunnel.close()
            throw error
        }
    }

    /// A copy of the file on the SSH server (with its -wal, so recent writes come along),
    /// downloaded through the tunnel into a private folder that goes when the connection closes.
    private static func openRemoteCopy(_ config: ConnectionConfig, passphrase: String?, _ login: SSHLogin) async throws -> any DatabaseConnection {
        let path = config.filePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw DatabaseError("Enter the database file's path on the SSH server.") }
        let tunnel = try makeTunnel(config, login)
        defer { Task { await tunnel.close() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: "moonrow-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let name = (path as NSString).lastPathComponent.isEmpty ? "database.sqlite" : (path as NSString).lastPathComponent
            let local = folder.appending(path: name)
            func read(_ suffix: String) -> String {
                "exec sh -c " + SSHTunnelConfiguration.shellQuoted(
                    #"f=$1; case $f in "~/"*) f=$HOME/${f#??};; esac; "# +
                    (suffix.isEmpty ? #"[ -f "$f" ] || { echo "No file at $1" >&2; exit 3; }; cat -- "$f""#
                                    : #"[ -f "$f\#(suffix)" ] && cat -- "$f\#(suffix)"; exit 0"#))
                    + " sh " + SSHTunnelConfiguration.shellQuoted(path)
            }
            try await tunnel.run(read("")).write(to: local)
            let wal = try await tunnel.run(read("-wal"))
            if !wal.isEmpty { try wal.write(to: URL(filePath: local.path + "-wal")) }
            var copy = config
            copy.overSSH = false
            copy.filePath = local.path
            let connection = try await openSQLite(copy, passphrase: config.passwordMode == .none ? nil : passphrase)
            if let sqlite = connection as? SQLiteConnection {
                await sqlite.markAsCopy(of: "\(config.sshUser.isEmpty ? "" : config.sshUser + "@")\(config.sshHost):\(path)", removing: folder)
            }
            return connection
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `passphrase` opens a SQLCipher database; nil opens a plain one.
    private static func openSQLite(_ config: ConnectionConfig, passphrase: String?) async throws -> any DatabaseConnection {
        let path = config.expandedFilePath
        guard !path.isEmpty else { throw DatabaseError("Choose a database file.") }
        // SQLite would otherwise create an empty database at a mistyped path.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DatabaseError("There is no file at \(path).")
        }
        guard !isDirectory.boolValue else { throw DatabaseError("\(path) is a folder, not a database file.") }

        // Reading the schema (inside `open`) is what rejects non-databases and wrong passphrases.
        let connection = try await SQLiteConnection.open(path: path, readOnly: config.readOnly, passphrase: passphrase)
        // A file has one session, opened once, so its bootstrap runs once.
        for sql in config.bootstrapStatements {
            do {
                _ = try await connection.execute(SQLStatement(sql))
            } catch {
                await connection.close()
                throw DatabaseError.bootstrap(error, sql: sql)
            }
        }
        return connection
    }
}
