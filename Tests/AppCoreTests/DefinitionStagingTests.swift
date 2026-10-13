import DBKit
import Foundation
import SQLScript
import Testing
@testable import AppCore

private let pg = PostgresDialect()
private let items = TableRef(schema: "public", "items")
private let view = DefinedObject(kind: .view, ref: TableRef(schema: "public", "stock"))
private let viewText = "CREATE OR REPLACE VIEW \"public\".\"stock\" AS\n SELECT 1;\n"

/// Edited and new definitions, trigger edits and clones in the workspace's staged changes.
@MainActor
@Suite struct DefinitionStagingTests {
    private func edited(_ text: String, of object: DefinedObject = view, original: String = viewText) -> StagedDefinition {
        StagedDefinition(kind: object.kind, object: object, schema: object.ref.schema, original: original, text: text, lexer: pg.lexer)
    }

    @Test func anEditIsStagedUntilItsTextIsBack() throws {
        let changes = StagedChanges()
        changes.setDefinition(edited(viewText))
        #expect(changes.isEmpty)
        var d = edited(viewText.replacingOccurrences(of: "1", with: "2"))
        changes.perform("Edit View", at: .sidebar) { changes.setDefinition(d) }
        #expect(changes.changeCount == 1)
        #expect(changes.mark(for: view.ref) == .edited)
        #expect(changes.mark(for: view.object!) == .edited)
        #expect(changes.summary == "view stock")
        let plan = try changes.plan(dialect: pg)
        #expect(plan.statements == ["CREATE OR REPLACE VIEW \"public\".\"stock\" AS\n SELECT 2"])
        #expect(plan.preview.hasPrefix("-- view stock\n"))

        // A second edit of the same object replaces the first.
        d.setText(viewText.replacingOccurrences(of: "1", with: "3"), lexer: pg.lexer)
        changes.setDefinition(d)
        #expect(changes.definitions.count == 1)
        changes.changesUndo()
        #expect(changes.isEmpty)
        changes.undoManager.redo()
        #expect(changes.definition(for: view)?.text.contains("3") == true)

        d.setText(viewText, lexer: pg.lexer)
        changes.setDefinition(d)
        #expect(changes.isEmpty)
    }

    @Test func aRenameInTheTextShowsAsTheStagedName() {
        let changes = StagedChanges()
        changes.setDefinition(edited(viewText.replacingOccurrences(of: "\"stock\"", with: "\"inventory\"")))
        #expect(changes.stagedName(for: view.ref) == "inventory")
        #expect(changes.definitions.first?.name == "inventory")
    }

    @Test func newObjectsGetUnusedNames() throws {
        let changes = StagedChanges()
        let template = { (kind: DefinitionKind) in { (name: String) in DefinitionTemplate.text(kind, name: name, schema: "public", dialect: pg) } }
        let first = changes.addNewDefinition(kind: .view, schema: "public", dialect: pg, taken: ["untitled_view"], template: template(.view))
        changes.addNewDefinition(kind: .view, schema: "public", dialect: pg, taken: ["untitled_view"], template: template(.view))
        changes.addNewDefinition(kind: .materializedView, schema: "public", dialect: pg, taken: [], template: template(.materializedView))
        #expect(changes.definitions.map(\.name) == ["untitled_view_2", "untitled_view_3", "untitled_materialized_view"])
        #expect(changes.definition(first)?.isNew == true)
        // New views take names the way tables do.
        #expect(changes.nameProblem("Untitled_View_2", existing: []) != nil)
        #expect(changes.summary == "new view untitled_view_2 · new view untitled_view_3 · new materialized view untitled_materialized_view")
        #expect(try changes.plan(dialect: pg).statements.first == "CREATE VIEW \"public\".\"untitled_view_2\" AS\nSELECT\n    1 AS \"id\"")
        changes.removeDefinition(first)
        #expect(changes.definitions.count == 2)
    }

    @Test func droppingATableTakesItsTriggerEditsAlong() {
        let changes = StagedChanges()
        let trigger = DefinedObject.trigger("touch", on: items)
        changes.setDefinition(edited("CREATE TRIGGER touch AFTER UPDATE ON public.items FOR EACH ROW EXECUTE FUNCTION f();",
                                     of: trigger, original: "old"))
        changes.addNewDefinition(kind: .trigger, schema: "public", table: items, dialect: pg, taken: []) { _ in "CREATE TRIGGER x" }
        #expect(changes.triggerDefinitions(of: items).count == 2)
        #expect(changes.mark(for: items) == nil)
        changes.perform("Delete Table", at: .sidebar) {
            changes.stage(StagedAction(.drop, DatabaseObject(items, kind: .table), plan: DDLPlan(statements: ["DROP TABLE items"])))
        }
        #expect(changes.triggerDefinitions(of: items).isEmpty)
        changes.undoManager.undo()
        #expect(changes.triggerDefinitions(of: items).count == 2)
        changes.discard(items)
        #expect(changes.isEmpty)
    }

    @Test func routinesAreToldApartBySignature() {
        let changes = StagedChanges()
        let int = DatabaseObject(TableRef(schema: "public", "items"), kind: .function, signature: "integer")
        let text = DatabaseObject(TableRef(schema: "public", "items"), kind: .function, signature: "text")
        changes.setEdits(TableEdits(table: items, columns: [ColumnInfo(name: "id", typeName: "int", primaryKeyPosition: 1)]))
        changes.stage(StagedAction(.drop, int, plan: DDLPlan(statements: ["DROP FUNCTION items(integer)"])))
        changes.stage(StagedAction(.drop, text, plan: DDLPlan(statements: ["DROP FUNCTION items(text)"])))
        // Both drops stay, and the table of the same name keeps what's staged for it.
        #expect(changes.actions.count == 2)
        #expect(changes.mark(for: int) == .dropped && changes.mark(for: text) == .dropped)
        #expect(changes.mark(for: items) == nil)
        #expect(changes.action(for: items) == nil)
    }

    @Test func clonesAreStagedUnderTheirNewName() throws {
        let changes = StagedChanges()
        let source = DatabaseObject(items, kind: .table)
        changes.setEdits(TableEdits(table: items, columns: [ColumnInfo(name: "id", typeName: "int", primaryKeyPosition: 1)]))
        changes.perform("Clone Table", at: .sidebar) {
            changes.stage(StagedAction(.clone(as: "items_copy", withData: true), source,
                                       plan: DDLPlan(statements: ["CREATE TABLE items_copy (LIKE items)"])))
        }
        #expect(changes.clones.map(\.name) == ["items_copy"])
        #expect(changes.mark(for: items) == nil)
        #expect(changes.nameProblem("items_copy", existing: ["items"]) != nil)
        #expect(changes.summary == "clone items as items_copy with its rows")
        // A truncate of the source keeps the clone, which runs first.
        changes.stage(StagedAction(.truncate, source, plan: DDLPlan(statements: ["TRUNCATE items"])))
        #expect(try changes.plan(dialect: pg).statements == ["CREATE TABLE items_copy (LIKE items)", "TRUNCATE items"])
        changes.removeClone(named: "items_copy")
        #expect(changes.clones.isEmpty)
    }
}

extension StagedChanges {
    /// Undo, for tests that read better with a name.
    func changesUndo() { undoManager.undo() }
}
