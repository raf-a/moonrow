import DBKit
import Foundation

/// A sidebar Truncate or Delete, staged with the other changes and committed with them.
public struct StagedAction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case truncate, drop }

    public var kind: Kind
    public var object: DatabaseObject
    /// Worked out when the dialog closed, with the options it showed.
    public var plan: DDLPlan

    public init(_ kind: Kind, _ object: DatabaseObject, plan: DDLPlan) {
        self.kind = kind
        self.object = object
        self.plan = plan
    }
}

/// Everything staged in a workspace: row edits per table, structure edits, new tables, and
/// truncates and drops from the sidebar. One preview and one commit cover all of it.
///
/// Changes belong to the table, not to a tab: closing a tab or opening another table keeps
/// them, and reopening the table shows them again.
@MainActor
public final class StagedChanges {
    /// Posted (object: self) whenever anything is staged or unstaged.
    public static let didChange = Notification.Name("StagedChanges.didChange")

    public struct NewTable: Sendable {
        public let id: UUID
        public var editor: StructureEditor
    }

    public enum Mark: Sendable, Hashable { case edited, truncated, dropped }

    public private(set) var edits: [TableRef: TableEdits] = [:]
    private var editOrder: [TableRef] = []
    /// Structure edits of existing tables, keyed by the table as it is in the database.
    public private(set) var structures: [TableRef: StructureEditor] = [:]
    private var structureOrder: [TableRef] = []
    public private(set) var newTables: [NewTable] = []
    public private(set) var actions: [StagedAction] = []

    public init() {}

    public var isEmpty: Bool { edits.isEmpty && structures.isEmpty && newTables.isEmpty && actions.isEmpty }

