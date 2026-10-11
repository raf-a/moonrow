import DBKit
import Foundation

/// The structure editor's staged changes to one table (or a table being created).
///
/// Rows stay where they are while edited: a deleted column or index is only marked, so the
/// grid can strike it out until the change is committed or discarded. `design` is what's left,
/// and `plan(for:)` the DDL that gets there. Renaming or deleting a column follows into the
/// primary key, the indexes and the foreign keys.
public struct StructureEditor: Sendable {
    public struct Row<Value: Sendable & Hashable>: Sendable, Hashable {
        /// Position in the loaded structure's list; nil for a row added here.
        public var origin: Int?
        public var value: Value
        public var isDeleted = false

        public var isNew: Bool { origin == nil }
    }

    public enum ColumnField: Sendable, Hashable {
        case name, type, nullable, defaultValue, comment, autoIncrement, foreignKey
    }

    public enum IndexField: Sendable, Hashable {
        case name, columns, unique, method, predicate
    }

    public private(set) var original: TableStructure
    /// False while creating a table that doesn't exist yet.
    public let exists: Bool
    public var name: String
    public var comment: String
    public private(set) var columns: [Row<ColumnInfo>]
    public private(set) var indexes: [Row<IndexInfo>]
    public private(set) var foreignKeys: [Row<ForeignKeyInfo>]
    public private(set) var primaryKey: [String]

    /// `exists: false` for a table that is being created.
    public init(_ structure: TableStructure, exists: Bool = true) {
        original = structure
        self.exists = exists
        name = structure.table.name
        comment = structure.comment ?? ""
        columns = structure.columns.enumerated().map { i, c in
            var c = c
            c.primaryKeyPosition = nil
            return Row(origin: i, value: c)
        }
        indexes = structure.indexes.enumerated().filter { !$0.element.isPrimary }.map { Row(origin: $0.offset, value: $0.element) }
        foreignKeys = structure.foreignKeys.enumerated().map { Row(origin: $0.offset, value: $0.element) }
        primaryKey = structure.primaryKey
    }

    /// A new table with an auto-increment `id` key, as most new tables start.
    public static func newTable(_ table: TableRef, dialect: any Dialect) -> StructureEditor {
        var e = StructureEditor(TableStructure(table: table, columns: []), exists: false)
        let idType = dialect is SQLiteDialect ? "INTEGER" : dialect is MySQLDialect ? "int" : "integer"
        e.columns = [Row(origin: nil, value: ColumnInfo(name: "id", typeName: idType, isNullable: false, isAutoIncrement: true))]
        e.primaryKey = ["id"]
        return e
    }

    // MARK: - What changed

    public var design: TableDesign {
        TableDesign(
            name: name,
            columns: columns.filter { !$0.isDeleted }.map { Designed(origin: $0.origin, $0.value) },
            primaryKey: primaryKey,
            indexes: indexes.filter { !$0.isDeleted }.map { Designed(origin: $0.origin, $0.value) },
            foreignKeys: foreignKeys.filter { !$0.isDeleted }.map { Designed(origin: $0.origin, $0.value) },
            comment: comment)
    }

    public var change: StructureChange { StructureChange(from: original, to: design) }

    public var hasChanges: Bool { !exists || !change.isEmpty }

    /// What differs from the loaded column, for highlighting. Empty for new and deleted rows.
    public func changedFields(ofColumn row: Int) -> Set<ColumnField> {
        let r = columns[row]
        guard let o = r.origin, !r.isDeleted else { return [] }
        let old = original.columns[o]
        let new = r.value
        var out: Set<ColumnField> = []
        if old.name != new.name { out.insert(.name) }
        if old.typeName != new.typeName { out.insert(.type) }
        if old.isNullable != new.isNullable { out.insert(.nullable) }
        if old.defaultExpression != new.defaultExpression { out.insert(.defaultValue) }
        if (old.comment ?? "") != (new.comment ?? "") { out.insert(.comment) }
        if old.isAutoIncrement != new.isAutoIncrement { out.insert(.autoIncrement) }
        let change = self.change
        let changedKeys = Set(change.droppedForeignKeys.flatMap(\.columns).map(change.renamed) + change.addedForeignKeys.flatMap(\.columns))
        if changedKeys.contains(new.name) { out.insert(.foreignKey) }
        return out
    }

