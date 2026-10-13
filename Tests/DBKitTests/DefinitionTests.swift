import Foundation
import SQLScript
import Testing
@testable import DBKit

private let sqlite = SQLiteDialect()
private let pg = PostgresDialect()
private let my = MySQLDialect()

@Suite struct DefinitionHeadTests {
    @Test func readsKindAndName() throws {
        let cases: [(String, LexerDialect, DefinitionKind, TableRef, Bool)] = [
            ("CREATE VIEW v AS SELECT 1", .sqlite, .view, TableRef("v"), false),
            ("create or replace view \"S\".\"My View\" as select 1", .postgres, .view, TableRef(schema: "S", "My View"), true),
            ("CREATE MATERIALIZED VIEW IF NOT EXISTS mv AS SELECT 1", .postgres, .materializedView, TableRef("mv"), false),
            ("CREATE OR REPLACE FUNCTION public.f(a integer) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql", .postgres,
             .function, TableRef(schema: "public", "f"), false),
            ("CREATE DEFINER=`root`@`%` PROCEDURE `p`() BEGIN SELECT 1; END", .mysql, .procedure, TableRef("p"), true),
            ("CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `db`.`v` AS select 1", .mysql,
             .view, TableRef(schema: "db", "v"), true),
            ("-- note\nCREATE CONSTRAINT TRIGGER t AFTER INSERT ON x FOR EACH ROW EXECUTE FUNCTION f()", .postgres,
             .trigger, TableRef("t"), false),
            ("CREATE TRIGGER [t] AFTER INSERT ON x BEGIN SELECT 1; END", .sqlite, .trigger, TableRef("t"), true),
        ]
        for (sql, dialect, kind, name, quoted) in cases {
            let head = try #require(DefinitionHead.parse(sql, dialect: dialect), "\(sql)")
            #expect(head.kind == kind, "\(sql)")
            #expect(head.name == name, "\(sql)")
            #expect(head.isQuoted == quoted, "\(sql)")
        }
        #expect(DefinitionHead.parse("CREATE TABLE t (a int)", dialect: .postgres) == nil)
        #expect(DefinitionHead.parse("SELECT 1", dialect: .postgres) == nil)
        #expect(DefinitionHead.parse("CREATE INDEX i ON t (a)", dialect: .postgres) == nil)
    }

    @Test func comparesNamesLikeTheDatabase() throws {
        let plain = try #require(DefinitionHead.parse("CREATE VIEW People AS SELECT 1", dialect: .postgres))
        #expect(plain.names("people") && plain.names("PEOPLE"))
        let quoted = try #require(DefinitionHead.parse("CREATE VIEW \"People\" AS SELECT 1", dialect: .postgres))
        #expect(quoted.names("People") && !quoted.names("people"))
    }

    @Test func insertsOrReplaceOnce() throws {
        let sql = "CREATE  VIEW v AS SELECT 1"
        let head = try #require(DefinitionHead.parse(sql, dialect: .postgres))
        #expect(DefinitionText.orReplace(sql, head) == "CREATE OR REPLACE  VIEW v AS SELECT 1")
        let again = "CREATE OR REPLACE VIEW v AS SELECT 1"
        #expect(DefinitionText.orReplace(again, DefinitionHead.parse(again, dialect: .postgres)!) == again)
        let mysql = "CREATE DEFINER=`u`@`%` VIEW `v` AS select 1"
        #expect(DefinitionText.orReplace(mysql, DefinitionHead.parse(mysql, dialect: .mysql)!)
                == "CREATE OR REPLACE DEFINER=`u`@`%` VIEW `v` AS select 1")
    }

    @Test func renamesOnlyTheHead() throws {
        let sql = "CREATE FUNCTION `db`.`f`() RETURNS INT DETERMINISTIC RETURN f2()"
        let head = try #require(DefinitionHead.parse(sql, dialect: .mysql))
        #expect(DefinitionText.renaming(sql, head, to: "g", quote: my.quoteIdentifier)
                == "CREATE FUNCTION `db`.`g`() RETURNS INT DETERMINISTIC RETURN f2()")
        let table = "CREATE TABLE \"tags\" (\"tags\" TEXT, id INTEGER PRIMARY KEY)"
        #expect(DefinitionText.renamingCreate(table, dialect: .sqlite, to: "tags_copy", quote: sqlite.quoteIdentifier)
                == "CREATE TABLE \"tags_copy\" (\"tags\" TEXT, id INTEGER PRIMARY KEY)")
        let index = "CREATE UNIQUE INDEX IF NOT EXISTS main.tags_name ON tags (tags COLLATE NOCASE)"
        #expect(DefinitionText.renamingCreate(index, dialect: .sqlite, to: "tags_copy_name", onTable: "tags_copy",
                                              quote: sqlite.quoteIdentifier)
                == "CREATE UNIQUE INDEX IF NOT EXISTS main.\"tags_copy_name\" ON \"tags_copy\" (tags COLLATE NOCASE)")
    }

    @Test func splitsDefinitions() {
        // MySQL: one statement unless DELIMITER says otherwise; the final ';' goes.
        let body = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\n-- done\n"
        #expect(DefinitionText.statements(body, dialect: .mysql) == ["CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND"])
        let delimited = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\n"
        #expect(DefinitionText.statements(delimited, dialect: .mysql) == ["CREATE PROCEDURE p() BEGIN SELECT 1; END"])
        // Postgres: $$ bodies and several statements.
        let pgText = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nCOMMENT ON FUNCTION f() IS 'x';"
        #expect(DefinitionText.statements(pgText, dialect: .postgres).count == 2)
        #expect(DefinitionText.statements("  \n-- nothing\n", dialect: .mysql).isEmpty)
    }
}

