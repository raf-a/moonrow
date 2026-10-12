import DBKit

/// A staged cell value.
public enum CellChange: Sendable, Hashable {
    case value(DBValue)
    /// The column's default: left out of an INSERT, `DEFAULT` (or the declared default) in an UPDATE.
    case defaultValue
}

/// One table's staged row edits, kept until the workspace commits or discards them.
///
/// Loaded rows are known by their key: the primary-key values, or every value when the table
/// has none. The grid looks rows up by key as they load, so edits outlive paging, sorting,
/// filtering, reloads and closing the tab. Identical rows of a
/// keyless table share one key; the commit refuses a statement that hits more than one row.
/// New rows aren't on any page; the grid shows them after the page it shows.
public struct TableEdits: Sendable, Equatable {
    public enum RowState: Sendable, Hashable {
        case unchanged, edited, inserted, deleted
    }

    public typealias RowKey = [DBValue]

    private struct Loaded: Sendable, Equatable {
        /// The row as it was loaded: it locates the row on commit.
        var original: [DBValue]
        var cells: [Int: CellChange] = [:]
        var deleted = false
        var isEmpty: Bool { cells.isEmpty && !deleted }
    }

    public let table: TableRef
    public private(set) var columns: [ColumnInfo]
    private var keyColumns: [Int]
    private var loaded: [RowKey: Loaded] = [:]
    /// Keys in the order they were first staged, so statements come out in that order.
    private var order: [RowKey] = []
    /// New rows; a column without an entry gets its default.
    public private(set) var inserts: [[Int: CellChange]] = []

    public init(table: TableRef, columns: [ColumnInfo]) {
        self.table = table
        self.columns = columns
        keyColumns = Self.keyColumns(columns)
    }

    private static func keyColumns(_ columns: [ColumnInfo]) -> [Int] {
        let pk = columns.primaryKey
        return pk.isEmpty ? Array(columns.indices) : pk.compactMap { name in columns.firstIndex { $0.name == name } }
    }

    public var isEmpty: Bool { loaded.isEmpty && inserts.isEmpty }
    public var hasPrimaryKey: Bool { !columns.primaryKey.isEmpty }
    public var updatedRowCount: Int { loaded.values.filter { !$0.deleted && !$0.cells.isEmpty }.count }
    public var deletedRowCount: Int { loaded.values.filter(\.deleted).count }
    public var insertedRowCount: Int { inserts.count }

