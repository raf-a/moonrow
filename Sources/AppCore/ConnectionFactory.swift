import DBKit
import DriverMySQL
import DriverPostgres
import DriverSQLite
import Foundation
import WireSupport

/// Turns a saved connection into a live one.
public enum ConnectionFactory {
    /// Opens the connection and runs one cheap query, so a wrong file or server fails here
    /// rather than on the first click in the workspace. `password` is the one to log in with,
    /// already looked up or asked for according to the connection's password mode.
    public static func open(_ config: ConnectionConfig, password: String? = nil) async throws -> any DatabaseConnection {
        switch config.driver {
        case .sqlite:
            return try await openSQLite(config)
        case .postgres:
            return try await PostgresConnection.connect(postgresConfiguration(config, password: password))
        case .mysql, .mariadb:
            return try await MySQLConnection.connect(mysqlConfiguration(config, password: password))
        }
    }

    /// Opens, checks and closes. For the form's Test button.
    public static func test(_ config: ConnectionConfig, password: String? = nil) async throws {
        try await open(config, password: password).close()
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
