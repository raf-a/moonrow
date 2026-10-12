import DBKit
import Foundation

/// A sidebar Truncate, Delete or view Rename, staged with the other changes and
/// committed with them. Tables are renamed through their structure editor instead.
public struct StagedAction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case truncate, drop
        case rename(to: String)
    }

    public var kind: Kind
    public var object: DatabaseObject
    /// Worked out when the dialog closed, with the options it showed.
    public var plan: DDLPlan

    public init(_ kind: Kind, _ object: DatabaseObject, plan: DDLPlan) {
        self.kind = kind
        self.object = object
        self.plan = plan
    }

    /// "truncate logs", for summaries and the preview.
    public var title: String {
        switch kind {
        case .truncate: "truncate \(object.ref.name)"
        case .drop: "delete \(object.ref.name)"
        case .rename(let name): "rename \(object.ref.name) to \(name)"
        }
    }
}

/// Where an undoable change was made, so undo and redo can show it again: the table (or staged
/// new table), the side of its tab, and what was selected there.
public struct EditPlace: Sendable, Hashable {
    public enum Side: Sendable, Hashable {
        case data, structure
        /// The items list: `objects` are the items that were selected.
        case sidebar
    }

    public var table: TableRef?
    public var kind: ObjectKind
    public var newTable: UUID?
    public var side: Side
    /// Selected grid rows: data rows, or structure columns.
    public var rows: IndexSet
    /// The data grid's focused column (model index), or the selected structure indexes.
    public var column: Int?
    public var indexRows: IndexSet
    /// Sidebar items the change was made on.
    public var objects: [DatabaseObject]

    public init(table: TableRef? = nil, kind: ObjectKind = .table, newTable: UUID? = nil, side: Side,
                rows: IndexSet = [], column: Int? = nil, indexRows: IndexSet = [], objects: [DatabaseObject] = []) {
        self.table = table
        self.kind = kind
        self.newTable = newTable
        self.side = side
        self.rows = rows
        self.column = column
        self.indexRows = indexRows
        self.objects = objects
    }

    public static let sidebar = EditPlace(side: .sidebar)
}

/// Everything staged in a workspace: row edits per table, structure edits, new tables, and
/// truncates and drops from the sidebar. One preview and one commit cover all of it.
///
/// Changes belong to the table, not to a tab: closing a tab or opening another table keeps
/// them, and reopening the table shows them again.
///
/// Every user action goes through `perform(_:at:_:)`, which makes it one step of `undoManager`.
/// A step keeps the whole staged state from before it, so undoing an action that replaced other
/// changes (a drop replacing row edits) brings those back too. A commit clears the steps.
@MainActor
public final class StagedChanges {
    /// Posted (object: self) whenever anything is staged or unstaged.
    public static let didChange = Notification.Name("StagedChanges.didChange")

