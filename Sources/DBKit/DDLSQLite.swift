import Foundation

// SQLite's ALTER TABLE can rename a table or column, add a column and drop one. Everything
// else (type, NOT NULL, default, primary key, foreign keys, constraint indexes) needs the
// rebuild from the SQLite docs ("Making Other Kinds Of Table Schema Changes"): create the new
// table under a temporary name, copy the rows, drop the old one, rename, then recreate the
// indexes and triggers that went with it.

extension SQLiteDialect {
    public var commonTypes: [String] {
        ["BLOB", "BOOLEAN", "DATE", "DATETIME", "INTEGER", "NUMERIC", "REAL", "TEXT", "VARCHAR"]
    }

    /// What only the CREATE TABLE text tells: AUTOINCREMENT and generated-column expressions,
    /// keyed by lowercased column name.
    public func columnTraits(definition: String) -> [String: (isAutoIncrement: Bool, generated: String?)] {
        guard let parsed = SQLiteTableSQL(definition) else { return [:] }
        var out: [String: (isAutoIncrement: Bool, generated: String?)] = [:]
        for c in parsed.columns {
            out[c.name.lowercased()] = (parsed.isAutoIncrement(c.name), parsed.generatedClause(c.name))
        }
        return out
    }

    /// A default as SQLite accepts it: literals as they are, anything else in parentheses.
    func defaultTerm(_ expression: String) -> String {
        let e = expression.trimmingCharacters(in: .whitespaces)
        if isPlainDefault(e) || e.hasPrefix("(") { return e }
        if e.hasPrefix("-") || e.hasPrefix("+"), Double(e) != nil { return e }
        return "(\(e))"
    }

    func newColumnDefinition(_ c: ColumnInfo, inlinePrimaryKey: Bool) -> String {
        var s = quoteIdentifier(c.name)
        if !c.typeName.isEmpty { s += " " + c.typeName }
        if inlinePrimaryKey { s += c.isAutoIncrement ? " PRIMARY KEY AUTOINCREMENT" : " PRIMARY KEY" }
        if let g = c.generated, !inlinePrimaryKey { s += " " + g }
        if !c.isNullable { s += " NOT NULL" }
        if let d = c.defaultExpression, c.generated == nil { s += " DEFAULT \(defaultTerm(d))" }
        return s
    }

    /// The column that holds the whole primary key inline (`id INTEGER PRIMARY KEY AUTOINCREMENT`),
    /// which AUTOINCREMENT requires.
    func inlineKeyColumn(_ columns: [ColumnInfo], primaryKey: [String]) -> String? {
        guard primaryKey.count == 1, let c = columns.first(where: { $0.name == primaryKey[0] }), c.isAutoIncrement
        else { return nil }
        return c.name
    }

    public func createTable(_ design: TableDesign, schema: String?) -> DDLPlan {
        let table = TableRef(schema: schema, design.name)
        let columns = design.columns.map(\.value)
        let inline = inlineKeyColumn(columns, primaryKey: design.primaryKey)
        var parts = columns.map { newColumnDefinition($0, inlinePrimaryKey: $0.name == inline) }
        if inline == nil, !design.primaryKey.isEmpty { parts.append("PRIMARY KEY \(columnList(design.primaryKey))") }
        parts += design.foreignKeys.map { foreignKeyClause($0.value, from: table) }
        var s = ["CREATE TABLE \(qualified(table)) (\n  " + parts.joined(separator: ",\n  ") + "\n)"]
        s += namedIndexes(design).map { createIndex($0, on: table) }
        return DDLPlan(statements: s)
    }

    func createIndex(_ index: IndexInfo, on table: TableRef) -> String {
        let name = index.name.isEmpty
            ? defaultIndexName(table: table.name, columns: index.columns, unique: index.isUnique) : index.name
        // SQLite puts the schema on the index name, not the table.
        return "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(qualified(TableRef(schema: table.schema, name)))"
            + " ON \(quoteIdentifier(table.name)) \(indexKeyList(index.columns))"
            + (index.predicate.map { $0.isEmpty ? "" : " WHERE \($0)" } ?? "")
    }

    func dropIndex(_ index: IndexInfo, of table: TableRef) -> String {
        "DROP INDEX \(qualified(TableRef(schema: table.schema, index.name)))"
    }

    public func alterTable(_ c: StructureChange) throws -> DDLPlan {
        try needsRebuild(c) ? rebuild(c) : alterInPlace(c)
    }

