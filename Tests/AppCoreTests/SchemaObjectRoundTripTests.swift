import DBKit
import Foundation
import Testing
@testable import AppCore

/// M10's acceptance check, on every backend: views, routines and triggers written through the
/// definition editor's staged changes run exactly what the preview shows, behave as written,
/// and read back as a definition that, written again, reads back the same (the round trip).
/// Clones copy the structure and the rows.
@MainActor @Suite(.serialized) struct SchemaObjectRoundTripTests {
    /// Commits what's staged and checks the server ran the preview's statements.
    private func commit(_ f: Fixture, _ changes: StagedChanges) async throws {
        let plan = try changes.plan(dialect: f.db.dialect)
        try await f.startLog()
        try await f.db.run(plan)
        #expect(try await f.ran(count: plan.statements.count) == plan.statements)
        changes.clearAfterCommit()
    }

    private func objects(_ f: Fixture, _ kind: ObjectKind) async throws -> [DatabaseObject] {
        try await f.db.objects(schema: nil).filter { $0.kind == kind }
    }

    private func value(_ f: Fixture, _ sql: String) async throws -> String? {
        try await f.rows(sql).first?.first?.displayString
    }

    /// Writes the loaded definition back as an edit (forcing the replacement) and reads it again.
    private func roundTrip(_ f: Fixture, _ object: DefinedObject) async throws {
        let loaded = try await ObjectActions.definitionText(object, on: f.db)
        let changes = StagedChanges()
        var d = StagedDefinition(kind: object.kind, object: object, schema: nil, original: "", text: loaded, lexer: f.db.dialect.lexer)
        d.original = "-- forces a replacement"
        changes.setDefinition(d)
        try await commit(f, changes)
        #expect(try await ObjectActions.definitionText(object, on: f.db) == loaded, "\(object.ref.name) reads back the same")
    }

    private func stage(_ changes: StagedChanges, _ f: Fixture, _ object: DefinedObject, _ edit: (String) -> String) async throws {
        let loaded = try await ObjectActions.definitionText(object, on: f.db)
        let edited = edit(loaded)
        #expect(edited != loaded, "the edit changes \(object.ref.name)'s text")
        changes.setDefinition(StagedDefinition(
            kind: object.kind, object: object, schema: nil, original: loaded, text: edited, lexer: f.db.dialect.lexer))
    }

    @Test(arguments: Backend.all) func views(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let d = f.db.dialect
        let changes = StagedChanges()
        changes.addNewDefinition(kind: .view, schema: nil, dialect: d, taken: ["items"]) { name in
            "CREATE VIEW \(d.quoteIdentifier(name)) AS SELECT name, qty FROM items WHERE qty > 0;"
        }
        #expect(changes.definitions.first?.name == "untitled_view")
        try await commit(f, changes)
        let view = try #require(try await objects(f, .view).first)
        #expect(view.ref.name == "untitled_view")
        #expect(try await f.rows("SELECT COUNT(*) FROM untitled_view").first?.first == .integer(2))

        // An edit that keeps the name replaces the view in place.
        let object = try #require(DefinedObject(view))
        try await stage(changes, f, object) { $0.replacingOccurrences(of: "> 0", with: ">= 0") }
        #expect(changes.mark(for: view.ref) == .edited)
        try await commit(f, changes)
        #expect(try await f.rows("SELECT COUNT(*) FROM untitled_view").first?.first == .integer(3))
        try await roundTrip(f, object)

        // Another name in the text renames it: the old view is dropped first.
        try await stage(changes, f, object) { $0.replacingOccurrences(of: "untitled_view", with: "stock") }
        #expect(changes.stagedName(for: view.ref) == "stock")
        try await commit(f, changes)
        #expect(try await objects(f, .view).map(\.ref.name) == ["stock"])
    }