    /// Undo and redo for staged changes; the workspace window hands it to AppKit.
    public let undoManager: UndoManager = {
        let m = UndoManager()
        // Steps are grouped by `perform`, not by run-loop pass, so tests behave like the app.
        m.groupsByEvent = false
        return m
    }()
    /// After an undo or redo restored the state: show where the step was made.
    public var onRestore: ((EditPlace) -> Void)?
    /// Bumped on every change, so `perform` can tell whether its body changed anything.
    private var revision = 0

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
        parts += actions.map(\.title)
        return parts.joined(separator: " · ")
    }

    private func changed() {
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Undo

    private struct Snapshot {
        var edits: [TableRef: TableEdits]
        var editOrder: [TableRef]
        var structures: [TableRef: StructureEditor]
        var structureOrder: [TableRef]
        var newTables: [NewTable]
        var actions: [StagedAction]
    }

    private var snapshot: Snapshot {
        Snapshot(edits: edits, editOrder: editOrder, structures: structures, structureOrder: structureOrder,
                 newTables: newTables, actions: actions)
    }

    private func restore(_ s: Snapshot) {
        edits = s.edits
        editOrder = s.editOrder
        structures = s.structures
        structureOrder = s.structureOrder
        newTables = s.newTables
        actions = s.actions
        changed()
    }

    /// Runs one user action as one undo step named `name` ("Edit Cell"). A body that changes
    /// nothing leaves no step. Nested calls join the outer step.
    public func perform(_ name: String, at place: EditPlace, _ body: () -> Void) {
        guard !isPerforming else { return body() }
        let before = snapshot
        let start = revision
        isPerforming = true
        body()
        isPerforming = false
        guard revision != start else { return }
        undoManager.beginUndoGrouping()
        register(before, name: name, place: place)
        undoManager.endUndoGrouping()
    }

    private var isPerforming = false

    private func register(_ state: Snapshot, name: String, place: EditPlace) {
        undoManager.registerUndo(withTarget: self) { changes in
            let current = changes.snapshot
            changes.restore(state)
            // Registered while undoing, this becomes the redo step (and the other way round).
            changes.register(current, name: name, place: place)
            changes.onRestore?(place)
        }
        undoManager.setActionName(name)
    }

    /// After a commit: nothing is staged, and nothing before it can be undone.
    public func clearAfterCommit() {
        undoManager.removeAllActions()
        restore(Snapshot(edits: [:], editOrder: [], structures: [:], structureOrder: [], newTables: [], actions: []))
    }

    // MARK: Counting

    /// How many changes are staged: each edited, new or deleted row, each structure change, each
    /// new table, truncate, drop and rename. The toolbar shows it.
    public var changeCount: Int {
        edits.values.reduce(0) { $0 + $1.updatedRowCount + $1.insertedRowCount + $1.deletedRowCount }
            + structures.values.reduce(0) { $0 + $1.changeCount }
            + newTables.count + actions.count
    }

    /// The name a table or view will have after the commit, when a rename is staged.
    public func stagedName(for table: TableRef) -> String? {
        if let s = structures[table], s.name != table.name { return s.name }
        for a in actions.reversed() where a.object.ref == table {
            if case .rename(let name) = a.kind { return name }
        }
        return nil
    }

    /// Why `name` can't be given to a new table (`newTable`) or to `renaming`, or nil. `existing`
    /// are the schema's table and view names. Names are compared ignoring case.
    public func nameProblem(_ name: String, newTable: UUID? = nil, renaming: TableRef? = nil, existing: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A table needs a name." }
        let wanted = trimmed.lowercased()
        var taken = existing.filter { $0.lowercased() != renaming?.name.lowercased() }.map { $0.lowercased() }
        taken += newTables.filter { $0.id != newTable }.map { $0.editor.name.lowercased() }
        for table in Set(structures.keys).union(actions.map(\.object.ref)) where table != renaming {
            if let renamed = stagedName(for: table) { taken.append(renamed.lowercased()) }
        }
        return taken.contains(wanted) ? "There is already a table or view named “\(trimmed)”." : nil
    }

    // MARK: Rows

    public func edits(for table: TableRef) -> TableEdits? { edits[table] }

    /// Stores a table's edits; empty edits unstage the table.
    public func setEdits(_ e: TableEdits) {
        guard edits[e.table] != e else { return }
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
        guard structures[table] != editor else { return }
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
    @discardableResult
    public func addNewTable(id: UUID = UUID(), schema: String?, dialect: any Dialect, taken: Set<String>) -> UUID {
        let names = taken.union(newTables.map { $0.editor.name.lowercased() })
        var name = "untitled_table"
        var n = 2
        while names.contains(name.lowercased()) {
            name = "untitled_table_\(n)"
            n += 1
        }
        var editor = StructureEditor.newTable(TableRef(schema: schema, ""), dialect: dialect)
        editor.name = name
        newTables.append(NewTable(id: id, editor: editor))
        changed()
        return id
    }

    public func setNewTable(_ id: UUID, _ editor: StructureEditor) {
        guard let i = newTables.firstIndex(where: { $0.id == id }), newTables[i].editor != editor else { return }
        newTables[i].editor = editor
        changed()
    }

    public func removeNewTable(_ id: UUID) {
        guard newTables.contains(where: { $0.id == id }) else { return }
        newTables.removeAll { $0.id == id }
        changed()
    }

    // MARK: Truncate and drop

    /// The staged drop of a table, else its staged truncate.
    public func action(for table: TableRef) -> StagedAction? {
        actions.last { $0.object.ref == table && $0.kind == .drop } ?? actions.last { $0.object.ref == table && $0.kind == .truncate }
    }

    /// A drop replaces everything staged for the object; a truncate replaces its row edits,
    /// which it would wipe anyway; a rename replaces an earlier rename.
    public func stage(_ action: StagedAction) {
        let table = action.object.ref
        if case .rename = action.kind {
            actions.removeAll { $0.object.ref == table && $0.isRename }
            actions.append(action)
            return changed()
        }
        if edits[table] != nil {
            edits[table] = nil
            editOrder.removeAll { $0 == table }
        }
        if action.kind == .drop, structures[table] != nil {
            structures[table] = nil
            structureOrder.removeAll { $0 == table }
        }
        actions.removeAll { $0.object.ref == table && (action.kind == .drop || !$0.isRename) }
        actions.append(action)
        changed()
    }

    /// Unstages a view's rename (renamed back to its own name).
    public func removeRename(of table: TableRef) {
        guard actions.contains(where: { $0.object.ref == table && $0.isRename }) else { return }
        actions.removeAll { $0.object.ref == table && $0.isRename }
        changed()
    }

    public func mark(for table: TableRef) -> Mark? {
        if let a = action(for: table) { return a.kind == .drop ? .dropped : .truncated }
        return edits[table] != nil || structures[table] != nil || stagedName(for: table) != nil ? .edited : nil
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

    /// Unstages everything (Discard All); undo brings it back.
    public func discardAll() {
        guard !isEmpty else { return }
        restore(Snapshot(edits: [:], editOrder: [], structures: [:], structureOrder: [], newTables: [], actions: []))
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
            sections.append(.init(title: a.title, ddl: a.plan))
        }
        return CommitPlan(sections: sections, dialect: dialect)
    }
}

extension StagedAction {
    var isRename: Bool {
        if case .rename = kind { return true }
        return false
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
