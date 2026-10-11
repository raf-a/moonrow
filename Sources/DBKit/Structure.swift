import Foundation

/// A table's structure as loaded from the database.
public struct TableStructure: Sendable, Hashable {
    public var table: TableRef
    public var columns: [ColumnInfo]
    /// Every index, the primary key's included.
    public var indexes: [IndexInfo]
    public var foreignKeys: [ForeignKeyInfo]
    public var triggers: [TriggerInfo]
    public var comment: String?
    /// SQLite: the table's `CREATE TABLE` text, which a rebuild starts from.
    public var definition: String?
    /// SQLite: whether `PRAGMA foreign_keys` is on, so a rebuild turns it off and back on.
    public var foreignKeysEnforced: Bool

    public init(
        table: TableRef, columns: [ColumnInfo], indexes: [IndexInfo] = [], foreignKeys: [ForeignKeyInfo] = [],
        triggers: [TriggerInfo] = [], comment: String? = nil, definition: String? = nil,
        foreignKeysEnforced: Bool = false
    ) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.triggers = triggers
        self.comment = comment
        self.definition = definition
        self.foreignKeysEnforced = foreignKeysEnforced
    }

    public var primaryKey: [String] { columns.primaryKey }

    /// The primary key's own index, when the database lists one.
    public var primaryIndex: IndexInfo? { indexes.first { $0.isPrimary } }
}

/// An element of a design, remembering which loaded element it started as.
public struct Designed<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Position in the loaded structure's list; nil for something added in the editor.
    public var origin: Int?
    public var value: Value

    public init(origin: Int?, _ value: Value) {
        self.origin = origin
        self.value = value
    }
}

/// The structure as the user is editing it. Comparing it with the loaded `TableStructure`
/// gives the DDL to run (`StructureChange`).
public struct TableDesign: Sendable, Hashable {
    public var name: String
    public var columns: [Designed<ColumnInfo>]
    /// Column names, in key order. Kept here rather than in `ColumnInfo.primaryKeyPosition`.
    public var primaryKey: [String]
    /// Indexes other than the primary key's.
    public var indexes: [Designed<IndexInfo>]
    public var foreignKeys: [Designed<ForeignKeyInfo>]
    public var comment: String

    public init(
        name: String, columns: [Designed<ColumnInfo>] = [], primaryKey: [String] = [],
        indexes: [Designed<IndexInfo>] = [], foreignKeys: [Designed<ForeignKeyInfo>] = [], comment: String = ""
    ) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.comment = comment
    }

    /// The loaded structure, unchanged.
    public init(_ s: TableStructure) {
        name = s.table.name
        columns = s.columns.enumerated().map { i, c in
            var c = c
            c.primaryKeyPosition = nil
            return Designed(origin: i, c)
        }
        primaryKey = s.primaryKey
        indexes = s.indexes.enumerated().filter { !$0.element.isPrimary }.map { Designed(origin: $0.offset, $0.element) }
        foreignKeys = s.foreignKeys.enumerated().map { Designed(origin: $0.offset, $0.element) }
        comment = s.comment ?? ""
    }

    /// Columns with `primaryKeyPosition` filled in from `primaryKey`.
    public var resolvedColumns: [ColumnInfo] {
        columns.map { d in
            var c = d.value
            c.primaryKeyPosition = primaryKey.firstIndex(of: c.name).map { $0 + 1 }
            return c
        }
    }
}

/// What turns a loaded structure into a design, element by element. Dialects render it as DDL.
public struct StructureChange: Sendable, Hashable {
    public struct Alteration: Sendable, Hashable {
        public var old: ColumnInfo
        /// Carries the new name too; `old.name` is the name before any rename.
        public var new: ColumnInfo

        public var renamed: Bool { old.name != new.name }
        public var typeChanged: Bool { old.typeName != new.typeName }
        public var nullabilityChanged: Bool { old.isNullable != new.isNullable }
        public var defaultChanged: Bool { old.defaultExpression != new.defaultExpression }
        public var commentChanged: Bool { (old.comment ?? "") != (new.comment ?? "") }
        public var autoIncrementChanged: Bool { old.isAutoIncrement != new.isAutoIncrement }
        /// Anything besides the name.
        public var definitionChanged: Bool {
            typeChanged || nullabilityChanged || defaultChanged || commentChanged || autoIncrementChanged
        }
    }

    public var original: TableStructure
    public var design: TableDesign

    /// Columns in the design that existed before, whether or not they changed, in design order.
    public var keptColumns: [Alteration] = []
    public var droppedColumns: [ColumnInfo] = []
    public var addedColumns: [ColumnInfo] = []
    public var oldPrimaryKey: [String]
    public var newPrimaryKey: [String]
    /// Indexes are never altered in place: a changed one is dropped and created again.
    public var droppedIndexes: [IndexInfo] = []
    public var createdIndexes: [IndexInfo] = []
    public var droppedForeignKeys: [ForeignKeyInfo] = []
    public var addedForeignKeys: [ForeignKeyInfo] = []
    /// Old name → new name, for every renamed column.
    public var renames: [String: String] = [:]