    /// "2 edited, 1 new, 1 deleted"; empty when nothing is staged.
    public var summary: String {
        [(updatedRowCount, "edited"), (insertedRowCount, "new"), (deletedRowCount, "deleted")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    public func key(of row: [DBValue]) -> RowKey {
        keyColumns.map { $0 < row.count ? row[$0] : .null }
    }

    /// The state of a loaded row; nil (not loaded yet) is unchanged.
    public func state(of row: [DBValue]?) -> RowState {
        guard let row, let entry = loaded[key(of: row)] else { return .unchanged }
        return entry.deleted ? .deleted : .edited
    }

    public func change(in row: [DBValue]?, column: Int) -> CellChange? {
        guard let row else { return nil }
        return loaded[key(of: row)]?.cells[column]
    }

    /// Stages a cell of a loaded row. Setting a cell back to its loaded value unstages it.
    public mutating func set(_ change: CellChange, column: Int, in row: [DBValue]) {
        let k = key(of: row)
        var entry = loaded[k] ?? Loaded(original: row)
        guard !entry.deleted else { return }
        if case .value(let v) = change, column < entry.original.count, entry.original[column] == v {
            entry.cells[column] = nil
        } else {
            entry.cells[column] = change
        }
        store(entry, at: k)
    }

    /// Marks a loaded row for deletion. Its cell edits are kept in case it's restored, but not sent.
    public mutating func delete(_ row: [DBValue]) {
        let k = key(of: row)
        var entry = loaded[k] ?? Loaded(original: row)
        entry.deleted = true
        store(entry, at: k)
    }

    private mutating func store(_ entry: Loaded, at k: RowKey) {
        if entry.isEmpty {
            loaded[k] = nil
            order.removeAll { $0 == k }
        } else {
            if loaded[k] == nil { order.append(k) }
            loaded[k] = entry
        }
    }

    // MARK: New rows

    /// Appends a new row and returns its index in `inserts`.
    @discardableResult
    public mutating func addRow(_ values: [Int: CellChange] = [:]) -> Int {
        inserts.append(values)
        return inserts.count - 1
    }

    public mutating func setInserted(_ change: CellChange, row: Int, column: Int) {
        guard inserts.indices.contains(row) else { return }
        inserts[row][column] = change
    }

    public mutating func removeInserted(_ rows: some Sequence<Int>) {
        for i in Set(rows).sorted(by: >) where inserts.indices.contains(i) { inserts.remove(at: i) }
    }

    // MARK: Columns

    /// Follows the table's columns after a reload: edits move with their column's name, and
    /// edits to columns that are gone are dropped. Rows are keyed again by the new key.
    public mutating func rebase(columns new: [ColumnInfo]) {
        guard new.map(\.name) != columns.map(\.name) || new.primaryKey != columns.primaryKey else {
            columns = new
            return
        }
        let position = Dictionary(columns.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        let map: [Int?] = new.map { position[$0.name] }  // new index → old index
        func remap(_ cells: [Int: CellChange]) -> [Int: CellChange] {
            var out: [Int: CellChange] = [:]
            for (newIndex, old) in map.enumerated() { if let old, let c = cells[old] { out[newIndex] = c } }
            return out
        }
        let oldOrder = order
        let oldLoaded = loaded
        columns = new
        keyColumns = Self.keyColumns(new)
        loaded = [:]
        order = []
        for k in oldOrder {
            guard var entry = oldLoaded[k] else { continue }
            entry.original = map.map { $0.map { entry.original[$0] } ?? .null }
            entry.cells = remap(entry.cells)
            store(entry, at: key(of: entry.original))
        }
        inserts = inserts.map(remap)
    }

    // MARK: SQL

    /// The change set for these edits. Rows are located by their primary key, or by every column
    /// when the table has none (`DatabaseConnection.commit` then refuses to touch duplicates).
    public func changeSet(dialect: any Dialect) -> ChangeSet {
        func key(_ entry: Loaded) -> [ColumnValue] {
            keyColumns.filter { $0 < entry.original.count }.map { ColumnValue(columns[$0].name, entry.original[$0]) }
        }
        func assignments(_ cells: [Int: CellChange], forInsert: Bool) -> [ColumnValue] {
            cells.sorted { $0.key < $1.key }.compactMap { column, change in
                guard column < columns.count else { return nil }
                // Computed columns and ALWAYS identities can't be written (a duplicated row carries them).
                if forInsert, columns[column].generated?.hasPrefix("GENERATED ALWAYS") == true { return nil }
                switch change {
                case .value(let v): return ColumnValue(columns[column].name, v)
                case .defaultValue:
                    return forInsert ? nil : .expression(columns[column].name, dialect.defaultValue(for: columns[column]))
                }
            }
        }
        let entries = order.compactMap { loaded[$0] }
        return ChangeSet(
            table,
            updates: entries.filter { !$0.deleted && !$0.cells.isEmpty }.map {
                RowUpdate(key: key($0), changes: assignments($0.cells, forInsert: false))
            },
            inserts: inserts.map { assignments($0, forInsert: true) },
            deletes: entries.filter(\.deleted).map(key))
    }
}

/// Turns what the user typed into a cell into a value, guided by the column's declared type.
/// Text that doesn't parse as the column's type stays text, so the database reports the problem.
public enum CellInput {
    public static func parse(_ text: String, typeName: String) -> DBValue {
        let type = typeName.uppercased()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // SQLite's affinity rule (any type containing INT), minus Postgres's INTERVAL and POINT.
        if type.contains("INT"), !type.contains("INTERVAL"), !type.contains("POINT"), let n = Int64(trimmed) {
            return .integer(n)
        }
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