    @Test(arguments: Backend.all) func triggers(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let d = f.db.dialect
        let items = try #require(try await objects(f, .table).first { $0.ref.name == "items" }).ref
        let changes = StagedChanges()
        changes.addNewDefinition(kind: .trigger, schema: items.schema, table: items, dialect: d, taken: []) { name in
            DefinitionTemplate.text(.trigger, name: name, schema: items.schema, table: items, dialect: d)
        }
        try await commit(f, changes)
        let loaded = try await f.db.triggers(of: items)
        #expect(loaded.map(\.name) == ["untitled_trigger"])
        let object = DefinedObject.trigger("untitled_trigger", on: items)

        // Make it do something: the note becomes 'touched' on update.
        try await stage(changes, f, object) { text in
            switch backend.kind {
            case .sqlite:
                text.replacingOccurrences(of: "SELECT 1;", with: "UPDATE items SET note = 'touched' WHERE id = NEW.id;")
            case .mysql:
                text.replacingOccurrences(of: "BEGIN\nEND", with: "SET NEW.note = 'touched'")
            case .postgres:
                text.replacingOccurrences(of: "BEFORE UPDATE", with: "BEFORE INSERT OR UPDATE")
            }
        }
        try await commit(f, changes)
        if backend.kind != .postgres {
            _ = try await f.db.execute("UPDATE items SET qty = 9 WHERE name = 'fig'")
            #expect(try await value(f, "SELECT note FROM items WHERE name = 'fig'") == "touched")
        } else {
            #expect(try await f.db.triggers(of: items).first?.events == ["INSERT", "UPDATE"])
        }
        try await roundTrip(f, object)

        // Deleting it from the list.
        var drop = StagedDefinition(kind: .trigger, object: object, schema: nil, original: "", text: "", lexer: d.lexer)
        drop.isDropped = true
        changes.setDefinition(drop)
        #expect(try changes.plan(dialect: d).statements.contains { $0.hasPrefix("DROP TRIGGER") })
        try await commit(f, changes)
        #expect(try await f.db.triggers(of: items).isEmpty)
    }

    @Test(arguments: Backend.all.filter { $0.kind != .sqlite }) func routines(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let d = f.db.dialect
        let changes = StagedChanges()
        for kind in [DefinitionKind.function, .procedure] {
            changes.addNewDefinition(kind: kind, schema: nil, dialect: d, taken: []) { name in
                DefinitionTemplate.text(kind, name: name, schema: nil, dialect: d)
            }
        }
        try await commit(f, changes)
        #expect(try await objects(f, .function).map(\.ref.name) == ["untitled_function"])
        #expect(try await objects(f, .procedure).map(\.ref.name) == ["untitled_procedure"])
        #expect(try await value(f, "SELECT untitled_function()") == "1")

        let functionObject = try #require(try await objects(f, .function).first)
        let function = try #require(DefinedObject(functionObject))
        try await stage(changes, f, function) { text in
            backend.kind == .postgres ? text.replacingOccurrences(of: "SELECT 1;", with: "SELECT 2;")
                : text.replacingOccurrences(of: "RETURN 1", with: "RETURN 2")
        }
        try await commit(f, changes)
        #expect(try await value(f, "SELECT untitled_function()") == "2")
        try await roundTrip(f, function)
        let procedureObject = try #require(try await objects(f, .procedure).first)
        let procedure = try #require(DefinedObject(procedureObject))
        try await roundTrip(f, procedure)

        // A definition the database refuses changes nothing.
        try await stage(changes, f, function) { text in
            text.replacingOccurrences(of: backend.kind == .postgres ? "SELECT 2;" : "RETURN 2", with: "RETURN nope(")
        }
        await #expect(throws: (any Error).self) { try await f.db.run(try changes.plan(dialect: d)) }
        #expect(try await value(f, "SELECT untitled_function()") == "2")
        changes.discardAll()

        // Deleting one from the sidebar.
        let dropped = try #require(function.object)
        changes.stage(StagedAction(.drop, dropped, plan: try await ObjectActions.dropPlan([dropped], options: DropOptions(), on: f.db)))
        #expect(changes.mark(for: dropped) == .dropped)
        #expect(changes.mark(for: TableRef("untitled_function")) == nil)
        try await commit(f, changes)
        #expect(try await objects(f, .function).isEmpty)
    }

