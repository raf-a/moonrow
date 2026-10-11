import DBKit
import Foundation
import WireSupport

/// A connection to a MySQL or MariaDB server over our own client protocol implementation.
public final class MySQLConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect: any Dialect = MySQLDialect()
    public let configuration: MySQLConfiguration
    /// As the server announced it, e.g. `8.4.3` or `11.4.4-MariaDB-ubu2404`.
    public let serverVersion: String
    private let host: SessionHost<MySQLSession>

    private init(configuration: MySQLConfiguration, first: MySQLSession) {
        self.configuration = configuration
        self.serverVersion = first.serverVersion
        self.host = SessionHost(first: first) { try await MySQLSession.open(configuration) }
    }

    public static func connect(_ configuration: MySQLConfiguration) async throws -> MySQLConnection {
        MySQLConnection(configuration: configuration, first: try await MySQLSession.open(configuration))
    }

    public var isMariaDB: Bool { serverVersion.contains("MariaDB") }

    /// The server's id for the current session (`CONNECTION_ID()`); changes after a reconnect.
    public var connectionID: UInt32 {
        get async throws { try await host.withSession { $0.connectionID } }
    }

    /// Whether the current session is encrypted.
    public var isTLS: Bool {
        get async throws { try await host.withSession { $0.io.wire.isTLS } }
    }

    public func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        host.stream(statement, batchSize: batchSize)
    }

    public func transaction(
        _ statements: [SQLStatement], verify: @Sendable (_ index: Int, _ rowsAffected: Int) throws -> Void
    ) async throws -> [Int] {
        let dialect = dialect
        return try await host.withSession { try await $0.transaction(statements, dialect: dialect, verify: verify) }
    }

    public func close() async {
        await host.close()
    }

    private func rows(_ sql: String, _ bindings: [DBValue] = []) async throws -> [[DBValue]] {
        try await host.withSession { try await $0.collect(SQLStatement(sql, bindings: bindings)).rows }
    }

    // MARK: - Introspection

    public func schemas() async throws -> [String] {
        try await rows("""
            SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
            ORDER BY SCHEMA_NAME
            """).compactMap { string($0[0]) }
    }

    public func currentSchema() async throws -> String? {
        try await rows("SELECT DATABASE()").first.flatMap { string($0[0]) }
    }

    public func objects(schema: String?) async throws -> [DatabaseObject] {
        let schemaValue = schema.map(DBValue.text) ?? .null
        let found = try await rows("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = COALESCE(?, DATABASE())
            UNION ALL
            SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA = COALESCE(?, DATABASE())
            """, [schemaValue, schemaValue])
        return found.compactMap { row -> DatabaseObject? in
            guard let name = string(row[0]), let type = string(row[1]) else { return nil }
            let kind: ObjectKind = switch type {
            case "VIEW", "SYSTEM VIEW": .view
            case "PROCEDURE", "FUNCTION": .function
            default: .table
            }
            return DatabaseObject(TableRef(schema: schema, name), kind: kind)
        }
        .sorted { ($0.ref.name, $0.kind.rawValue) < ($1.ref.name, $1.kind.rawValue) }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let found = try await rows("""
            SELECT c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT, k.ORDINAL_POSITION
            FROM information_schema.COLUMNS c
            LEFT JOIN information_schema.KEY_COLUMN_USAGE k
              ON k.TABLE_SCHEMA = c.TABLE_SCHEMA AND k.TABLE_NAME = c.TABLE_NAME
             AND k.COLUMN_NAME = c.COLUMN_NAME AND k.CONSTRAINT_NAME = 'PRIMARY'
            WHERE c.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND c.TABLE_NAME = ?
            ORDER BY c.ORDINAL_POSITION
            """, tableBindings(table))
        guard !found.isEmpty else { throw DatabaseError("no such table: \(table)") }
        return found.map { row in
            var defaultExpression = string(row[3])
            // MariaDB spells "no default / DEFAULT NULL" as the text NULL.
            if isMariaDB, defaultExpression == "NULL" { defaultExpression = nil }
            return ColumnInfo(
                name: string(row[0]) ?? "",
                typeName: string(row[1]) ?? "",
                isNullable: string(row[2]) == "YES",
                defaultExpression: defaultExpression,
                primaryKeyPosition: integer(row[4]))
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let found = try await rows("""
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, INDEX_TYPE
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """, tableBindings(table))
        var out: [IndexInfo] = []
        for row in found {
            let name = string(row[0]) ?? ""
            let column = string(row[2]) ?? "(expression)"
            if out.last?.name == name {
                out[out.count - 1].columns.append(column)
            } else {
                out.append(IndexInfo(
                    name: name, columns: [column], isUnique: integer(row[1]) == 0, isPrimary: name == "PRIMARY",
                    method: string(row[3])))
            }
        }
        return out
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let found = try await rows("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
                   k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND k.TABLE_NAME = ?
              AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """, tableBindings(table))
        var out: [ForeignKeyInfo] = []
        for row in found {
            let name = string(row[0]) ?? ""
            let column = string(row[1]) ?? ""
            let referenced = string(row[4]) ?? ""
            if out.last?.name == name {
                out[out.count - 1].columns.append(column)
                out[out.count - 1].referencedColumns.append(referenced)
            } else {
                out.append(ForeignKeyInfo(
                    name: name, columns: [column],
                    referencedTable: TableRef(schema: string(row[2]), string(row[3]) ?? ""),
                    referencedColumns: [referenced],
                    onUpdate: string(row[5]) ?? "NO ACTION", onDelete: string(row[6]) ?? "NO ACTION"))
            }
        }
        return out
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        try await rows("""
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
            FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = COALESCE(?, DATABASE()) AND EVENT_OBJECT_TABLE = ?
            ORDER BY TRIGGER_NAME
            """, tableBindings(table)).map { row in
            TriggerInfo(
                name: string(row[0]) ?? "", timing: string(row[1]) ?? "",
                events: [string(row[2]) ?? ""], definition: string(row[3]) ?? "")
        }
    }

    private func tableBindings(_ table: TableRef) -> [DBValue] {
        [table.schema.map(DBValue.text) ?? .null, .text(table.name)]
    }

    private func string(_ v: DBValue) -> String? {
        switch v {
        case .null: nil
        case .text(let s): s
        case .blob(let d): String(decoding: d, as: UTF8.self)
        default: v.displayString
        }
    }

    private func integer(_ v: DBValue) -> Int? {
        switch v {
        case .integer(let n): Int(n)
        case .text(let s): Int(s)
        default: nil
        }
    }
}
