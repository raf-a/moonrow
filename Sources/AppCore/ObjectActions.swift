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
        if connection.dialect is SQLiteDialect {
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
            let counter = connection.dialect is SQLiteDialect && options.restartIdentity
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

    /// Clone… of a table: its structure (and rows) under `name`.
    public static func clonePlan(
        _ table: TableRef, as name: String, withData: Bool, on connection: any DatabaseConnection
    ) async throws -> DDLPlan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError("The clone needs a name.") }
        return try connection.dialect.clone(try await connection.structure(of: table), as: trimmed, withData: withData)
    }

    /// What the definition editor shows for an existing object. Triggers come from the table's
    /// structure (`TriggerInfo.definition`).
    public static func definitionText(_ object: DefinedObject, on connection: any DatabaseConnection) async throws -> String {
        if object.kind == .trigger, let table = object.table {
            guard let t = try await connection.triggers(of: table).first(where: { $0.name == object.ref.name }) else {
                throw DatabaseError("There's no trigger \(object.ref.name) on \(table.name).")
            }
            return t.definition.hasSuffix(";") ? t.definition : t.definition + ";"
        }
        guard let o = object.object else { throw DatabaseError("Nothing to show.") }
        let text = try await connection.definition(of: o)
        guard !text.isEmpty else { throw DatabaseError("\(o.ref.name) has no definition the database will show.") }
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}
