import DBKit
import DriverSQLite
import Foundation

/// DDL for the sidebar's Rename, Truncate and Delete on whole tables and views. The dialect
/// writes the SQL; this fills in what only the live database knows.
public enum ObjectActions {
    public static func dropPlan(
        _ objects: [DatabaseObject], options: DropOptions, on connection: any DatabaseConnection
    ) async throws -> DDLPlan {
        var options = options
        if connection is SQLiteConnection {
            options.foreignKeysEnforced = try await connection.execute("PRAGMA foreign_keys").rows.first?.first == .integer(1)
        }
        return try objects.reduce(DDLPlan()) { plan, object in
            plan + (try connection.dialect.drop(object, options: options))
        }
    }

    public static func truncatePlan(
        _ tables: [TableRef], options: TruncateOptions, on connection: any DatabaseConnection
    ) async throws -> DDLPlan {
        var plan = DDLPlan()
        for table in tables {
            // Only SQLite keeps a separate counter (sqlite_sequence), for AUTOINCREMENT tables.
            let counter = connection is SQLiteConnection && options.restartIdentity
                ? try await connection.columns(of: table).contains(where: \.isAutoIncrement) : false
            plan = plan + connection.dialect.truncate(table, options: options, hasAutoIncrement: counter)
        }
        return plan
    }

    public static func renamePlan(_ object: DatabaseObject, to name: String, on connection: any DatabaseConnection) throws -> DDLPlan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError("The new name is empty.") }
        return try connection.dialect.rename(object, to: trimmed)
    }
}
