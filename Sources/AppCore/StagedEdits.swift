import DBKit

/// A staged cell value.
public enum CellChange: Sendable, Hashable {
    case value(DBValue)
    /// The column's default: left out of an INSERT, `DEFAULT` (or the declared default) in an UPDATE.
    case defaultValue
}

/// Grid edits waiting for commit, laid over the rows the grid shows.
///
/// Rows are addressed by their index in the grid: `0..<baseRowCount` are the rows loaded from
/// the database, inserted rows follow. The grid must not reload, page, sort or filter while
/// edits are staged, or the indexes would point at other rows; the table view asks the user to
/// commit or discard first.
public struct StagedEdits: Sendable {
    public enum RowState: Sendable, Hashable {
        case unchanged, edited, inserted, deleted
    }

    public let baseRowCount: Int
    /// Row → column → change, for loaded rows.
    private var updates: [Int: [Int: CellChange]] = [:]
    /// Database values of loaded rows that have staged updates or deletes. They locate the row.
    private var originals: [Int: [DBValue]] = [:]
    public private(set) var deleted: Set<Int> = []
    /// New rows in grid order; a column without an entry gets its default.
    private var inserts: [[Int: CellChange]] = []

    public init(baseRowCount: Int) {
        self.baseRowCount = max(0, baseRowCount)
    }

    public var rowCount: Int { baseRowCount + inserts.count }
    public var isEmpty: Bool { updates.isEmpty && deleted.isEmpty && inserts.isEmpty }
    public var updatedRowCount: Int { updates.keys.filter { !deleted.contains($0) }.count }
    public var insertedRowCount: Int { inserts.count }

    public func isInserted(_ row: Int) -> Bool { row >= baseRowCount && row < rowCount }

    public func state(of row: Int) -> RowState {
        if isInserted(row) { return .inserted }
        if deleted.contains(row) { return .deleted }
        return updates[row] == nil ? .unchanged : .edited
    }

    /// The staged change for a cell, if any. Inserted rows report only the cells set on them.
    public func change(row: Int, column: Int) -> CellChange? {
        if isInserted(row) { return inserts[row - baseRowCount][column] }
        return updates[row]?[column]
    }

    /// Stages a cell. `original` is the row as loaded from the database (ignored for inserted
    /// rows). Setting a cell back to its loaded value unstages it.
    public mutating func set(_ change: CellChange, row: Int, column: Int, original: [DBValue]?) {
        if isInserted(row) {
            inserts[row - baseRowCount][column] = change
            return
        }
        guard row >= 0, row < baseRowCount, !deleted.contains(row), let original else { return }
        if case .value(let v) = change, column < original.count, original[column] == v {
            updates[row]?[column] = nil
            if updates[row]?.isEmpty == true { updates[row] = nil }
        } else {
            updates[row, default: [:]][column] = change
        }
        originals[row] = updates[row] == nil ? nil : originals[row] ?? original
    }

    /// Appends a new row and returns its grid index.
    @discardableResult
    public mutating func addRow(_ values: [Int: CellChange] = [:]) -> Int {
        inserts.append(values)
        return rowCount - 1
    }

    /// Inserted rows are dropped; loaded rows are marked for deletion. `original` gives the
    /// loaded values of a row.
    public mutating func delete(rows: some Sequence<Int>, original: (Int) -> [DBValue]?) {
        var droppedInserts: [Int] = []
        for row in rows {
            if isInserted(row) {
                droppedInserts.append(row - baseRowCount)
            } else if row >= 0, row < baseRowCount, let values = originals[row] ?? original(row) {
                deleted.insert(row)
                originals[row] = values
            }
        }
        for i in droppedInserts.sorted(by: >) { inserts.remove(at: i) }
    }

    public mutating func discard() {
        self = StagedEdits(baseRowCount: baseRowCount)
    }

    /// The change set for these edits. Rows are located by their primary key, or by every column
    /// when the table has none (`DatabaseConnection.commit` then refuses to touch duplicates).
    public func changeSet(for table: TableRef, columns: [ColumnInfo], dialect: any Dialect) -> ChangeSet {
        let pk = columns.primaryKey
        let keyColumns = pk.isEmpty
            ? Array(columns.indices)
            : pk.compactMap { name in columns.firstIndex { $0.name == name } }
        func key(_ row: Int) -> [ColumnValue] {
            let values = originals[row] ?? []
            return keyColumns.filter { $0 < values.count }.map { ColumnValue(columns[$0].name, values[$0]) }
        }
        func assignments(_ cells: [Int: CellChange], forInsert: Bool) -> [ColumnValue] {
            cells.sorted { $0.key < $1.key }.compactMap { column, change in
                guard column < columns.count else { return nil }
                switch change {
                case .value(let v): return ColumnValue(columns[column].name, v)
                case .defaultValue:
                    return forInsert ? nil : .expression(columns[column].name, dialect.defaultValue(for: columns[column]))
                }
            }
        }
        return ChangeSet(
            table,
            updates: updates.keys.sorted().filter { !deleted.contains($0) }.map {
                RowUpdate(key: key($0), changes: assignments(updates[$0]!, forInsert: false))
            },
            inserts: inserts.map { assignments($0, forInsert: true) },
            deletes: deleted.sorted().map(key))
    }
}

/// Turns what the user typed into a cell into a value, guided by the column's declared type.
/// Text that doesn't parse as the column's type stays text, so the database reports the problem.
public enum CellInput {
    public static func parse(_ text: String, typeName: String) -> DBValue {
        let type = typeName.uppercased()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if type.contains("INT"), let n = Int64(trimmed) { return .integer(n) }
        if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB"), let d = Double(trimmed) {
            return .double(d)
        }
        if type.hasPrefix("BOOL") {
            switch trimmed.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: break
            }
        }
        return .text(text)
    }

    /// The text an editor starts from: the full value, unlike the grid's one-line display.
    public static func editingText(_ value: DBValue) -> String {
        value.isNull ? "" : value.displayString
    }

    /// Blobs are shown as a byte count, so they can't be edited as text.
    public static func isEditableAsText(_ value: DBValue?) -> Bool {
        if case .blob = value { return false }
        return true
    }
}
