import DBKit
import Foundation
import SQLScript

/// What the sidebar, the structure editor and the definitions read from a SQLite database, as
/// SQL over any way of running it: a local file (`SQLiteConnection`), or a file on a server
/// through its own sqlite3.
public struct SQLiteCatalog: Sendable {
    /// Runs a statement and returns its rows.
    public typealias Rows = @Sendable (SQLStatement) async throws -> [[DBValue]]

    private let query: Rows
    private let dialect = SQLiteDialect()

    public init(rows: @escaping Rows) {
        self.query = rows
    }

    public func objects(schema: String?) async throws -> [DatabaseObject] {
        let schemaName = schema ?? "main"
        let rows = try await query(SQLStatement("""
            SELECT type, name FROM \(dialect.quoteIdentifier(schemaName)).sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY name
            """))
        return rows.compactMap { row in
            guard case .text(let type) = row[0], case .text(let name) = row[1] else { return nil }
            return DatabaseObject(TableRef(schema: schema, name), kind: type == "view" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        // table_xinfo also lists generated columns (hidden 2 virtual, 3 stored); 1 is a virtual
        // table's hidden column.
        let rows = try await query(SQLStatement(
            #"SELECT name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?, ?) WHERE hidden <> 1"#,
            bindings: [.text(table.name), .text(table.schema ?? "main")]))
        guard !rows.isEmpty else { throw DatabaseError("no such table: \(table)") }
        let traits = try await tableSQL(table).map { dialect.columnTraits(definition: $0) } ?? [:]
        return rows.map { row in
            var pk: Int?
            if case .integer(let n) = row[4], n > 0 { pk = Int(n) }
            var defaultExpression: String?
            if case .text(let d) = row[3] { defaultExpression = d }
            let name = row[0].displayString
            let trait = traits[name.lowercased()]
            var generated = trait?.generated
            if generated == nil, case .integer(let hidden) = row[5], hidden >= 2 {
                generated = "GENERATED ALWAYS AS (…) \(hidden == 3 ? "STORED" : "VIRTUAL")"
            }
            return ColumnInfo(
                name: name,
                typeName: row[1].isNull ? "" : row[1].displayString,
                isNullable: row[2] != .integer(1),
                defaultExpression: defaultExpression,
                primaryKeyPosition: pk,
                isAutoIncrement: trait?.isAutoIncrement ?? false,
                generated: generated)
        }
    }

    /// The table's CREATE TABLE text.
    public func tableSQL(_ table: TableRef) async throws -> String? {
        let rows = try await query(SQLStatement(
            "SELECT sql FROM \(dialect.quoteIdentifier(table.schema ?? "main")).sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.text(table.name)]))
        if case .text(let sql)? = rows.first?.first { return sql }
        return nil
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        var s = TableStructure(
            table: table, columns: try await columns(of: table), indexes: try await indexes(of: table),
            foreignKeys: try await foreignKeys(of: table), triggers: try await triggers(of: table))
        s.definition = try await tableSQL(table)
        s.foreignKeysEnforced = try await query(SQLStatement("PRAGMA foreign_keys")).first?.first == .integer(1)
        return s
    }

    public func definition(of object: DatabaseObject) async throws -> String {
        // Tables and views as created, then their indexes and triggers.
        let rows = try await query(SQLStatement("""
            SELECT sql FROM \(dialect.quoteIdentifier(object.ref.schema ?? "main")).sqlite_master
            WHERE tbl_name = ? AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 WHEN 'index' THEN 1 ELSE 2 END, name
            """, bindings: [.text(object.ref.name)]))
        guard !rows.isEmpty else { throw DatabaseError("no such table: \(object.ref)") }
        return rows.map { $0[0].displayString + ";" }.joined(separator: "\n\n")
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let schema = table.schema ?? "main"
        let list = try await query(SQLStatement(
            #"SELECT name, "unique", origin, partial FROM pragma_index_list(?, ?) ORDER BY name"#,
            bindings: [.text(table.name), .text(schema)]))
        var indexes: [IndexInfo] = []
        for row in list {
            let name = row[0].displayString
            // pragma_index_xinfo lists key columns first (key = 1); cid -2 is an expression.
            let columns = try await query(SQLStatement(
                "SELECT name, cid FROM pragma_index_xinfo(?, ?) WHERE key = 1 ORDER BY seqno",
                bindings: [.text(name), .text(schema)]))
            // Indexes made by UNIQUE or PRIMARY KEY constraints have no SQL of their own.
            var definition: String?
            if case .text(let text)? = try await query(SQLStatement(
                "SELECT sql FROM \(dialect.quoteIdentifier(schema)).sqlite_master WHERE type = 'index' AND name = ?",
                bindings: [.text(name)])).first?.first {
                definition = text
            }
            var predicate: String?
            if row[3] == .integer(1), let text = definition,
               let r = text.range(of: " WHERE ", options: [.caseInsensitive, .backwards]) {
                predicate = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            indexes.append(IndexInfo(
                name: name,
                columns: columns.map { $0[1] == .integer(-2) ? "<expression>" : $0[0].displayString },
                isUnique: row[1] == .integer(1), isPrimary: row[2] == .text("pk"), predicate: predicate,
                isConstraint: row[2] != .text("c"), definition: definition))
        }
        return indexes
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let rows = try await query(SQLStatement(
            #"SELECT id, "table", "from", "to", on_update, on_delete FROM pragma_foreign_key_list(?, ?) ORDER BY id, seq"#,
            bindings: [.text(table.name), .text(table.schema ?? "main")]))
        var out: [(id: DBValue, key: ForeignKeyInfo)] = []
        for row in rows {
            // "to" is NULL when the key references the parent's primary key implicitly.
            let to = row[3].isNull ? "" : row[3].displayString
            if out.last?.id == row[0] {
                out[out.count - 1].key.columns.append(row[2].displayString)
                out[out.count - 1].key.referencedColumns.append(to)
            } else {
                out.append((row[0], ForeignKeyInfo(
                    name: "", columns: [row[2].displayString],
                    referencedTable: TableRef(schema: table.schema, row[1].displayString), referencedColumns: [to],
                    onUpdate: row[4].displayString, onDelete: row[5].displayString)))
            }
        }
        return out.map(\.key)
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        let rows = try await query(SQLStatement("""
            SELECT name, sql FROM \(dialect.quoteIdentifier(table.schema ?? "main")).sqlite_master
            WHERE type = 'trigger' AND tbl_name = ? ORDER BY name
            """, bindings: [.text(table.name)]))
        return rows.map { row in
            let sql = row[1].isNull ? "" : row[1].displayString
            let (timing, events) = Self.triggerHead(sql)
            return TriggerInfo(name: row[0].displayString, timing: timing, events: events, definition: sql)
        }
    }

    /// Timing and events from `CREATE TRIGGER [IF NOT EXISTS] name [BEFORE|AFTER|INSTEAD OF]
    /// {DELETE|INSERT|UPDATE [OF …]} ON …`.
    static func triggerHead(_ sql: String) -> (timing: String, events: [String]) {
        let lexer = SQLLexer(sql, dialect: .sqlite)
        let words = lexer.tokens().filter { !$0.kind.isTrivia }.map {
            String(decoding: lexer.units[$0.range], as: UTF16.self).uppercased()
        }
        guard var i = words.firstIndex(of: "TRIGGER") else { return ("AFTER", []) }
        i += 1
        if i < words.count, words[i] == "IF" { i += 3 }
        i += 1                                             // the name
        if i < words.count, words[i] == "." { i += 2 }     // schema.name
        let head = words[min(i, words.count)...].prefix { $0 != "ON" }
        let timing = head.contains("INSTEAD") ? "INSTEAD OF" : head.contains("BEFORE") ? "BEFORE" : "AFTER"
        return (timing, ["INSERT", "UPDATE", "DELETE"].filter(head.contains))
    }

    // MARK: - Helpers
}