@Suite struct DefinitionPlanTests {
    @Test func postgresReplacesViewsAndRoutinesInPlace() throws {
        let view = DefinedObject(kind: .view, ref: TableRef(schema: "public", "v"))
        let plan = try pg.definitionPlan(replacing: view, kind: .view, text: "CREATE VIEW public.v AS\nSELECT 2;")
        #expect(plan.statements == ["CREATE OR REPLACE VIEW public.v AS\nSELECT 2"])
        #expect(plan.isAtomic)

        let f = DefinedObject(kind: .function, ref: TableRef(schema: "public", "f"), signature: "a integer")
        let text = "CREATE OR REPLACE FUNCTION public.f(a integer) RETURNS integer LANGUAGE sql AS $$ SELECT a; $$;"
        #expect(try pg.definitionPlan(replacing: f, kind: .function, text: text).statements == [String(text.dropLast())])
        // Another name: the old one goes first.
        let renamed = try pg.definitionPlan(replacing: f, kind: .function, text: text.replacingOccurrences(of: "public.f(", with: "public.g("))
        #expect(renamed.statements.first == "DROP FUNCTION \"public\".\"f\"(a integer)")
        #expect(renamed.statements.count == 2)
    }

    @Test func postgresDropsMaterializedViewsAndTriggersFirst() throws {
        let mv = DefinedObject(kind: .materializedView, ref: TableRef(schema: "s", "mv"))
        let plan = try pg.definitionPlan(
            replacing: mv, kind: .materializedView,
            text: "CREATE MATERIALIZED VIEW s.mv AS SELECT 1 AS a WITH DATA;\n\nCREATE INDEX mv_a ON s.mv USING btree (a);")
        #expect(plan.statements == [
            "DROP MATERIALIZED VIEW \"s\".\"mv\"", "CREATE MATERIALIZED VIEW s.mv AS SELECT 1 AS a WITH DATA",
            "CREATE INDEX mv_a ON s.mv USING btree (a)",
        ])
        let t = DefinedObject.trigger("touch", on: TableRef(schema: "s", "items"))
        let trigger = try pg.definitionPlan(
            replacing: t, kind: .trigger, text: "CREATE TRIGGER touch BEFORE UPDATE ON s.items FOR EACH ROW EXECUTE FUNCTION f()")
        #expect(trigger.statements.first == "DROP TRIGGER \"touch\" ON \"s\".\"items\"")
    }

    @Test func mysqlChecksRoutinesUnderAScratchName() throws {
        let p = DefinedObject(kind: .procedure, ref: TableRef("p"))
        let text = "CREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN\n  SELECT 2;\nEND;"
        let plan = try my.definitionPlan(replacing: p, kind: .procedure, text: text)
        #expect(plan.statements == [
            "CREATE DEFINER=`root`@`%` PROCEDURE `tabula_check_p`()\nBEGIN\n  SELECT 2;\nEND",
            "DROP PROCEDURE `tabula_check_p`",
            "DROP PROCEDURE `p`",
            "CREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN\n  SELECT 2;\nEND",
        ])
        #expect(!plan.isAtomic && !plan.notes.isEmpty)

        let view = DefinedObject(kind: .view, ref: TableRef("v"))
        #expect(try my.definitionPlan(replacing: view, kind: .view, text: "CREATE VIEW `v` AS select 1").statements
                == ["CREATE OR REPLACE VIEW `v` AS select 1"])
        let trigger = try my.definitionPlan(
            replacing: .trigger("t", on: TableRef("items")), kind: .trigger,
            text: "CREATE TRIGGER `t` BEFORE INSERT ON `items` FOR EACH ROW SET NEW.qty = 1")
        #expect(trigger.statements.first == "DROP TRIGGER `t`")
        #expect(!trigger.notes.isEmpty)
        #expect(throws: DatabaseError.self) { try my.definitionPlan(replacing: nil, kind: .materializedView, text: "x") }
    }

    @Test func sqliteDropsAndCreatesInOneTransaction() throws {
        let view = DefinedObject(kind: .view, ref: TableRef("v"))
        let plan = try sqlite.definitionPlan(
            replacing: view, kind: .view,
            text: "CREATE VIEW v AS SELECT 2;\nCREATE TRIGGER v_ins INSTEAD OF INSERT ON v BEGIN SELECT 1; END;")
        #expect(plan.statements == [
            "DROP VIEW \"v\"", "CREATE VIEW v AS SELECT 2", "CREATE TRIGGER v_ins INSTEAD OF INSERT ON v BEGIN SELECT 1; END",
        ])
        #expect(plan.isAtomic)
        #expect(throws: DatabaseError.self) { try sqlite.definitionPlan(replacing: nil, kind: .function, text: "x") }
    }

    @Test func newObjectsRunAsWritten() throws {
        let plan = try pg.definitionPlan(replacing: nil, kind: .view, text: "CREATE VIEW n AS SELECT 1;\n")
        #expect(plan.statements == ["CREATE VIEW n AS SELECT 1"])
        #expect(throws: DatabaseError.self) { try pg.definitionPlan(replacing: nil, kind: .view, text: "  ") }
        // An existing object needs its CREATE in the text.
        #expect(throws: DatabaseError.self) {
            try pg.definitionPlan(replacing: DefinedObject(kind: .view, ref: TableRef("v")), kind: .view, text: "SELECT 1")
        }
    }

    @Test func routinesDropByKindAndSignature() throws {
        let f = DatabaseObject(TableRef(schema: "s", "f"), kind: .function, signature: "integer, text")
        #expect(try pg.drop(f, options: DropOptions()).statements == ["DROP FUNCTION \"s\".\"f\"(integer, text)"])
        let p = DatabaseObject(TableRef(schema: "s", "p"), kind: .procedure, signature: "")
        #expect(try pg.drop(p, options: DropOptions(cascade: true)).statements == ["DROP PROCEDURE \"s\".\"p\"() CASCADE"])
        #expect(try my.drop(DatabaseObject(TableRef("p"), kind: .procedure), options: DropOptions()).statements == ["DROP PROCEDURE `p`"])
        #expect(throws: DatabaseError.self) { try pg.rename(f, to: "g") }
    }
}