    @Test(arguments: Backend.all.filter { $0.kind == .postgres }) func postgresOverloadsAndMaterializedViews(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        for sql in [
            "CREATE FUNCTION twice(a integer) RETURNS integer LANGUAGE sql AS $$ SELECT a * 2 $$",
            "CREATE FUNCTION twice(a text) RETURNS text LANGUAGE sql AS $$ SELECT a || a $$",
            "CREATE MATERIALIZED VIEW stock AS SELECT name, qty FROM items",
            "CREATE INDEX stock_name ON stock (name)",
        ] { _ = try await f.db.execute(sql) }
        let overloads = try await objects(f, .function)
        #expect(overloads.map(\.signature) == ["a integer", "a text"])

        // Editing one overload leaves the other alone.
        let changes = StagedChanges()
        let int = try #require(DefinedObject(overloads[0]))
        try await stage(changes, f, int) { $0.replacingOccurrences(of: "a * 2", with: "a * 3") }
        #expect(changes.mark(for: overloads[0]) == .edited && changes.mark(for: overloads[1]) == nil)
        try await commit(f, changes)
        #expect(try await value(f, "SELECT twice(2)") == "6")
        #expect(try await value(f, "SELECT twice('ab'::text)") == "abab")
        try await roundTrip(f, int)

        // A materialized view is dropped and created again, its index with it.
        let mvObject = try #require(try await objects(f, .materializedView).first)
        let mv = try #require(DefinedObject(mvObject))
        try await stage(changes, f, mv) { $0.replacingOccurrences(of: "FROM items", with: "FROM items\n  WHERE qty > 0") }
        try await commit(f, changes)
        #expect(try await f.rows("SELECT COUNT(*) FROM stock").first?.first == .integer(2))
        #expect(try await f.db.indexes(of: mv.ref).map(\.name) == ["stock_name"])
        try await roundTrip(f, mv)
    }

    @Test(arguments: Backend.all.filter { $0.kind == .mysql }) func mysqlChecksARoutineBeforeDroppingIt(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        _ = try await f.db.execute("CREATE FUNCTION f() RETURNS INT DETERMINISTIC RETURN 1")
        let functionObject = try #require(try await objects(f, .function).first)
        let function = try #require(DefinedObject(functionObject))
        let changes = StagedChanges()
        try await stage(changes, f, function) { $0.replacingOccurrences(of: "RETURN 1", with: "RETURN nope(") }
        await #expect(throws: (any Error).self) { try await f.db.run(try changes.plan(dialect: f.db.dialect)) }
        #expect(try await objects(f, .function).map(\.ref.name) == ["f"])
        #expect(try await value(f, "SELECT f()") == "1")
    }

    @Test(arguments: Backend.all) func clones(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let items = try #require(try await objects(f, .table).first { $0.ref.name == "items" })
        let changes = StagedChanges()
        for (name, withData) in [("items_copy", true), ("items_empty", false)] {
            let plan = try await ObjectActions.clonePlan(items.ref, as: name, withData: withData, on: f.db)
            changes.stage(StagedAction(.clone(as: name, withData: withData), items, plan: plan))
        }
        #expect(changes.clones.map(\.name) == ["items_copy", "items_empty"])
        #expect(changes.nameProblem("ITEMS_COPY", existing: ["items"]) != nil)
        try await commit(f, changes)

        let original = try await f.db.structure(of: items.ref)
        for name in ["items_copy", "items_empty"] {
            let copy = try await f.db.structure(of: TableRef(schema: items.ref.schema, name))
            #expect(copy.columns.map(\.name) == original.columns.map(\.name))
            #expect(copy.columns.map(\.typeName) == original.columns.map(\.typeName))
            #expect(copy.primaryKey == ["id"])
        }
        #expect(try await f.rows("SELECT id, name, qty, note FROM items_copy ORDER BY id").map { $0.map(\.displayString) }
                == f.rows("SELECT id, name, qty, note FROM items ORDER BY id").map { $0.map(\.displayString) })
        #expect(try await f.rows("SELECT COUNT(*) FROM items_empty").first?.first == .integer(0))
        // New rows in the copy get keys past the copied ones.
        _ = try await f.db.execute("INSERT INTO items_copy (name) VALUES ('kiwi')")
        #expect(try await value(f, "SELECT id FROM items_copy WHERE name = 'kiwi'") == "4")
    }
}