    func needsRebuild(_ c: StructureChange) -> Bool {
        if c.primaryKeyChanged || !c.droppedForeignKeys.isEmpty || !c.addedForeignKeys.isEmpty { return true }
        if c.droppedIndexes.contains(where: \.isConstraint) { return true }
        if c.keptColumns.contains(where: { $0.typeChanged || $0.nullabilityChanged || $0.defaultChanged || $0.autoIncrementChanged }) {
            return true
        }
        // ADD COLUMN takes neither NOT NULL without a default nor a non-constant default.
        for column in c.addedColumns {
            if column.isAutoIncrement || column.generated != nil { return true }
            if !column.isNullable, column.defaultExpression == nil { return true }
            if let d = column.defaultExpression, !isPlainDefault(d) || d.uppercased().hasPrefix("CURRENT_") { return true }
        }
        // DROP COLUMN refuses keys, constrained columns and indexed ones.
        let constrained = Set(c.oldPrimaryKey + c.original.foreignKeys.flatMap(\.columns)
            + c.original.indexes.filter(\.isConstraint).flatMap(\.columns)).map { $0.lowercased() }
        let checks = SQLiteTableSQL(c.original.definition ?? "")?.constraints.filter { $0.kind == .check } ?? []
        for column in c.droppedColumns {
            let name = column.name.lowercased()
            if constrained.contains(name) || checks.contains(where: { $0.identifiers.contains(name) }) { return true }
        }
        return false
    }

    func alterInPlace(_ c: StructureChange) -> DDLPlan {
        let table = c.original.table
        let t = qualified(table)
        var s: [String] = []
        s += c.droppedIndexes.map { dropIndex($0, of: table) }
        // An index on a dropped column has to go first or the DROP COLUMN fails.
        let dropped = Set(c.droppedColumns.map { $0.name.lowercased() })
        let droppedIndexNames = Set(c.droppedIndexes.map(\.name))
        for index in c.original.indexes where !index.isConstraint && !droppedIndexNames.contains(index.name) {
            if index.columns.contains(where: { dropped.contains($0.lowercased()) }) { s.append(dropIndex(index, of: table)) }
        }
        s += c.droppedColumns.map { "ALTER TABLE \(t) DROP COLUMN \(quoteIdentifier($0.name))" }
        for a in c.alteredColumns where a.renamed {
            s.append("ALTER TABLE \(t) RENAME COLUMN \(quoteIdentifier(a.old.name)) TO \(quoteIdentifier(a.new.name))")
        }
        s += c.addedColumns.map { "ALTER TABLE \(t) ADD COLUMN \(newColumnDefinition($0, inlinePrimaryKey: false))" }
        s += c.createdIndexes.map { createIndex($0, on: table) }
        if let name = c.renamedTable { s.append("ALTER TABLE \(t) RENAME TO \(quoteIdentifier(name))") }
        return DDLPlan(statements: s)
    }