@Suite struct ClonePlanTests {
    private func structure(_ dialect: any Dialect, definition: String? = nil) -> TableStructure {
        TableStructure(
            table: TableRef(schema: dialect is SQLiteDialect ? nil : "s", "people"),
            columns: [
                ColumnInfo(name: "id", typeName: "integer", isNullable: false, primaryKeyPosition: 1, isAutoIncrement: true,
                           generated: dialect is PostgresDialect ? "GENERATED ALWAYS AS IDENTITY" : nil),
                ColumnInfo(name: "name", typeName: "text"),
                ColumnInfo(name: "upper_name", typeName: "text", generated: "GENERATED ALWAYS AS (upper(name)) STORED"),
            ],
            indexes: [
                IndexInfo(name: "people_pkey", columns: ["id"], isUnique: true, isPrimary: true),
                IndexInfo(name: "people_name", columns: ["name"], definition: "CREATE INDEX people_name ON people (name)"),
                IndexInfo(name: "by_name", columns: ["name"], definition: "CREATE INDEX \"by_name\" ON \"people\" (\"name\")"),
            ],
            definition: definition)
    }

    @Test func postgresClone() throws {
        let plan = try pg.clone(structure(pg), as: "people_copy", withData: true)
        #expect(plan.statements == [
            "CREATE TABLE \"s\".\"people_copy\" (LIKE \"s\".\"people\" INCLUDING ALL)",
            "INSERT INTO \"s\".\"people_copy\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE SELECT \"id\", \"name\" FROM \"s\".\"people\"",
            "SELECT setval(pg_get_serial_sequence('\"s\".\"people_copy\"', 'id'), max(\"id\")) FROM \"s\".\"people_copy\"",
        ])
        #expect(try pg.clone(structure(pg), as: "people_copy", withData: false).statements.count == 1)
    }

    @Test func mysqlClone() throws {
        let plan = try my.clone(structure(my), as: "people_copy", withData: true)
        #expect(plan.statements == [
            "CREATE TABLE `s`.`people_copy` LIKE `s`.`people`",
            "INSERT INTO `s`.`people_copy` (`id`, `name`) SELECT `id`, `name` FROM `s`.`people`",
        ])
    }

    @Test func sqliteClone() throws {
        let create = "CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, upper_name TEXT GENERATED ALWAYS AS (upper(name)) STORED)"
        let plan = try sqlite.clone(structure(sqlite, definition: create), as: "people_copy", withData: true)
        #expect(plan.statements == [
            "CREATE TABLE \"people_copy\" (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, upper_name TEXT GENERATED ALWAYS AS (upper(name)) STORED)",
            "INSERT INTO \"people_copy\" (\"id\", \"name\") SELECT \"id\", \"name\" FROM \"people\"",
            "CREATE INDEX \"people_copy_name\" ON \"people_copy\" (name)",
            "CREATE INDEX \"people_copy_by_name\" ON \"people_copy\" (\"name\")",
        ])
        #expect(throws: DatabaseError.self) { try sqlite.clone(structure(sqlite), as: "x", withData: false) }
    }
}