    /// "people: 2 edited · new table orders · truncate logs", for prompts.
    public var summary: String {
        var parts = editOrder.compactMap { t in edits[t].map { "\(t.name): \($0.summary)" } }
        parts += structureOrder.map { "\($0.name): structure" }
        parts += newTables.map { "new table \($0.editor.name.isEmpty ? "(unnamed)" : $0.editor.name)" }
        parts += actions.map { "\($0.kind == .truncate ? "truncate" : "delete") \($0.object.ref.name)" }
        return parts.joined(separator: " · ")
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Rows

    public func edits(for table: TableRef) -> TableEdits? { edits[table] }

    /// Stores a table's edits; empty edits unstage the table.
    public func setEdits(_ e: TableEdits) {
        if e.isEmpty {
            guard edits[e.table] != nil else { return }
            edits[e.table] = nil
            editOrder.removeAll { $0 == e.table }
        } else {
            if edits[e.table] == nil { editOrder.append(e.table) }
            edits[e.table] = e
        }
        changed()
    }

    // MARK: Structure

    public func structure(for table: TableRef) -> StructureEditor? { structures[table] }

    /// Stores an existing table's structure edits; an editor without changes unstages them.
    public func setStructure(_ editor: StructureEditor) {
        let table = editor.original.table
        if editor.hasChanges {
            if structures[table] == nil { structureOrder.append(table) }
            structures[table] = editor
        } else {
            guard structures[table] != nil else { return }
            structures[table] = nil
            structureOrder.removeAll { $0 == table }
        }
        changed()
    }

    // MARK: New tables

    public func newTable(_ id: UUID) -> StructureEditor? { newTables.first { $0.id == id }?.editor }

    /// Stages a new table named `untitled_table` (or `_2`, `_3`, … past `taken` names).
    public func addNewTable(schema: String?, dialect: any Dialect, taken: Set<String>) -> UUID {
        let names = taken.union(newTables.map { $0.editor.name.lowercased() })
        var name = "untitled_table"
        var n = 2
        while names.contains(name.lowercased()) {
            name = "untitled_table_\(n)"
            n += 1
        }
        let id = UUID()
        var editor = StructureEditor.newTable(TableRef(schema: schema, ""), dialect: dialect)
        editor.name = name
        newTables.append(NewTable(id: id, editor: editor))
        changed()
        return id
    }

    public func setNewTable(_ id: UUID, _ editor: StructureEditor) {
        guard let i = newTables.firstIndex(where: { $0.id == id }) else { return }
        newTables[i].editor = editor
        changed()
    }

    public func removeNewTable(_ id: UUID) {
        newTables.removeAll { $0.id == id }
        changed()
    }

    // MARK: Truncate and drop

    /// The staged drop of a table, else its staged truncate.
    public func action(for table: TableRef) -> StagedAction? {
        actions.last { $0.object.ref == table && $0.kind == .drop } ?? actions.last { $0.object.ref == table }
    }

    /// A drop replaces everything staged for the object; a truncate replaces its row edits,
    /// which it would wipe anyway.
    public func stage(_ action: StagedAction) {
        let table = action.object.ref
        if edits[table] != nil {
            edits[table] = nil
            editOrder.removeAll { $0 == table }
        }
        if action.kind == .drop, structures[table] != nil {
            structures[table] = nil
            structureOrder.removeAll { $0 == table }
        }
        actions.removeAll { $0.object.ref == table }
        actions.append(action)
        changed()
    }

    public func mark(for table: TableRef) -> Mark? {
        if let a = action(for: table) { return a.kind == .drop ? .dropped : .truncated }
        return edits[table] != nil || structures[table] != nil ? .edited : nil
    }

    // MARK: Discarding

    /// Unstages everything staged for one table.
    public func discard(_ table: TableRef) {
        edits[table] = nil
        editOrder.removeAll { $0 == table }
        structures[table] = nil
        structureOrder.removeAll { $0 == table }
        actions.removeAll { $0.object.ref == table }
        changed()
    }

    public func discardAll() {
        edits = [:]
        editOrder = []
        structures = [:]
        structureOrder = []
        newTables = []
        actions = []
        changed()
    }

    // MARK: Commit

    /// What a commit runs, in this order: row edits table by table (deletes, updates, inserts),
    /// structure changes, new tables, then truncates and drops in the order they were staged.
    /// Throws when a structure design can't be applied.
    public func plan(dialect: any Dialect) throws -> CommitPlan {
        var sections: [CommitPlan.Section] = []
        for table in editOrder {
            guard let e = edits[table] else { continue }
            let changes = e.changeSet(dialect: dialect)
            guard !changes.isEmpty else { continue }
            let note = e.hasPrimaryKey ? [] : ["\(table.name) has no primary key, so rows are matched on every column."]
            sections.append(.init(title: "\(table.name): \(e.summary)", notes: note, rows: dialect.statements(for: changes)))
        }
        for table in structureOrder {
            guard let s = structures[table] else { continue }
            sections.append(.init(title: "\(table.name): structure", ddl: try s.plan(for: dialect)))
        }
        for t in newTables {
            sections.append(.init(title: "new table \(t.editor.name)", ddl: try t.editor.plan(for: dialect)))
        }
        for a in actions {
            sections.append(.init(title: "\(a.kind == .truncate ? "truncate" : "delete") \(a.object.ref.name)", ddl: a.plan))
        }
        return CommitPlan(sections: sections, dialect: dialect)
    }
}

/// The statements of one workspace commit.
///
/// Where the database can roll DDL back (Postgres, SQLite), everything runs in one
/// transaction: the DDL plans' setup (SQLite's `PRAGMA foreign_keys = OFF`) runs before it and
/// their teardown after it. MySQL commits each DDL statement as it runs, so the row edits go
/// first in their own transaction and the DDL follows statement by statement.
public struct CommitPlan: Sendable {
    public struct Section: Sendable {
        public var title: String
        public var notes: [String]
        /// Row edits: each must change exactly one row.
        public var rows: [SQLFragment]
        public var ddl: DDLPlan?

        init(title: String, notes: [String] = [], rows: [SQLFragment] = [], ddl: DDLPlan? = nil) {
            self.title = title
            self.notes = notes + (ddl?.notes ?? [])
            self.rows = rows
            self.ddl = ddl
        }
    }

    public let sections: [Section]
    public let dialect: any Dialect

    public init(sections: [Section], dialect: any Dialect) {
        self.sections = sections
        self.dialect = dialect
    }

    public var isEmpty: Bool { sections.isEmpty }
    /// Whether DDL joins the row edits' transaction.
    public var isAtomic: Bool { dialect.transactionalDDL || !sections.contains { $0.ddl != nil } }

    private var setup: [String] { unique(sections.flatMap { $0.ddl?.setup ?? [] }) }
    private var teardown: [String] { unique(sections.flatMap { $0.ddl?.teardown ?? [] }) }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Every statement in the order it runs, without comments. What safe mode is shown.
    public var statements: [String] {
        let rows = sections.flatMap { $0.rows.map { $0.inlined(for: dialect) } }
        if dialect.transactionalDDL {
            return setup + rows + sections.flatMap { $0.ddl?.statements ?? [] } + teardown
        }
        return rows + sections.flatMap { s in s.ddl.map { $0.setup + $0.statements + $0.teardown } ?? [] }
    }

