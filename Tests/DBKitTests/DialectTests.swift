import Foundation
import Testing
@testable import DBKit

private let sqlite = SQLiteDialect()
private let pg = PostgresDialect()
private let my = MySQLDialect()

@Suite struct QuotingTests {
    @Test func identifiers() {
        #expect(sqlite.quoteIdentifier(#"a"b"#) == #""a""b""#)
        #expect(my.quoteIdentifier("a`b") == "`a``b`")
        #expect(pg.qualified(TableRef(schema: "public", "users")) == #""public"."users""#)
    }

    @Test func literals() {
        #expect(pg.literal(.text("it's")) == "'it''s'")
        #expect(my.literal(.text(#"a\b"#)) == #"'a\\b'"#)
        #expect(pg.literal(.blob(Data([0xDE, 0xAD]))) == #"'\xDEAD'::bytea"#)
        #expect(sqlite.literal(.blob(Data([1]))) == "X'01'")
        #expect(sqlite.literal(.bool(true)) == "1")
        #expect(pg.literal(.bool(false)) == "FALSE")
        #expect(pg.literal(.null) == "NULL")
    }

    @Test func placeholders() {
        let f = "a = " + SQLFragment.value(.integer(1)) + " AND b = " + .value(.text("x"))
        #expect(f.statement(for: pg) == SQLStatement("a = $1 AND b = $2", bindings: [.integer(1), .text("x")]))
        #expect(f.statement(for: my).sql == "a = ? AND b = ?")
        #expect(f.inlined(for: pg) == "a = 1 AND b = 'x'")
    }
}

@Suite struct FilterTests {
    func render(_ d: any Dialect, _ c: FilterCondition, columns: [String] = ["a", "b"]) -> String {
        d.predicate(for: Filter([c]), columns: columns)!.inlined(for: d)
    }

    @Test func comparisons() {
        #expect(render(pg, .init(.column("age"), .greaterOrEqual, "18")) == #""age" >= '18'"#)
        #expect(render(pg, .init(.column("id"), .in, "1, 2,,3")) == #""id" IN ('1', '2', '3')"#)
        #expect(render(pg, .init(.column("id"), .in, " ")) == "1 = 0")
        #expect(render(pg, .init(.column("n"), .between, "1", "100")) == #""n" BETWEEN '1' AND '100'"#)
        #expect(render(pg, .init(.column("n"), .isNull)) == #""n" IS NULL"#)
        #expect(render(pg, .init(.column("n"), .isEmpty)) == #""n"::text = ''"#)
    }

    @Test func containsPerDialect() {
        let ci = FilterCondition(.column("name"), .contains, "50%_off")
        #expect(render(pg, ci) == #""name"::text ILIKE '%50\%\_off%'"#)
        #expect(render(my, ci) == #"LOWER(CAST(`name` AS CHAR)) LIKE LOWER('%50\\%\\_off%')"#)
        #expect(render(sqlite, ci) == #"CAST("name" AS TEXT) LIKE '%50\%\_off%' ESCAPE '\'"#)

        let cs = FilterCondition(.column("name"), .hasPrefix, "A*", caseSensitive: true)
        #expect(render(pg, cs) == #""name"::text LIKE 'A*%'"#)
        #expect(render(sqlite, cs) == #"CAST("name" AS TEXT) GLOB 'A[*]*'"#)
        #expect(render(my, cs) == "CAST(CAST(`name` AS CHAR) AS BINARY) LIKE CAST('A*%' AS BINARY)")

        let not = FilterCondition(.column("name"), .notContains, "x")
        #expect(render(pg, not) == #""name"::text NOT ILIKE '%x%'"#)
    }

    @Test func anyColumn() {
        let c = FilterCondition(.anyColumn, .contains, "x")
        #expect(render(pg, c) == #"("a"::text ILIKE '%x%' OR "b"::text ILIKE '%x%')"#)
        let n = FilterCondition(.anyColumn, .notContains, "x")
        #expect(render(pg, n) == #"("a"::text NOT ILIKE '%x%' AND "b"::text NOT ILIKE '%x%')"#)
    }

    @Test func combined() {
        let f = Filter([
            .init(.column("a"), .equal, "1"),
            .init(.column("b"), .raw, "b > 2"),
            .init(.column("c"), .raw, "  "),
        ], matchAll: false)
        #expect(pg.predicate(for: f, columns: [])!.inlined(for: pg) == #"("a" = '1') OR (b > 2)"#)
    }
}

@Suite struct BuilderTests {
    let users = TableRef("users")

    @Test func select() {
        let r = BrowseRequest(
            users, filter: Filter([.init(.column("active"), .equal, "1")]),
            sort: [SortKey("name"), SortKey("id", ascending: false)], limit: 300, offset: 600)
        #expect(pg.select(r, allColumns: []).statement(for: pg).sql
                == #"SELECT * FROM "users" WHERE "active" = $1 ORDER BY "name" ASC, "id" DESC LIMIT 300 OFFSET 600"#)
        #expect(my.count(users, allColumns: []).inlined(for: my) == "SELECT COUNT(*) FROM `users`")
    }

    @Test func changeSetOrderAndShape() {
        let cs = ChangeSet(
            users,
            updates: [RowUpdate(key: [.init("id", .integer(1))], changes: [.init("name", .text("Ann"))]),
                      RowUpdate(key: [.init("id", .integer(9))], changes: [])],
            inserts: [[.init("name", .text("Bo"))], []],
            deletes: [[.init("id", .integer(2)), .init("org", .null)]])
        let sql = pg.statements(for: cs).map { $0.inlined(for: pg) }
        #expect(sql == [
            #"DELETE FROM "users" WHERE "id" = 2 AND "org" IS NULL"#,
            #"UPDATE "users" SET "name" = 'Ann' WHERE "id" = 1"#,
            #"INSERT INTO "users" ("name") VALUES ('Bo')"#,
            #"INSERT INTO "users" DEFAULT VALUES"#,
        ])
        #expect(my.insert(into: users, []).inlined(for: my) == "INSERT INTO `users` () VALUES ()")
    }

    @Test func defaultValues() {
        let update = RowUpdate(key: [.init("id", .integer(1))], changes: [.expression("n", "DEFAULT")])
        #expect(pg.update(users, update).statement(for: pg) == SQLStatement(#"UPDATE "users" SET "n" = DEFAULT WHERE "id" = $1"#, bindings: [.integer(1)]))
        func column(_ d: String?) -> ColumnInfo { ColumnInfo(name: "n", typeName: "", defaultExpression: d) }
        #expect(my.defaultValue(for: column("5")) == "DEFAULT")
        // SQLite can't SET x = DEFAULT, so the declared default is written out.
        #expect(sqlite.defaultValue(for: column(nil)) == "NULL")
        #expect(sqlite.defaultValue(for: column("CURRENT_TIMESTAMP")) == "CURRENT_TIMESTAMP")
        #expect(sqlite.defaultValue(for: column("'a' || 'b'")) == "('a' || 'b')")
        #expect(sqlite.defaultValue(for: column("(random())")) == "(random())")
    }
}
