import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

/// M5's acceptance check, on every backend: a structure change runs exactly the DDL its preview
/// shows (read back from the server's statement log), the table then has the structure that was
/// designed, and the rows are still there.
@Suite(.serialized) struct StructureRoundTripTests {
    /// Applies the change and returns what the preview listed and what the database ran.
    private func apply(_ f: Fixture, _ plan: DDLPlan) async throws -> (preview: [String], ran: [String]) {
        let preview = plan.setup + plan.statements + plan.teardown
        try await f.startLog()
        try await f.db.apply(plan)
        return (preview, try await f.ran(count: preview.count))
    }

    private func design(_ s: TableStructure, _ edit: (inout TableDesign) -> Void) -> TableDesign {
        var d = TableDesign(s)
        edit(&d)
        return d
    }

    private func types(_ backend: Backend) -> (varchar80: String, loaded80: String, text: String, int: String) {
        switch backend.kind {
        case .sqlite: ("VARCHAR(80)", "VARCHAR(80)", "TEXT", "INTEGER")
        case .postgres: ("varchar(80)", "character varying(80)", "text", "integer")
        case .mysql: ("varchar(80)", "varchar(80)", "varchar(20)", "int")
        }
    }

    @Test(arguments: Backend.all) func columnsAndIndexes(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let t = types(backend)
        let items = TableRef("items")
        let before = try await f.db.structure(of: items)

        let d = design(before) { d in
            func edit(_ name: String, _ change: (inout ColumnInfo) -> Void) {
                change(&d.columns[d.columns.firstIndex { $0.value.name == name }!].value)
            }
            edit("qty") { $0.name = "quantity"; $0.defaultExpression = "1" }
            edit("note") { $0.typeName = t.varchar80; if backend.kind != .sqlite { $0.comment = "free text" } }
            edit("name") { $0.isNullable = true }
            d.columns.removeAll { $0.value.name == "price" }
            d.columns.append(Designed(origin: nil, ColumnInfo(name: "sku", typeName: t.text, defaultExpression: "'n/a'")))
            d.indexes.append(Designed(origin: nil, IndexInfo(name: "items_name", columns: ["name", "quantity"])))
        }
        let plan = try f.db.dialect.alterTable(StructureChange(from: before, to: d))
        let (preview, ran) = try await apply(f, plan)
        #expect(ran == preview)

        let after = try await f.db.structure(of: items)
        #expect(after.columns.map(\.name) == ["id", "name", "quantity", "note", "added", "sku"])
        let byName = Dictionary(uniqueKeysWithValues: after.columns.map { ($0.name, $0) })
        #expect(byName["quantity"]?.defaultExpression == "1")
        #expect(byName["name"]?.isNullable == true)
        #expect(byName["note"]?.typeName == t.loaded80)
        #expect(byName["sku"]?.defaultExpression?.hasPrefix("'n/a'") == true)
        if backend.kind != .sqlite { #expect(byName["note"]?.comment == "free text") }
        #expect(after.primaryKey == ["id"])
        #expect(after.indexes.first { $0.name == "items_name" }?.columns == ["name", "quantity"])
        #expect(try await f.rows("SELECT name, quantity, sku FROM items ORDER BY id").map { $0.map(\.displayString) } == [
            ["apple", "3", "n/a"], ["pear", "5", "n/a"], ["fig", "0", "n/a"],
        ])
        // What was read back describes the table exactly: designing from it changes nothing.
        #expect(StructureChange(from: after, to: TableDesign(after)).isEmpty)
        let again = try f.db.dialect.alterTable(StructureChange(from: after, to: TableDesign(after)))
        #expect(again.statements.isEmpty)
    }

    @Test(arguments: Backend.all) func keysAndForeignKeys(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let t = types(backend)
        let pk = backend.kind == .sqlite ? "INTEGER PRIMARY KEY" : "\(t.int) PRIMARY KEY"
        _ = try await f.db.execute("CREATE TABLE parents (id \(pk))")
        _ = try await f.db.execute("INSERT INTO parents VALUES (1), (2)")
        let items = TableRef("items")

        // A new column with a key to parents, and a two-column primary key.
        let before = try await f.db.structure(of: items)
        let d = design(before) { d in
            d.columns.append(Designed(origin: nil, ColumnInfo(name: "parent_id", typeName: t.int)))
            d.foreignKeys.append(Designed(origin: nil, ForeignKeyInfo(
                name: backend.kind == .sqlite ? "" : "items_parent_fk", columns: ["parent_id"],
                referencedTable: TableRef("parents"), referencedColumns: ["id"], onDelete: "CASCADE")))
            d.primaryKey = ["id", "name"]
        }
        let (preview, ran) = try await apply(f, try f.db.dialect.alterTable(StructureChange(from: before, to: d)))
        #expect(ran == preview)
        let after = try await f.db.structure(of: items)
        #expect(after.primaryKey == ["id", "name"])
        #expect(after.foreignKeys.map(\.columns) == [["parent_id"]])
        #expect(after.foreignKeys.first?.onDelete == "CASCADE")
        #expect(try await f.rows("SELECT COUNT(*) FROM items").first?.first == .integer(3))
        #expect(StructureChange(from: after, to: TableDesign(after)).isEmpty)

        // And back: the key goes, the primary key is the id again.
        let undo = design(after) { d in
            d.foreignKeys = []
            d.primaryKey = ["id"]
        }
        let (preview2, ran2) = try await apply(f, try f.db.dialect.alterTable(StructureChange(from: after, to: undo)))
        #expect(ran2 == preview2)
        let final = try await f.db.structure(of: items)
        #expect(final.foreignKeys.isEmpty)
        #expect(final.primaryKey == ["id"])
    }

    @Test(arguments: Backend.all) func createRenameTruncateDrop(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let t = types(backend)
        let d = TableDesign(
            name: "notes",
            columns: [
                Designed(origin: nil, ColumnInfo(name: "id", typeName: t.int, isNullable: false, isAutoIncrement: true)),
                Designed(origin: nil, ColumnInfo(name: "body", typeName: t.text, isNullable: false, defaultExpression: "''")),
            ],
            primaryKey: ["id"],
            indexes: [Designed(origin: nil, IndexInfo(name: "", columns: ["body"]))])
        let dialect = f.db.dialect
        let (preview, ran) = try await apply(f, dialect.createTable(d, schema: nil))
        #expect(ran == preview)
        _ = try await f.db.execute("INSERT INTO notes (body) VALUES ('a')")
        _ = try await f.db.execute("INSERT INTO notes (body) VALUES ('b')")
        let created = try await f.db.structure(of: TableRef("notes"))
        #expect(created.columns.map(\.isAutoIncrement) == [true, false])
        #expect(created.indexes.contains { $0.name == "notes_body_idx" })

        let notes = DatabaseObject(TableRef("notes"), kind: .table)
        try await f.db.apply(dialect.truncate(notes.ref, options: TruncateOptions(restartIdentity: true), hasAutoIncrement: true))
        _ = try await f.db.execute("INSERT INTO notes (body) VALUES ('c')")
        // MySQL's TRUNCATE always restarts AUTO_INCREMENT; the others were asked to.
        #expect(try await f.rows("SELECT id, body FROM notes").map { $0.map(\.displayString) } == [["1", "c"]])

        try await f.db.apply(try dialect.rename(notes, to: "memos"))
        #expect(try await f.db.objects(schema: nil).map(\.ref.name).contains("memos"))
        try await f.db.apply(try dialect.drop(DatabaseObject(TableRef("memos"), kind: .table), options: DropOptions()))
        #expect(!(try await f.db.objects(schema: nil).map(\.ref.name).contains("memos")))
    }

    @Test(arguments: Backend.all) func definitionReadsBack(_ backend: Backend) async throws {
        let f = try await Fixture(backend)
        defer { Task { await f.tearDown() } }
        let text = try await f.db.definition(of: DatabaseObject(TableRef("items"), kind: .table))
        #expect(text.uppercased().contains("CREATE TABLE"))
        #expect(text.contains("note"))
    }

    // MARK: - SQLite rebuild

    @Test func sqliteRebuildKeepsConstraintsIndexesTriggersAndViews() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "moonrow-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteConnection(path: url.path)
        for sql in [
            "PRAGMA foreign_keys = ON",
            "CREATE TABLE teams (id INTEGER PRIMARY KEY)",
            """
            CREATE TABLE users (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              email TEXT NOT NULL COLLATE NOCASE UNIQUE,
              age INTEGER DEFAULT 0 CHECK (age >= 0),
              team_id INTEGER REFERENCES teams (id),
              twice INTEGER GENERATED ALWAYS AS (age * 2) VIRTUAL
            )
            """,
            "CREATE INDEX users_age ON users (age)",
            "CREATE TABLE log (msg TEXT)",
            "CREATE TRIGGER users_log AFTER INSERT ON users BEGIN INSERT INTO log VALUES (NEW.email); END",
            "CREATE VIEW adults AS SELECT email FROM users WHERE age >= 18",
            "INSERT INTO teams VALUES (1)",
            "INSERT INTO users (email, age, team_id) VALUES ('a@x', 20, 1), ('b@x', 10, NULL)",
        ] { _ = try await db.execute(SQLStatement(sql)) }

        let before = try await db.structure(of: TableRef("users"))
        #expect(before.foreignKeysEnforced)
        #expect(before.columns.map(\.name) == ["id", "email", "age", "team_id", "twice"])
        #expect(before.columns[4].generated == "GENERATED ALWAYS AS (age * 2) VIRTUAL")
        var d = TableDesign(before)
        d.columns[2].value.isNullable = false          // NOT NULL: a rebuild
        d.columns[2].value.defaultExpression = "18"
        d.foreignKeys = []
        let plan = try db.dialect.alterTable(StructureChange(from: before, to: d))
        #expect(plan.setup.first == "PRAGMA foreign_keys = OFF")
        try await db.apply(plan)

        let after = try await db.structure(of: TableRef("users"))
        #expect(after.foreignKeysEnforced)
        #expect(after.columns[2].isNullable == false && after.columns[2].defaultExpression == "18")
        #expect(after.foreignKeys.isEmpty)
        #expect(after.columns[0].isAutoIncrement)
        #expect(after.indexes.map(\.name).sorted() == ["sqlite_autoindex_users_1", "users_age"])
        #expect(after.triggers.map(\.name) == ["users_log"])
        // CHECK, COLLATE and the generated column are still there.
        await #expect(throws: DatabaseError.self) { _ = try await db.execute("INSERT INTO users (email, age) VALUES ('c@x', -1)") }
        _ = try await db.execute("INSERT INTO users (email) VALUES ('C@X')")
        await #expect(throws: DatabaseError.self) { _ = try await db.execute("INSERT INTO users (email) VALUES ('c@x')") }
        #expect(try await db.execute("SELECT twice FROM users WHERE email = 'C@X'").rows == [[.integer(36)]])
        #expect(try await db.execute("SELECT COUNT(*) FROM log").rows == [[.integer(3)]])
        #expect(try await db.execute("SELECT email FROM adults ORDER BY email").rows == [[.text("a@x")], [.text("C@X")]])
        #expect(try await db.execute("PRAGMA foreign_key_check").rows.isEmpty)
        await db.close()
    }
}
