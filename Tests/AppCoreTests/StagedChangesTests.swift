import DBKit
import Foundation
import Testing
@testable import AppCore

private let people = TableRef("people")
private let logs = TableRef("logs")
private let peopleColumns = [
    ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
    ColumnInfo(name: "name", typeName: "TEXT"),
]
private let logColumns = [
    ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
    ColumnInfo(name: "line", typeName: "TEXT"),
]

/// A SQLite file with `people` (2 rows), `logs` (2 rows) and `scratch`.
private func makeDatabase() async throws -> any DatabaseConnection {
    let url = FileManager.default.temporaryDirectory.appending(path: "tabula-\(UUID().uuidString).db")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let db = try await ConnectionFactory.open(ConnectionConfig(filePath: url.path))
    _ = try await db.transaction([
        SQLStatement("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)"),
        SQLStatement("INSERT INTO people VALUES (1, 'Ann'), (2, 'Bo')"),
        SQLStatement("CREATE TABLE logs (id INTEGER PRIMARY KEY, line TEXT)"),
        SQLStatement("INSERT INTO logs VALUES (1, 'a'), (2, 'b')"),
        SQLStatement("CREATE TABLE scratch (x TEXT)"),
    ])
    return db
}

@MainActor
@Suite struct StagedChangesTests {
    /// Two tables' row edits, a truncate and a drop, staged in that order.
    private func stageEverything(_ changes: StagedChanges, dialect: any Dialect) {
        var p = TableEdits(table: people, columns: peopleColumns)
        p.set(.value(.text("Ann B")), column: 1, in: [.integer(1), .text("Ann")])
        p.addRow([1: .value(.text("Cy"))])
        changes.setEdits(p)
        var l = TableEdits(table: logs, columns: logColumns)
        l.delete([.integer(2), .text("b")])
        changes.setEdits(l)
        changes.stage(StagedAction(.truncate, DatabaseObject(logs, kind: .table),
                                   plan: dialect.truncate(logs, options: TruncateOptions(), hasAutoIncrement: false)))
        changes.stage(StagedAction(.drop, DatabaseObject(TableRef("scratch"), kind: .table),
                                   plan: try! dialect.drop(DatabaseObject(TableRef("scratch"), kind: .table), options: DropOptions())))
    }

    /// Closing a tab and reopening the table finds the same edits: they belong to the table.
    @Test func editsBelongToTheTable() {
        let changes = StagedChanges()
        var e = TableEdits(table: people, columns: peopleColumns)
        e.set(.value(.text("Ann B")), column: 1, in: [.integer(1), .text("Ann")])
        changes.setEdits(e)
        #expect(changes.edits(for: people)?.state(of: [.integer(1), .text("Ann")]) == .edited)
        #expect(changes.mark(for: people) == .edited)
        #expect(changes.mark(for: logs) == nil)
        // Unstaging the last edit unstages the table.
        e.set(.value(.text("Ann")), column: 1, in: [.integer(1), .text("Ann")])
        changes.setEdits(e)
        #expect(changes.isEmpty)
    }

    @Test func truncateAndDropReplaceWhatTheyWouldWipe() {
        let changes = StagedChanges()
        let d = SQLiteDialect()
        stageEverything(changes, dialect: d)
        // The truncate of logs took its row edits with it.
        #expect(changes.edits(for: logs) == nil)
        #expect(changes.edits(for: people) != nil)
        #expect(changes.mark(for: logs) == .truncated)
        #expect(changes.mark(for: TableRef("scratch")) == .dropped)
        // Dropping people takes its edits and structure edits; dropping logs replaces the truncate.
        changes.setStructure({
            var s = StructureEditor(TableStructure(table: people, columns: peopleColumns))
            s.comment = "x"
            return s
        }())
        changes.stage(StagedAction(.drop, DatabaseObject(people, kind: .table), plan: DDLPlan(statements: ["DROP TABLE people"])))
        changes.stage(StagedAction(.drop, DatabaseObject(logs, kind: .table), plan: DDLPlan(statements: ["DROP TABLE logs"])))
        #expect(changes.edits.isEmpty && changes.structures.isEmpty)
        #expect(changes.actions.map(\.object.ref.name) == ["scratch", "people", "logs"])
        changes.discard(people)
        #expect(changes.mark(for: people) == nil)
        changes.discardAll()
        #expect(changes.isEmpty)
    }