    public func changedFields(ofIndex row: Int) -> Set<IndexField> {
        let r = indexes[row]
        guard let o = r.origin, !r.isDeleted else { return [] }
        let old = original.indexes[o]
        let renamedColumns = old.columns.map(change.renamed)
        var out: Set<IndexField> = []
        if old.name != r.value.name { out.insert(.name) }
        if renamedColumns != r.value.columns { out.insert(.columns) }
        if old.isUnique != r.value.isUnique { out.insert(.unique) }
        if (old.method ?? "") != (r.value.method ?? "") { out.insert(.method) }
        if (old.predicate ?? "") != (r.value.predicate ?? "") { out.insert(.predicate) }
        return out
    }

    public var primaryKeyChanged: Bool { exists && change.primaryKeyChanged }

    /// Why the design can't be applied, or nil.
    public func problem(for dialect: any Dialect) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The table needs a name." }
        let live = columns.filter { !$0.isDeleted }.map(\.value)
        if live.isEmpty { return "A table needs at least one column." }
        var seen = Set<String>()
        for c in live {
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Every column needs a name." }
            // SQLite is the one that takes columns without a type.
            if c.typeName.trimmingCharacters(in: .whitespaces).isEmpty, !(dialect is SQLiteDialect) {
                return "Column \(c.name) needs a type."
            }
            if !seen.insert(c.name.lowercased()).inserted { return "There are two columns named \(c.name)." }
        }
        for i in indexes where !i.isDeleted {
            if i.value.columns.isEmpty { return "Index \(i.value.name.isEmpty ? "(unnamed)" : i.value.name) has no columns." }
        }
        for k in foreignKeys where !k.isDeleted {
            if k.value.referencedTable.name.isEmpty { return "A foreign key has no referenced table." }
            if k.value.columns.count != k.value.referencedColumns.count {
                return "A foreign key needs as many referenced columns as columns."
            }
        }
        return nil
    }

    /// The DDL for the staged changes.
    public func plan(for dialect: any Dialect) throws -> DDLPlan {
        if let problem = problem(for: dialect) { throw DatabaseError(problem) }
        return exists ? try dialect.alterTable(change) : dialect.createTable(design, schema: original.table.schema)
    }

    // MARK: - Columns

    /// The default type for a new column.
    public static func newColumnType(_ dialect: any Dialect) -> String {
        dialect is SQLiteDialect ? "TEXT" : dialect is MySQLDialect ? "varchar(255)" : "text"
    }

    /// Adds a nullable column named `column`, `column_2`, … and returns its row.
    @discardableResult
    public mutating func addColumn(type: String, after row: Int? = nil) -> Int {
        let taken = Set(columns.map { $0.value.name.lowercased() })
        var n = 1
        var candidate = "column"
        while taken.contains(candidate) {
            n += 1
            candidate = "column_\(n)"
        }
        let at = row.map { $0 + 1 } ?? columns.count
        columns.insert(Row(origin: nil, value: ColumnInfo(name: candidate, typeName: type)), at: at)
        return at
    }

    /// A copy of the column under a new name, without key or identity.
    @discardableResult
    public mutating func duplicateColumn(_ row: Int) -> Int {
        let source = columns[row].value
        let at = addColumn(type: source.typeName, after: row)
        let name = columns[at].value.name
        columns[at].value = source
        columns[at].value.name = name
        columns[at].value.isAutoIncrement = false
        columns[at].value.generated = nil
        return at
    }

    public mutating func setColumn(_ row: Int, _ edit: (inout ColumnInfo) -> Void) {
        let oldName = columns[row].value.name
        edit(&columns[row].value)
        let newName = columns[row].value.name
        guard oldName != newName else { return }
        func follow(_ names: [String]) -> [String] { names.map { $0 == oldName ? newName : $0 } }
        primaryKey = follow(primaryKey)
        for i in indexes.indices { indexes[i].value.columns = follow(indexes[i].value.columns) }
        for i in foreignKeys.indices {
            foreignKeys[i].value.columns = follow(foreignKeys[i].value.columns)
            if foreignKeys[i].value.referencedTable.name == name, foreignKeys[i].value.referencedTable.schema == original.table.schema {
                foreignKeys[i].value.referencedColumns = follow(foreignKeys[i].value.referencedColumns)
            }
        }
    }

    /// New rows go away; loaded ones are marked, and leave the key, indexes and foreign keys.
    public mutating func deleteColumns(_ rows: IndexSet) {
        let names = Set(rows.map { columns[$0].value.name })
        for row in rows.reversed() {
            if columns[row].isNew { columns.remove(at: row) } else { columns[row].isDeleted = true }
        }
        primaryKey.removeAll { names.contains($0) }
        for i in indexes.indices {
            indexes[i].value.columns.removeAll { names.contains($0) }
        }
        deleteIndexes(IndexSet(indexes.indices.filter { indexes[$0].value.columns.isEmpty && !indexes[$0].isDeleted }))
        deleteForeignKeys(IndexSet(foreignKeys.indices.filter { i in
            !foreignKeys[i].isDeleted && foreignKeys[i].value.columns.contains(where: names.contains)
        }))
    }

    /// Takes back a delete mark.
    public mutating func restoreColumn(_ row: Int) {
        columns[row].isDeleted = false
    }

    public mutating func setPrimaryKey(_ names: [String]) {
        let live = Set(columns.filter { !$0.isDeleted }.map(\.value.name))
        var seen = Set<String>()
        primaryKey = names.filter { live.contains($0) && seen.insert($0).inserted }
        // Key columns can't hold NULL.
        for i in columns.indices where primaryKey.contains(columns[i].value.name) { columns[i].value.isNullable = false }
    }

    public mutating func togglePrimaryKey(_ row: Int) {
        let name = columns[row].value.name
        setPrimaryKey(primaryKey.contains(name) ? primaryKey.filter { $0 != name } : primaryKey + [name])
    }

    // MARK: - Indexes

    @discardableResult
    public mutating func addIndex(columns names: [String], unique: Bool = false) -> Int {
        indexes.append(Row(origin: nil, value: IndexInfo(name: "", columns: names, isUnique: unique)))
        return indexes.count - 1
    }

    public mutating func setIndex(_ row: Int, _ edit: (inout IndexInfo) -> Void) {
        edit(&indexes[row].value)
        // What the database stored describes the old index.
        indexes[row].value.definition = nil
    }

    public mutating func deleteIndexes(_ rows: IndexSet) {
        for row in rows.reversed() {
            if indexes[row].isNew { indexes.remove(at: row) } else { indexes[row].isDeleted = true }
        }
    }

    public mutating func restoreIndex(_ row: Int) {
        indexes[row].isDeleted = false
    }

    // MARK: - Foreign keys

    /// The live foreign key that starts at this column, if any.
    public func foreignKey(forColumn name: String) -> Int? {
        foreignKeys.indices.first { !foreignKeys[$0].isDeleted && foreignKeys[$0].value.columns.first == name }
            ?? foreignKeys.indices.first { !foreignKeys[$0].isDeleted && foreignKeys[$0].value.columns.contains(name) }
    }

    /// Replaces the key at `row` (nil adds one).
    public mutating func setForeignKey(_ row: Int?, _ key: ForeignKeyInfo) {
        if let row {
            foreignKeys[row].value = key
        } else {
            foreignKeys.append(Row(origin: nil, value: key))
        }
    }

    public mutating func deleteForeignKeys(_ rows: IndexSet) {
        for row in rows.reversed() {
            if foreignKeys[row].isNew { foreignKeys.remove(at: row) } else { foreignKeys[row].isDeleted = true }
        }
    }
}

/// Turns what's typed into a structure grid's Default cell into SQL.
///
/// Numbers, quoted strings, NULL, TRUE/FALSE, the CURRENT_… keywords, function calls and
/// anything in parentheses or with `::` are SQL already. Any other text is a string and gets
/// quoted. Empty means no default.
public enum DefaultInput {
    public static func sql(from text: String, dialect: any Dialect) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if Double(t) != nil { return t }
        let upper = t.uppercased()
        let keywords: Set = ["NULL", "TRUE", "FALSE", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
                             "LOCALTIMESTAMP", "LOCALTIME", "CURRENT_USER"]
        if keywords.contains(upper) { return t }
        if t.hasPrefix("'") || t.hasPrefix("(") || t.contains("::") || t.hasPrefix("b'") || t.hasPrefix("X'") { return t }
        // name(…): a function call such as now() or gen_random_uuid().
        if let open = t.firstIndex(of: "("), t.hasSuffix(")"),
           t[..<open].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }), open != t.startIndex {
            return t
        }
        return dialect.literal(.text(t))
    }
}