    func rebuild(_ c: StructureChange) throws -> DDLPlan {
        let table = c.original.table
        guard let definition = c.original.definition, let parsed = SQLiteTableSQL(definition) else {
            throw DatabaseError("Can't change the structure of \(table.name): its CREATE TABLE statement couldn't be read.")
        }
        var notes: [String] = []
        let renames = Dictionary(c.renames.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        func rename(_ sql: String) -> String { renameIdentifiers(in: sql, renames, quote: quoteIdentifier) }
        let droppedNames = Set(c.droppedColumns.map { $0.name.lowercased() })
        let newColumns = c.design.columns.map(\.value)
        let rewriteKey = c.primaryKeyChanged
            || c.keptColumns.contains { $0.autoIncrementChanged } || c.addedColumns.contains { $0.isAutoIncrement }
        let inline = rewriteKey ? inlineKeyColumn(newColumns, primaryKey: c.newPrimaryKey) : nil

        func matches(_ key: ForeignKeyInfo, columns: [String], parent: String?) -> Bool {
            key.columns.map { $0.lowercased() } == columns.map { $0.lowercased() }
                && key.referencedTable.name.caseInsensitiveCompare(parent ?? "") == .orderedSame
        }

        // Columns, in the design's order.
        var parts: [String] = []
        for d in c.design.columns {
            let column = d.value
            guard let origin = d.origin, let old = parsed.column(named: c.original.columns[origin].name) else {
                parts.append(newColumnDefinition(column, inlinePrimaryKey: column.name == inline))
                continue
            }
            let a = c.keptColumns.first { $0.new.name == column.name }!
            var clauses = old.clauses
            if rewriteKey { clauses.removeAll { $0.kind == .primaryKey } }
            if a.nullabilityChanged { clauses.removeAll { $0.kind == .notNull || $0.kind == .null } }
            if a.defaultChanged { clauses.removeAll { $0.kind == .defaultValue } }
            clauses.removeAll { clause in
                clause.kind == .references && c.droppedForeignKeys.contains {
                    matches($0, columns: [a.old.name], parent: clause.referencedTable)
                }
            }
            var s = quoteIdentifier(column.name)
            let type = a.typeChanged ? column.typeName : old.type
            if !type.isEmpty { s += " " + type }
            if column.name == inline { s += column.isAutoIncrement ? " PRIMARY KEY AUTOINCREMENT" : " PRIMARY KEY" }
            for clause in clauses { s += " " + rename(clause.text) }
            if a.nullabilityChanged, !column.isNullable { s += " NOT NULL" }
            if a.defaultChanged, let def = column.defaultExpression { s += " DEFAULT \(defaultTerm(def))" }
            parts.append(s)
        }

        // Table constraints that still apply, then the new ones.
        let droppedUnique = c.droppedIndexes.filter { $0.isConstraint && !$0.isPrimary }
        for clause in parsed.constraints {
            switch clause.kind {
            case .primaryKey where rewriteKey:
                continue
            case .foreignKey where c.droppedForeignKeys.contains { matches($0, columns: clause.columns, parent: clause.referencedTable) }:
                continue
            case .unique where droppedUnique.contains { $0.columns.map { $0.lowercased() } == clause.columns.map { $0.lowercased() } }:
                continue
            default:
                if !clause.identifiers.isDisjoint(with: droppedNames) {
                    notes.append("Leaves out \(clause.text), which uses a dropped column.")
                    continue
                }
                parts.append(rename(clause.text))
            }
        }
        if rewriteKey, inline == nil, !c.newPrimaryKey.isEmpty { parts.append("PRIMARY KEY \(columnList(c.newPrimaryKey))") }
        parts += c.addedForeignKeys.map { foreignKeyClause($0, from: table) }

        let finalName = c.design.name
        let temporary = TableRef(schema: table.schema, "moonrow_new_" + finalName)
        var create = "CREATE TABLE \(qualified(temporary)) (\n  " + parts.joined(separator: ",\n  ") + "\n)"
        if !parsed.options.isEmpty { create += " " + parsed.options }

        // Copy the columns that existed before and aren't computed.
        let copied = c.keptColumns.filter { $0.new.generated == nil && parsed.generatedClause($0.old.name) == nil }
        var statements = [create]
        if !copied.isEmpty {
            statements.append(
                "INSERT INTO \(qualified(temporary)) \(columnList(copied.map(\.new.name)))"
                    + " SELECT \(copied.map { quoteIdentifier($0.old.name) }.joined(separator: ", ")) FROM \(qualified(table))")
        }
        statements.append("DROP TABLE \(qualified(table))")
        statements.append("ALTER TABLE \(qualified(temporary)) RENAME TO \(quoteIdentifier(finalName))")

        // Indexes and triggers went with the old table.
        let target = TableRef(schema: table.schema, finalName)
        let droppedIndexNames = Set(c.droppedIndexes.map(\.name))
        for index in c.original.indexes where !index.isConstraint && !droppedIndexNames.contains(index.name) {
            guard let sql = index.definition else { continue }
            if index.columns.contains(where: { droppedNames.contains($0.lowercased()) }) {
                notes.append("Drops index \(index.name), which uses a dropped column.")
                continue
            }
            statements.append(finalName == table.name ? rename(sql) : retarget(rename(sql), from: table.name, to: finalName))
        }
        statements += c.createdIndexes.map { createIndex($0, on: target) }
        for trigger in c.original.triggers where !trigger.definition.isEmpty {
            statements.append(finalName == table.name
                ? rename(trigger.definition) : retarget(rename(trigger.definition), from: table.name, to: finalName))
        }

        // legacy_alter_table keeps the RENAME from checking views that point at the dropped table;
        // they point at the new one once it has the name.
        var setup = ["PRAGMA legacy_alter_table = ON"]
        var teardown = ["PRAGMA legacy_alter_table = OFF"]
        if c.original.foreignKeysEnforced {
            setup.insert("PRAGMA foreign_keys = OFF", at: 0)
            teardown.append("PRAGMA foreign_keys = ON")
        }
        notes.insert("SQLite can't make this change in place: the table is rebuilt and its rows copied.", at: 0)
        return DDLPlan(setup: setup, statements: statements, teardown: teardown, notes: notes)
    }

    /// Points an index or trigger at the renamed table.
    func retarget(_ sql: String, from old: String, to new: String) -> String {
        renameIdentifiers(in: sql, [old.lowercased(): new], quote: quoteIdentifier)
    }

    public func drop(_ object: DatabaseObject, options: DropOptions) throws -> DDLPlan {
        let what = switch object.kind {
        case .table: "TABLE"
        case .view: "VIEW"
        default: throw DatabaseError("Only tables and views can be dropped from here.")
        }
        var plan = DDLPlan(statements: ["DROP \(what) \(qualified(object.ref))"])
        if options.ignoreForeignKeys, options.foreignKeysEnforced {
            plan.setup = ["PRAGMA foreign_keys = OFF"]
            plan.teardown = ["PRAGMA foreign_keys = ON"]
        }
        return plan
    }

    public func truncate(_ table: TableRef, options: TruncateOptions, hasAutoIncrement: Bool) -> DDLPlan {
        var s = ["DELETE FROM \(qualified(table))"]
        if options.restartIdentity, hasAutoIncrement {
            let sequence = TableRef(schema: table.schema, "sqlite_sequence")
            s.append("DELETE FROM \(qualified(sequence)) WHERE name = \(literal(.text(table.name)))")
        }
        return DDLPlan(statements: s)
    }

    public func supportsDefinitions(of kind: DefinitionKind) -> Bool { kind == .view || kind == .trigger }

    /// No `OR REPLACE`; the drop runs in the commit's transaction.
    public func replaceMethod(for kind: DefinitionKind) -> ReplaceMethod { .dropFirst }

    public func dropStatement(_ object: DefinedObject) throws -> String {
        switch object.kind {
        case .view: "DROP VIEW \(qualified(object.ref))"
        case .trigger: "DROP TRIGGER \(qualified(object.ref))"
        default: throw DatabaseError("SQLite has no \(object.kind.title)s.")
        }
    }

    /// The table's own CREATE TABLE under the new name (constraints and foreign keys included),
    /// and its indexes renamed after it. Triggers aren't copied.
    public func clone(_ structure: TableStructure, as name: String, withData: Bool) throws -> DDLPlan {
        let source = structure.table
        guard let definition = structure.definition,
              let create = DefinitionText.renamingCreate(definition, dialect: lexer, to: name, quote: quoteIdentifier)
        else { throw DatabaseError("Can't clone \(source.name): its CREATE TABLE statement couldn't be read.") }
        let target = TableRef(schema: source.schema, name)
        var s = [create]
        if withData {
            let copied = structure.columns.filter { $0.generated == nil }.map(\.name)
            s.append("INSERT INTO \(qualified(target)) \(columnList(copied))"
                     + " SELECT \(copied.map(quoteIdentifier).joined(separator: ", ")) FROM \(qualified(source))")
        }
        for index in structure.indexes where !index.isConstraint {
            guard let sql = index.definition,
                  let renamed = DefinitionText.renamingCreate(
                    sql, dialect: lexer, to: Self.cloneIndexName(index.name, from: source.name, to: name), onTable: name,
                    quote: quoteIdentifier)
            else { continue }
            s.append(renamed)
        }
        return DDLPlan(statements: s, notes: ["Triggers aren't copied."])
    }

    /// `people_email` → `people_copy_email`; a name that doesn't start with the table's gets it as a prefix.
    static func cloneIndexName(_ index: String, from table: String, to clone: String) -> String {
        if index.lowercased().hasPrefix(table.lowercased()) { return clone + index.dropFirst(table.count) }
        return clone + "_" + index
    }

    public func rename(_ object: DatabaseObject, to name: String) throws -> DDLPlan {
        guard object.kind == .table else { throw DatabaseError("SQLite can only rename tables.") }
        return DDLPlan(statements: ["ALTER TABLE \(qualified(object.ref)) RENAME TO \(quoteIdentifier(name))"])
    }
}
