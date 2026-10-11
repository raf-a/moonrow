import DBKit
import DriverMySQL
import DriverPostgres
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
    public static func open(
        _ config: ConnectionConfig, password: String? = nil, ssh: SSHLogin = SSHLogin()
    ) async throws -> any DatabaseConnection {
        switch config.driver {
        case .sqlite:
            return try await openSQLite(config)
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

    /// Opens, checks and closes. For the form's Test button.
    public static func test(_ config: ConnectionConfig, password: String? = nil, ssh: SSHLogin = SSHLogin()) async throws {
        try await open(config, password: password, ssh: ssh).close()
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
        let tunnel = try SSHTunnel(tunnelConfiguration(c, login), responder: responder, onSave: onSave)
        let host = c.host.trimmingCharacters(in: .whitespaces)
        return tunnel.endpoint(host: host.isEmpty ? "127.0.0.1" : host, port: c.effectivePort)
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
            database: c.database.isEmpty ? nil : c.database, tls: tls(c), readOnly: c.readOnly)
    }

    static func mysqlConfiguration(_ c: ConnectionConfig, password: String?) -> MySQLConfiguration {
        MySQLConfiguration(
            endpoint: endpoint(c), user: c.user.isEmpty ? "root" : c.user, password: password ?? "",
            database: c.database.isEmpty ? nil : c.database, tls: tls(c), readOnly: c.readOnly)
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
        return TLSSettings(
            mode: c.tlsMode, caCertificatePath: path(c.tlsCAPath),
            clientCertificatePath: path(c.tlsCertPath), clientKeyPath: path(c.tlsKeyPath))
    }

    private static func openSQLite(_ config: ConnectionConfig) async throws -> any DatabaseConnection {
        let path = config.expandedFilePath
        guard !path.isEmpty else { throw DatabaseError("Choose a database file.") }
        // SQLite would otherwise create an empty database at a mistyped path.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DatabaseError("There is no file at \(path).")
        }
        guard !isDirectory.boolValue else { throw DatabaseError("\(path) is a folder, not a database file.") }

        let connection = try SQLiteConnection(path: path, readOnly: config.readOnly)
        do {
            // Opening succeeds for any file; reading the schema is what rejects non-databases.
            _ = try await connection.execute("SELECT count(*) FROM sqlite_master")
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }
}