    /// The preview: a comment line per section, then its statements, each ending in `;`.
    /// Sections come in run order (row edits first where DDL can't share their transaction).
    public var preview: String {
        func lines(_ s: Section, _ statements: [String]) -> [String] {
            ["-- " + s.title] + s.notes.map { "-- " + $0 } + statements.map { $0 + ";" }
        }
        let rowSections = sections.filter { !$0.rows.isEmpty }
        let ddlSections = sections.filter { $0.ddl != nil }
        var out: [[String]] = []
        if dialect.transactionalDDL {
            if !setup.isEmpty { out.append(setup.map { $0 + ";" }) }
            out += rowSections.map { lines($0, $0.rows.map { $0.inlined(for: dialect) }) }
            out += ddlSections.map { lines($0, $0.ddl!.statements) }
            if !teardown.isEmpty { out.append(teardown.map { $0 + ";" }) }
        } else {
            out += rowSections.map { lines($0, $0.rows.map { $0.inlined(for: dialect) }) }
            out += ddlSections.map { lines($0, $0.ddl!.setup + $0.ddl!.statements + $0.ddl!.teardown) }
        }
        return out.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// One line for the preview's header.
    public var summary: String {
        let n = statements.count
        let what = "\(n) \(n == 1 ? "statement" : "statements")"
        if isAtomic { return n > 1 ? "\(what), run in one transaction" : what }
        return "\(what); \(dialect.name) applies each DDL statement as it runs, after the row changes"
    }
}

/// A commit that failed after some of it had been applied (MySQL DDL).
public struct PartialCommitError: Error, CustomStringConvertible {
    public var error: any Error
    /// What went through, for the message.
    public var applied: String

    public var description: String { "\(error) (Already applied: \(applied).)" }
}

extension DatabaseConnection {
    /// Runs a workspace commit; see `CommitPlan`. Row edits that change no row or several roll
    /// the transaction back. Throws `PartialCommitError` when some DDL went through before a
    /// failure; any other error means nothing changed.
    public func run(_ plan: CommitPlan) async throws {
        let dialect = plan.dialect
        let rows = plan.sections.flatMap(\.rows)
        let ddl = plan.sections.compactMap(\.ddl)
        // Each row statement must change exactly one row; DDL statements report what they like.
        func transaction(_ rows: [SQLFragment], then extra: [String]) async throws {
            let statements = rows.map { $0.statement(for: dialect) } + extra.map { SQLStatement($0) }
            guard !statements.isEmpty else { return }
            _ = try await self.transaction(statements) { i, affected in
                guard i < rows.count, affected != 1 else { return }
                let what = affected == 0 ? "matched no row; it may have been changed or deleted meanwhile"
                    : "would change \(affected) rows instead of one"
                throw DatabaseError("Nothing was saved: statement \(i + 1) \(what).", sql: rows[i].inlined(for: dialect))
            }
        }

        if dialect.transactionalDDL {
            let setup = ddl.flatMap(\.setup).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let teardown = ddl.flatMap(\.teardown).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            for sql in setup { _ = try await execute(SQLStatement(sql)) }
            do {
                try await transaction(rows, then: ddl.flatMap(\.statements))
            } catch {
                for sql in teardown { _ = try? await execute(SQLStatement(sql)) }
                throw error
            }
            for sql in teardown { _ = try await execute(SQLStatement(sql)) }
            return
        }

        try await transaction(rows, then: [])
        var applied = 0
        for plan in ddl {
            do {
                for sql in plan.setup { _ = try await execute(SQLStatement(sql)) }
                do {
                    for sql in plan.statements {
                        do {
                            _ = try await execute(SQLStatement(sql))
                        } catch var e as DatabaseError {
                            e.sql = sql
                            throw e
                        }
                        applied += 1
                    }
                } catch {
                    for sql in plan.teardown { _ = try? await execute(SQLStatement(sql)) }
                    throw error
                }
                for sql in plan.teardown { _ = try await execute(SQLStatement(sql)) }
            } catch {
                guard !rows.isEmpty || applied > 0 else { throw error }
                var parts: [String] = []
                if !rows.isEmpty { parts.append("the row changes") }
                if applied > 0 { parts.append("\(applied) DDL \(applied == 1 ? "statement" : "statements")") }
                throw PartialCommitError(error: error, applied: parts.joined(separator: " and "))
            }
        }
    }
}
