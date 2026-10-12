import DBKit
import Foundation
import Testing
@testable import AppCore

private let people = TableRef("people")
private let columns = [
    ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
    ColumnInfo(name: "name", typeName: "TEXT"),
]
private let ann: [DBValue] = [.integer(1), .text("Ann")]
private let bo: [DBValue] = [.integer(2), .text("Bo")]
private let here = EditPlace(table: people, side: .data, rows: [0])

@MainActor
@Suite struct UndoTests {
    private func edit(_ changes: StagedChanges, _ name: String = "Edit Cell", _ body: (inout TableEdits) -> Void) {
        changes.perform(name, at: here) {
            var e = changes.edits(for: people) ?? TableEdits(table: people, columns: columns)
            body(&e)
            changes.setEdits(e)
        }
    }

    private func value(_ changes: StagedChanges, _ row: [DBValue]) -> CellChange? {
        changes.edits(for: people)?.change(in: row, column: 1)
    }

    @Test func eachActionUndoesAndRedoes() {
        let changes = StagedChanges()
        let um = changes.undoManager
        var restored: [EditPlace] = []
        changes.onRestore = { restored.append($0) }

        edit(changes) { $0.set(.value(.text("Ann B")), column: 1, in: ann) }
        edit(changes, "Delete Rows") { $0.delete(ann); $0.delete(bo) }
        #expect(um.undoMenuItemTitle == "Undo Delete Rows")
        #expect(changes.changeCount == 2)

        // A multi-row delete is one step.
        um.undo()
        #expect(changes.edits(for: people)?.deletedRowCount == 0)
        #expect(value(changes, ann) == .value(.text("Ann B")))
        #expect(um.redoMenuItemTitle == "Redo Delete Rows")
        #expect(restored == [here])

        um.undo()
        #expect(changes.isEmpty)
        #expect(!um.canUndo)

        um.redo()
        um.redo()
        #expect(changes.edits(for: people)?.deletedRowCount == 2)
        #expect(changes.edits(for: people)?.updatedRowCount == 0)
        #expect(restored.count == 4)
    }

    @Test func aStepThatChangesNothingIsNotRecorded() {
        let changes = StagedChanges()
        edit(changes) { _ in }
        #expect(!changes.undoManager.canUndo)
        // Setting a cell to its loaded value stages nothing either.
        edit(changes) { $0.set(.value(.text("Ann")), column: 1, in: ann) }
        #expect(!changes.undoManager.canUndo)
    }

    @Test func nestedStepsJoinTheOuterOne() {
        let changes = StagedChanges()
        changes.perform("Paste", at: here) {
            edit(changes) { $0.set(.value(.text("A")), column: 1, in: ann) }
            edit(changes) { $0.set(.value(.text("B")), column: 1, in: bo) }
        }
        changes.undoManager.undo()
        #expect(changes.isEmpty)
        #expect(!changes.undoManager.canUndo)
    }

    /// Staging a drop replaces the table's row edits; undoing the drop brings them back.
    @Test func undoBringsBackWhatAnActionReplaced() {
        let changes = StagedChanges()
        edit(changes) { $0.set(.value(.text("Ann B")), column: 1, in: ann) }
        changes.perform("Delete Table", at: .sidebar) {
            changes.stage(StagedAction(.drop, DatabaseObject(people, kind: .table), plan: DDLPlan(statements: ["DROP TABLE people"])))
        }
        #expect(changes.edits(for: people) == nil)
        #expect(changes.mark(for: people) == .dropped)
        changes.undoManager.undo()
        #expect(changes.mark(for: people) == .edited)
        #expect(value(changes, ann) == .value(.text("Ann B")))
    }

