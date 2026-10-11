public struct ColumnValue: Sendable, Hashable {
    public var column: String
    public var value: DBValue
    /// SQL written in place of `value`, such as `DEFAULT`. Comes from the dialect or the
    /// table's structure, never from what the user typed. Not allowed in keys.
    public var expression: String?

    public init(_ column: String, _ value: DBValue) {
        self.column = column
        self.value = value
    }

    public static func expression(_ column: String, _ sql: String) -> ColumnValue {
        var c = ColumnValue(column, .null)
        c.expression = sql
        return c
    }

    var fragment: SQLFragment { expression.map { SQLFragment($0) } ?? .value(value) }
}

/// An edited row: how to find it, and what changed.
public struct RowUpdate: Sendable, Hashable {
    /// Identifies the row: primary-key columns with their *original* values. For a table
    /// without a key the caller has to pass every original column (and should warn the
    /// user, since duplicate rows would all match).
    public var key: [ColumnValue]
    public var changes: [ColumnValue]

    public init(key: [ColumnValue], changes: [ColumnValue]) {
        self.key = key
        self.changes = changes
    }
}

/// Grid edits waiting to be committed. Nothing touches the database until `commit`.
public struct ChangeSet: Sendable, Hashable {
    public var table: TableRef
    public var updates: [RowUpdate]
    public var inserts: [[ColumnValue]]
    /// Keys of rows to delete (same rules as `RowUpdate.key`).
    public var deletes: [[ColumnValue]]

    public init(
        _ table: TableRef, updates: [RowUpdate] = [], inserts: [[ColumnValue]] = [],
        deletes: [[ColumnValue]] = []
    ) {
        self.table = table
        self.updates = updates
        self.inserts = inserts
        self.deletes = deletes
    }

    public var isEmpty: Bool { updates.isEmpty && inserts.isEmpty && deletes.isEmpty }
}

extension Dialect {
    /// Statements for a change set, in commit order: deletes, then updates, then inserts,
    /// so freed unique values can be reused. Run them in one transaction.
    public func statements(for changes: ChangeSet) -> [SQLFragment] {
        changes.deletes.map { delete(from: changes.table, key: $0) }
            + changes.updates.filter { !$0.changes.isEmpty }.map { update(changes.table, $0) }
            + changes.inserts.map { insert(into: changes.table, $0) }
    }

    public func insert(into table: TableRef, _ values: [ColumnValue]) -> SQLFragment {
        guard !values.isEmpty else { return SQLFragment(insertDefaultValues(into: qualified(table))) }
        let columns = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let placeholders = values.map(\.fragment).joined(separator: ", ")
        return "INSERT INTO \(qualified(table)) (\(columns)) VALUES (" + placeholders + ")"
    }

    public func update(_ table: TableRef, _ row: RowUpdate) -> SQLFragment {
        let assignments = row.changes
            .map { "\(quoteIdentifier($0.column)) = " + $0.fragment }
            .joined(separator: ", ")
        return "UPDATE \(qualified(table)) SET " + assignments + " WHERE " + keyPredicate(row.key)
    }

    public func delete(from table: TableRef, key: [ColumnValue]) -> SQLFragment {
        "DELETE FROM \(qualified(table)) WHERE " + keyPredicate(key)
    }

    public func keyPredicate(_ key: [ColumnValue]) -> SQLFragment {
        precondition(!key.isEmpty, "refusing to build an unrestricted UPDATE/DELETE")
        precondition(key.allSatisfy { $0.expression == nil }, "keys are values, not expressions")
        return key.map { kv -> SQLFragment in
            let column = quoteIdentifier(kv.column)
            return kv.value.isNull ? SQLFragment("\(column) IS NULL") : "\(column) = " + .value(kv.value)
        }.joined(separator: " AND ")
    }
}
