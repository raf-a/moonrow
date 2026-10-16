import DBKit
import Foundation
import WireSupport

/// A connection to a MySQL or MariaDB server over our own client protocol implementation.
public final class MySQLConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect: any Dialect = MySQLDialect()
    public let configuration: MySQLConfiguration
    /// As the server announced it, e.g. `8.4.3` or `11.4.4-MariaDB-ubu2404`.
    public let serverVersion: String
    public let statementLog: StatementLog?
    private let host: SessionHost<MySQLSession>

    private init(configuration: MySQLConfiguration, first: MySQLSession, log: StatementLog) {
        self.configuration = configuration
        self.serverVersion = first.serverVersion
        self.statementLog = log
        self.host = SessionHost(first: first) { try await MySQLSession.open(configuration, log: log) }
    }

    public static func connect(_ configuration: MySQLConfiguration) async throws -> MySQLConnection {
        let log = StatementLog()
        let first = try await MySQLSession.open(configuration, log: log)
        return MySQLConnection(configuration: configuration, first: first, log: log)
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

    public func withTransaction<T: Sendable>(_ body: @Sendable (any TransactionScope) async throws -> T) async throws -> T {
        let dialect = dialect
        return try await host.withSession { session in
            _ = try await session.collect(SQLStatement(dialect.beginTransaction))
            do {
                let value = try await body(MySQLScope(session: session))
                _ = try await session.collect(SQLStatement(dialect.commitTransaction))
                return value
            } catch {
                if session.isAlive { _ = try? await session.collect(SQLStatement(dialect.rollbackTransaction)) }
                throw error
            }
        }
    }

    public func close() async {
        await host.close()
    }

    public func setKeepAlive(_ interval: Duration?) {
        host.setKeepAlive(interval)
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
            case "FUNCTION": .function
            case "PROCEDURE": .procedure
            default: .table
            }
            return DatabaseObject(TableRef(schema: schema, name), kind: kind)
        }
        .sorted { ($0.ref.name, $0.kind.rawValue) < ($1.ref.name, $1.kind.rawValue) }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let found = try await rows("""
            SELECT c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT, k.ORDINAL_POSITION,
                   c.EXTRA, c.COLUMN_COMMENT, c.COLLATION_NAME, c.GENERATION_EXPRESSION, c.DATA_TYPE
            FROM information_schema.COLUMNS c
            LEFT JOIN information_schema.KEY_COLUMN_USAGE k
              ON k.TABLE_SCHEMA = c.TABLE_SCHEMA AND k.TABLE_NAME = c.TABLE_NAME
             AND k.COLUMN_NAME = c.COLUMN_NAME AND k.CONSTRAINT_NAME = 'PRIMARY'
            WHERE c.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND c.TABLE_NAME = ?
            ORDER BY c.ORDINAL_POSITION
            """, tableBindings(table))
        guard !found.isEmpty else { throw DatabaseError("no such table: \(table)") }
        return found.map { row in
            let extra = string(row[5]) ?? ""
            let lowerExtra = extra.lowercased()
            var generated: String?
            if lowerExtra.contains("generated"), !lowerExtra.contains("default_generated"),
               let expression = string(row[8]), !expression.isEmpty {
                generated = "GENERATED ALWAYS AS (\(expression)) \(lowerExtra.contains("stored") ? "STORED" : "VIRTUAL")"
            }
            var onUpdate: String?
            if let r = extra.range(of: "on update ", options: .caseInsensitive) {
                onUpdate = String(extra[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            let comment = string(row[6]) ?? ""
            return ColumnInfo(
                name: string(row[0]) ?? "",
                typeName: string(row[1]) ?? "",
                isNullable: string(row[2]) == "YES",
                defaultExpression: generated == nil
                    ? defaultSQL(string(row[3]), extra: lowerExtra, dataType: string(row[9]) ?? "") : nil,
                primaryKeyPosition: integer(row[4]),
                comment: comment.isEmpty ? nil : comment,
                isAutoIncrement: lowerExtra.contains("auto_increment"),
                generated: generated,
                collation: string(row[7]),
                onUpdate: onUpdate)
        }
    }

    /// COLUMN_DEFAULT as SQL. MariaDB already writes it that way (`'text'`, `0`,
    /// `current_timestamp()`, `NULL`). MySQL gives a literal's bare value and marks expressions
    /// DEFAULT_GENERATED; those need parentheses unless they're CURRENT_TIMESTAMP.
    func defaultSQL(_ value: String?, extra: String, dataType: String) -> String? {
        guard let value else { return nil }
        if isMariaDB { return value == "NULL" ? nil : value }
        if extra.contains("default_generated") {
            let upper = value.uppercased()
            return upper.hasPrefix("CURRENT_TIMESTAMP") || upper.hasPrefix("NOW(") || value.hasPrefix("(") ? value : "(\(value))"
        }
        let numeric = ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric",
                       "float", "double", "real", "year"]
        if numeric.contains(dataType.lowercased()), Double(value) != nil { return value }
        if dataType.lowercased() == "bit", value.hasPrefix("b'") { return value }
        return dialect.literal(.text(value))
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        var s = TableStructure(
            table: table, columns: try await columns(of: table), indexes: try await indexes(of: table),
            foreignKeys: try await foreignKeys(of: table), triggers: try await triggers(of: table))
        let comment = try await rows("""
            SELECT TABLE_COMMENT FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
            """, tableBindings(table)).first.flatMap { string($0[0]) } ?? ""
        s.comment = comment.isEmpty ? nil : comment
        return s
    }

    public func definition(of object: DatabaseObject) async throws -> String {
        let name = dialect.qualified(object.ref)
        switch object.kind {
        case .view:
            return try await rows("SHOW CREATE VIEW \(name)").first.flatMap { string($0[1]) }.map { $0 + ";" } ?? ""
        case .function, .procedure:
            // SHOW CREATE FUNCTION/PROCEDURE: the statement is the third column.
            let what = object.kind == .function ? "FUNCTION" : "PROCEDURE"
            return try await rows("SHOW CREATE \(what) \(name)").first.flatMap { string($0[2]) }.map { $0 + ";" } ?? ""
        default:
            var statements = try await rows("SHOW CREATE TABLE \(name)").first.flatMap { string($0[1]) }.map { [$0] } ?? []
            statements += try await triggers(of: object.ref).map(\.definition)
            return statements.map { $0 + ";" }.joined(separator: "\n\n")
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

    /// The whole `CREATE TRIGGER` statement, as SHOW CREATE TRIGGER gives it (the trigger
    /// table only keeps the action).
    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        let found = try await rows("""
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, TRIGGER_SCHEMA
            FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = COALESCE(?, DATABASE()) AND EVENT_OBJECT_TABLE = ?
            ORDER BY TRIGGER_NAME
            """, tableBindings(table))
        var out: [TriggerInfo] = []
        for row in found {
            let name = string(row[0]) ?? ""
            let ref = dialect.qualified(TableRef(schema: string(row[3]), name))
            let sql = try await rows("SHOW CREATE TRIGGER \(ref)").first.flatMap { string($0[2]) } ?? ""
            out.append(TriggerInfo(name: name, timing: string(row[1]) ?? "", events: [string(row[2]) ?? ""], definition: sql))
        }
        return out
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

/// Statements inside `MySQLConnection.withTransaction`, on the session it holds.
struct MySQLScope: TransactionScope {
    let session: MySQLSession

    func execute(_ statement: SQLStatement) async throws -> Int {
        let signal = CancelSignal()
        let box = ResultBox()
        try await withTaskCancellationHandler {
            try await session.run(statement, batchSize: 10_000, cancel: signal) { box.add($0) }
        } onCancel: {
            signal.fire()
        }
        return box.result.rowsAffected ?? 0
    }
}