    @Test func discardAllIsOneStep() {
        let changes = StagedChanges()
        edit(changes) { $0.set(.value(.text("Ann B")), column: 1, in: ann) }
        let id = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: [])
        changes.perform("Discard All", at: .sidebar) { changes.discardAll() }
        #expect(changes.isEmpty)
        changes.undoManager.undo()
        #expect(changes.newTable(id) != nil)
        #expect(value(changes, ann) == .value(.text("Ann B")))
    }

    /// A deleted new table comes back with the same id, so its tab can reopen.
    @Test func deletingANewTableUndoes() {
        let changes = StagedChanges()
        var id = UUID()
        changes.perform("New Table", at: .sidebar) { id = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: []) }
        changes.perform("Delete Table", at: EditPlace(newTable: id, side: .sidebar)) { changes.removeNewTable(id) }
        #expect(changes.newTables.isEmpty)
        changes.undoManager.undo()
        #expect(changes.newTable(id)?.name == "untitled_table")
        #expect(changes.undoManager.undoMenuItemTitle == "Undo New Table")
    }

    @Test func structureChangesUndo() {
        let changes = StagedChanges()
        let structure = TableStructure(table: people, columns: columns)
        changes.perform("New Column", at: EditPlace(table: people, side: .structure)) {
            var s = StructureEditor(structure)
            s.addColumn(type: "TEXT")
            changes.setStructure(s)
        }
        changes.perform("Rename Table", at: EditPlace(table: people, side: .structure)) {
            var s = changes.structure(for: people)!
            s.name = "persons"
            changes.setStructure(s)
        }
        #expect(changes.stagedName(for: people) == "persons")
        #expect(changes.changeCount == 2)
        changes.undoManager.undo()
        #expect(changes.stagedName(for: people) == nil)
        #expect(changes.structure(for: people)?.columns.count == 3)
        changes.undoManager.undo()
        #expect(changes.structure(for: people) == nil)
    }

    /// After a commit only later changes can be undone; a failed commit keeps the steps.
    @Test func commitClearsTheSteps() {
        let changes = StagedChanges()
        edit(changes) { $0.set(.value(.text("Ann B")), column: 1, in: ann) }
        changes.clearAfterCommit()
        #expect(changes.isEmpty)
        #expect(!changes.undoManager.canUndo && !changes.undoManager.canRedo)
        edit(changes) { $0.set(.value(.text("Bo B")), column: 1, in: bo) }
        changes.undoManager.undo()
        #expect(changes.isEmpty)
        #expect(!changes.undoManager.canUndo)
    }

    @Test func viewRenamesAreStaged() throws {
        let changes = StagedChanges()
        let v = DatabaseObject(TableRef("recent"), kind: .view)
        let d = PostgresDialect()
        changes.stage(StagedAction(.rename(to: "latest"), v, plan: try d.rename(v, to: "latest")))
        changes.stage(StagedAction(.rename(to: "newest"), v, plan: try d.rename(v, to: "newest")))
        #expect(changes.actions.count == 1)
        #expect(changes.stagedName(for: v.ref) == "newest")
        #expect(changes.mark(for: v.ref) == .edited)
        #expect(try changes.plan(dialect: d).preview == """
            -- rename recent to newest
            ALTER VIEW "recent" RENAME TO "newest";
            """)
        // A drop replaces the rename.
        changes.stage(StagedAction(.drop, v, plan: try d.drop(v, options: DropOptions())))
        #expect(changes.actions.map(\.title) == ["delete recent"])
    }

    @Test func namesMustBeFreeAndNotEmpty() {
        let changes = StagedChanges()
        let a = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: [])
        let b = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: [])
        let existing = ["people", "logs"]
        #expect(changes.nameProblem("  ", newTable: a, existing: existing) == "A table needs a name.")
        #expect(changes.nameProblem("People", newTable: a, existing: existing) != nil)
        #expect(changes.nameProblem("untitled_table_2", newTable: a, existing: existing) != nil)
        #expect(changes.nameProblem("untitled_table", newTable: a, existing: existing) == nil)
        #expect(changes.nameProblem("orders", newTable: b, existing: existing) == nil)
        // Renaming a table to its own name is fine; to a name another rename takes is not.
        #expect(changes.nameProblem("people", renaming: people, existing: existing) == nil)
        var s = StructureEditor(TableStructure(table: TableRef("logs"), columns: columns))
        s.name = "events"
        changes.setStructure(s)
        #expect(changes.nameProblem("events", renaming: people, existing: existing) != nil)
        #expect(changes.nameProblem("events", renaming: TableRef("logs"), existing: existing) == nil)
    }
}