    @Test func newTablesGetFreeNames() {
        let changes = StagedChanges()
        let a = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: ["untitled_table"])
        let b = changes.addNewTable(schema: nil, dialect: SQLiteDialect(), taken: ["untitled_table"])
        #expect(changes.newTable(a)?.name == "untitled_table_2")
        #expect(changes.newTable(b)?.name == "untitled_table_3")
        changes.removeNewTable(a)
        #expect(changes.newTables.map(\.id) == [b])
    }

    @Test func onePreviewCoversEveryTable() throws {
        let changes = StagedChanges()
        stageEverything(changes, dialect: PostgresDialect())
        let plan = try changes.plan(dialect: PostgresDialect())
        #expect(plan.isAtomic)
        #expect(plan.preview == """
            -- people: 1 edited, 1 new
            UPDATE "people" SET "name" = 'Ann B' WHERE "id" = 1;
            INSERT INTO "people" ("name") VALUES ('Cy');

            -- truncate logs
            TRUNCATE TABLE "logs";

            -- delete scratch
            DROP TABLE "scratch";
            """)
        #expect(plan.summary == "4 statements, run in one transaction")
    }

    /// MySQL can't roll DDL back: the row edits come first, then the DDL one statement at a time.
    @Test func mysqlRunsDDLAfterTheRows() async throws {
        let changes = StagedChanges()
        let d = MySQLDialect()
        stageEverything(changes, dialect: d)
        let plan = try changes.plan(dialect: d)
        #expect(!plan.isAtomic)
        #expect(plan.statements == [
            "UPDATE `people` SET `name` = 'Ann B' WHERE `id` = 1",
            "INSERT INTO `people` (`name`) VALUES ('Cy')",
            "TRUNCATE TABLE `logs`",
            "DROP TABLE `scratch`",
        ])

        // The drop fails after the rows and the truncate went through.
        let db = ScriptedConnection(d, answers: [("DROP", .failure(DatabaseError("Unknown table 'scratch'")))])
        do {
            try await db.run(plan)
            Issue.record("expected a failure")
        } catch let e as PartialCommitError {
            #expect(e.applied == "the row changes and 1 DDL statement")
            #expect("\(e)".contains("Unknown table"))
        }
        #expect(db.sent == plan.statements)
    }

    @Test func sqliteCommitsEverythingInOneTransaction() async throws {
        let db = try await makeDatabase()
        let changes = StagedChanges()
        stageEverything(changes, dialect: db.dialect)
        let id = changes.addNewTable(schema: nil, dialect: db.dialect, taken: [])
        try await db.run(try changes.plan(dialect: db.dialect))
        #expect(try await db.execute("SELECT name FROM people ORDER BY id").rows == [[.text("Ann B")], [.text("Bo")], [.text("Cy")]])
        #expect(try await db.execute("SELECT COUNT(*) FROM logs").rows == [[.integer(0)]])
        let names = try await db.objects(schema: nil).map(\.ref.name)
        #expect(!names.contains("scratch"))
        #expect(names.contains(changes.newTable(id)!.name))
        await db.close()
    }

    /// A row edit that matches nothing rolls back the truncate and drop staged with it.
    @Test func aFailureRollsEverythingBack() async throws {
        let db = try await makeDatabase()
        let changes = StagedChanges()
        stageEverything(changes, dialect: db.dialect)
        var gone = TableEdits(table: people, columns: peopleColumns)
        gone.set(.value(.text("x")), column: 1, in: [.integer(42), .text("nobody")])
        gone.set(.value(.text("Ann B")), column: 1, in: [.integer(1), .text("Ann")])
        changes.setEdits(gone)
        await #expect(throws: DatabaseError.self) { try await db.run(try changes.plan(dialect: db.dialect)) }
        #expect(try await db.execute("SELECT COUNT(*) FROM logs").rows == [[.integer(2)]])
        #expect(try await db.objects(schema: nil).map(\.ref.name).contains("scratch"))
        #expect(try await db.execute("SELECT name FROM people WHERE id = 1").rows == [[.text("Ann")]])
        await db.close()
    }
}