    public init(from original: TableStructure, to design: TableDesign) {
        self.original = original
        self.design = design
        oldPrimaryKey = original.primaryKey
        newPrimaryKey = design.primaryKey

        let kept = Set(design.columns.compactMap(\.origin))
        droppedColumns = original.columns.enumerated().filter { !kept.contains($0.offset) }.map(\.element)
        for d in design.columns {
            if let o = d.origin {
                var old = original.columns[o]
                old.primaryKeyPosition = nil
                keptColumns.append(Alteration(old: old, new: d.value))
                if old.name != d.value.name { renames[old.name] = d.value.name }
            } else {
                addedColumns.append(d.value)
            }
        }

        // Compare what was loaded, with renamed columns under their new names, against the design:
        // renaming a column alone mustn't rebuild the indexes and keys that mention it.
        let keptIndexes = Dictionary(design.indexes.compactMap { d in d.origin.map { ($0, d.value) } }) { a, _ in a }
        for (i, index) in original.indexes.enumerated() where !index.isPrimary {
            if let now = keptIndexes[i], Self.comparable(now) == renamed(index) { continue }
            droppedIndexes.append(index)
        }
        createdIndexes = design.indexes.filter { d in
            guard let o = d.origin else { return true }
            return Self.comparable(d.value) != renamed(original.indexes[o])
        }.map(\.value)

        let keptKeys = Dictionary(design.foreignKeys.compactMap { d in d.origin.map { ($0, d.value) } }) { a, _ in a }
        for (i, key) in original.foreignKeys.enumerated() {
            if let now = keptKeys[i], now == renamed(key) { continue }
            droppedForeignKeys.append(key)
        }
        addedForeignKeys = design.foreignKeys.filter { d in
            guard let o = d.origin else { return true }
            return d.value != renamed(original.foreignKeys[o])
        }.map(\.value)
    }

    public var renamedTable: String? { design.name != original.table.name ? design.name : nil }
    public var primaryKeyChanged: Bool { oldPrimaryKey.map(renamed) != newPrimaryKey }
    public var alteredColumns: [Alteration] { keptColumns.filter { $0.renamed || $0.definitionChanged } }
    public var commentChanged: Bool { (original.comment ?? "") != design.comment }

    public var isEmpty: Bool {
        renamedTable == nil && droppedColumns.isEmpty && addedColumns.isEmpty && alteredColumns.isEmpty
            && !primaryKeyChanged && droppedIndexes.isEmpty && createdIndexes.isEmpty
            && droppedForeignKeys.isEmpty && addedForeignKeys.isEmpty && !commentChanged
    }

    /// A column's name after this change's renames.
    public func renamed(_ column: String) -> String { renames[column] ?? column }

    func renamed(_ index: IndexInfo) -> IndexInfo {
        var i = Self.comparable(index)
        i.columns = i.columns.map(renamed)
        return i
    }

    /// The stored definition is a by-product of the other fields; edits don't keep it current.
    static func comparable(_ index: IndexInfo) -> IndexInfo {
        var i = index
        i.definition = nil
        return i
    }

    func renamed(_ key: ForeignKeyInfo) -> ForeignKeyInfo {
        var k = key
        k.columns = k.columns.map(renamed)
        // A key on the table itself refers to its own (renamed) columns.
        if k.referencedTable.name == original.table.name { k.referencedColumns = k.referencedColumns.map(renamed) }
        return k
    }
}

/// DDL ready to run, plus what the preview says about it.
public struct DDLPlan: Sendable, Hashable {
    /// Run first, outside the transaction (`PRAGMA foreign_keys = OFF` can't change inside one).
    public var setup: [String]
    public var statements: [String]
    /// Run last, whether or not the statements succeeded.
    public var teardown: [String]
    /// Whether a failure undoes the statements that already ran. MySQL commits each DDL
    /// statement as it goes.
    public var isAtomic: Bool
    /// Shown as comments above the statements.
    public var notes: [String]

    public init(
        setup: [String] = [], statements: [String] = [], teardown: [String] = [], isAtomic: Bool = true,
        notes: [String] = []
    ) {
        self.setup = setup
        self.statements = statements
        self.teardown = teardown
        self.isAtomic = isAtomic
        self.notes = notes
    }

    public var isEmpty: Bool { statements.isEmpty }

    /// Every statement in the order it runs, each ending with `;`, notes first.
    public var preview: String {
        var lines = notes.map { "-- " + $0 }
        lines += (setup + statements + teardown).map { $0 + ";" }
        return lines.joined(separator: "\n")
    }

    public static func + (a: DDLPlan, b: DDLPlan) -> DDLPlan {
        DDLPlan(
            setup: a.setup + b.setup.filter { !a.setup.contains($0) }, statements: a.statements + b.statements,
            teardown: a.teardown + b.teardown.filter { !a.teardown.contains($0) },
            isAtomic: a.isAtomic && b.isAtomic, notes: a.notes + b.notes)
    }
}

/// Options for dropping a table or view.
public struct DropOptions: Sendable, Hashable {
    /// Postgres: `CASCADE` also drops what depends on it.
    public var cascade: Bool
    /// MySQL: `FOREIGN_KEY_CHECKS = 0`; SQLite: `foreign_keys = OFF` around the statement.
    public var ignoreForeignKeys: Bool
    /// SQLite: whether foreign keys are enforced now, so they're turned back on afterwards.
    public var foreignKeysEnforced: Bool

    public init(cascade: Bool = false, ignoreForeignKeys: Bool = false, foreignKeysEnforced: Bool = false) {
        self.cascade = cascade
        self.ignoreForeignKeys = ignoreForeignKeys
        self.foreignKeysEnforced = foreignKeysEnforced
    }
}

public struct TruncateOptions: Sendable, Hashable {
    /// Postgres `RESTART IDENTITY`; SQLite forgets the table's AUTOINCREMENT counter.
    public var restartIdentity: Bool
    /// Postgres: also empties tables that reference this one.
    public var cascade: Bool
    /// MySQL: `FOREIGN_KEY_CHECKS = 0`, so a referenced table can be emptied.
    public var ignoreForeignKeys: Bool

    public init(restartIdentity: Bool = false, cascade: Bool = false, ignoreForeignKeys: Bool = false) {
        self.restartIdentity = restartIdentity
        self.cascade = cascade
        self.ignoreForeignKeys = ignoreForeignKeys
    }
}
