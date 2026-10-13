import Foundation

/// A single cell value as it travels between drivers, the grid and SQL builders.
public enum DBValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case bool(Bool)

    public var isNull: Bool { self == .null }

    /// How the grid shows the value.
    public var displayString: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .double(let v): String(v)
        case .text(let v): v
        case .blob(let d): "<\(d.count) bytes>"
        case .bool(let v): v ? "true" : "false"
        }
    }
}

public struct TableRef: Sendable, Hashable, CustomStringConvertible {
    public var schema: String?
    public var name: String

    public init(schema: String? = nil, _ name: String) {
        self.schema = schema
        self.name = name
    }

    public var description: String { schema.map { "\($0).\(name)" } ?? name }
}

public enum ObjectKind: String, Sendable, Hashable, CaseIterable {
    case table, view, materializedView, function, procedure, sequence

    public var isRoutine: Bool { self == .function || self == .procedure }
    /// Tables and views: what opens in a grid.
    public var isRelation: Bool { self == .table || self == .view || self == .materializedView }
}

public struct DatabaseObject: Sendable, Hashable {
    public var ref: TableRef
    public var kind: ObjectKind
    /// Postgres routines: the argument types that tell overloads apart (`a integer, b text`,
    /// `pg_get_function_identity_arguments`). Nil elsewhere.
    public var signature: String?

    public init(_ ref: TableRef, kind: ObjectKind, signature: String? = nil) {
        self.ref = ref
        self.kind = kind
        self.signature = signature
    }

    /// `f(integer)` for a routine with a signature, else the name.
    public var displayName: String {
        guard let signature else { return ref.name }
        return "\(ref.name)(\(signature))"
    }
}

/// A column as declared in the table's structure.
public struct ColumnInfo: Sendable, Hashable {
    public var name: String
    public var typeName: String
    public var isNullable: Bool
    /// The default as SQL (`'draft'`, `0`, `now()`), nil when there is none.
    public var defaultExpression: String?
    /// 1-based position within the primary key, nil if not part of it.
    public var primaryKeyPosition: Int?
    /// Nil where the database has no column comments (SQLite) or none is set.
    public var comment: String?
    /// MySQL `AUTO_INCREMENT`, a Postgres identity column, SQLite `AUTOINCREMENT`.
    public var isAutoIncrement: Bool
    /// How a generated or identity column is computed, as SQL (`GENERATED ALWAYS AS (a + b) STORED`).
    /// The structure editor shows it but doesn't change it.
    public var generated: String?
    /// MySQL: the column's collation, restated when the column is redefined so it isn't reset.
    public var collation: String?
    /// MySQL: `ON UPDATE CURRENT_TIMESTAMP`, restated like the collation.
    public var onUpdate: String?

    public init(
        name: String, typeName: String, isNullable: Bool = true,
        defaultExpression: String? = nil, primaryKeyPosition: Int? = nil,
        comment: String? = nil, isAutoIncrement: Bool = false, generated: String? = nil,
        collation: String? = nil, onUpdate: String? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.primaryKeyPosition = primaryKeyPosition
        self.comment = comment
        self.isAutoIncrement = isAutoIncrement
        self.generated = generated
        self.collation = collation
        self.onUpdate = onUpdate
    }
}

extension Array where Element == ColumnInfo {
    /// Primary-key column names in key order.
    public var primaryKey: [String] {
        filter { $0.primaryKeyPosition != nil }
            .sorted { $0.primaryKeyPosition! < $1.primaryKeyPosition! }
            .map(\.name)
    }
}

public struct IndexInfo: Sendable, Hashable {
    public var name: String
    /// Key columns in order. An expression index shows its expression.
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    /// Access method (`btree`, `hash`, `BTREE`, …) when the database reports one.
    public var method: String?
    /// The WHERE clause of a partial index.
    public var predicate: String?
    /// The index belongs to a constraint (PRIMARY KEY, UNIQUE, EXCLUDE) and goes away with it,
    /// not with DROP INDEX. Postgres and SQLite.
    public var isConstraint: Bool
    /// The `CREATE INDEX` statement, where the database keeps one (SQLite, Postgres). A SQLite
    /// rebuild runs it again.
    public var definition: String?

    public init(
        name: String, columns: [String], isUnique: Bool = false, isPrimary: Bool = false,
        method: String? = nil, predicate: String? = nil, isConstraint: Bool = false, definition: String? = nil
    ) {
        self.definition = definition
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.predicate = predicate
        self.isConstraint = isConstraint || isPrimary
    }
}

public struct ForeignKeyInfo: Sendable, Hashable {
    /// Empty when the database doesn't name it (SQLite).
    public var name: String
    public var columns: [String]
    public var referencedTable: TableRef
    public var referencedColumns: [String]
    /// Referential actions as SQL words: `NO ACTION`, `CASCADE`, `SET NULL`, …
    public var onUpdate: String
    public var onDelete: String

    public init(
        name: String, columns: [String], referencedTable: TableRef, referencedColumns: [String],
        onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION"
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct TriggerInfo: Sendable, Hashable {
    public var name: String
    /// `BEFORE`, `AFTER` or `INSTEAD OF`.
    public var timing: String
    /// `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`.
    public var events: [String]
    /// The whole `CREATE TRIGGER` statement, without a final `;`.
    public var definition: String

    public init(name: String, timing: String, events: [String], definition: String) {
        self.name = name
        self.timing = timing
        self.events = events
        self.definition = definition
    }
}

/// A column of a result set (may not map to a table column).
public struct ResultColumn: Sendable, Hashable {
    public var name: String
    public var typeName: String?

    public init(name: String, typeName: String? = nil) {
        self.name = name
        self.typeName = typeName
    }
}

/// A chunk of rows streamed from a running statement.
public struct ResultBatch: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[DBValue]]
    /// Set on the last batch of a statement that changes rows.
    public var rowsAffected: Int?

    public init(columns: [ResultColumn], rows: [[DBValue]], rowsAffected: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
    }
}

/// A fully collected result.
public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[DBValue]]
    public var rowsAffected: Int?

    public init(columns: [ResultColumn] = [], rows: [[DBValue]] = [], rowsAffected: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
    }
}

public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var code: Int?
    /// SQLSTATE, when the server reports one (Postgres, MySQL).
    public var state: String?
    /// The statement that failed, when known.
    public var sql: String?

    public init(_ message: String, code: Int? = nil, state: String? = nil, sql: String? = nil) {
        self.message = message
        self.code = code
        self.state = state
        self.sql = sql
    }

    public var description: String { message }
}
