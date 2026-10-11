import DBKit
import DriverSQLite
import Foundation

/// Turns a saved connection into a live one.
public enum ConnectionFactory {
    /// Opens the connection and runs one cheap query, so a wrong file or server fails here
    /// rather than on the first click in the workspace.
    public static func open(_ config: ConnectionConfig) async throws -> any DatabaseConnection {
        switch config.driver {
        case .sqlite:
            return try await openSQLite(config)
        }
    }

    /// Opens, checks and closes. For the form's Test button.
    public static func test(_ config: ConnectionConfig) async throws {
        try await open(config).close()
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
