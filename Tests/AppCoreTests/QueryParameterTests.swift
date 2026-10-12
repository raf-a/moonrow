import AppCore
import DBKit
import SQLScript
import Testing

@Suite struct QueryParameterTests {
    private func keys(_ sql: String, _ dialect: any Dialect) -> [String] {
        QueryParameters.find(in: [sql], dialect: dialect.lexer, styles: QueryParameters.styles(for: dialect)).keys
    }

    @Test func stylesPerDatabase() {
        #expect(QueryParameters.styles(for: PostgresDialect()) == [.named, .numbered])
        #expect(QueryParameters.styles(for: MySQLDialect()) == [.named, .positional])
        #expect(QueryParameters.styles(for: SQLiteDialect()) == [.named, .positional])
    }

    @Test func findsNamedNumberedAndPositional() {
        #expect(keys("SELECT * FROM t WHERE a = :id AND b IN (:id, :other_1)", SQLiteDialect()) == [":id", ":other_1"])
        #expect(keys("SELECT $1, $2, $1", PostgresDialect()) == ["$1", "$2"])
        #expect(keys("SELECT ?, ? FROM t WHERE x = :x", MySQLDialect()) == ["?1", "?2", ":x"])
        // Postgres's ? is jsonb's operator; MySQL and SQLite have no $1.
        #expect(keys("SELECT data ? 'k', data ?| array['a'] FROM t", PostgresDialect()).isEmpty)
        #expect(keys("SELECT $1", MySQLDialect()).isEmpty)
    }

    @Test func leavesCastsSlicesStringsAndCommentsAlone() {
        let pg = PostgresDialect()
        #expect(keys("SELECT x::int, a[1:n], (b):text, '00:00:id', \"c:d\" FROM t -- :nope", pg).isEmpty)
        #expect(keys("SELECT $$ :in_body $1 $$ /* :c */", pg).isEmpty)
        #expect(keys("SELECT @v := 1, `a:b`", MySQLDialect()).isEmpty)
        #expect(keys("SELECT 1 WHERE a=:x", pg) == [":x"])
        #expect(keys("SELECT :select", pg) == [":select"])
    }

    @Test func positionalOnesAreNumberedAcrossStatements() {
        let found = QueryParameters.find(in: ["SELECT ?", "SELECT ?, :a"], dialect: .sqlite, styles: [.named, .positional])
        #expect(found.keys == ["?1", "?2", ":a"])
        #expect(found.occurrences.map(\.statement) == [0, 1, 1])
    }

    @Test func valuesBecomeSQL() {
        let d = PostgresDialect()
        #expect(QueryParameters.sql(for: "42", kind: .auto, dialect: d) == "42")
        #expect(QueryParameters.sql(for: "-1.5e3", kind: .auto, dialect: d) == "-1.5e3")
        #expect(QueryParameters.sql(for: "null", kind: .auto, dialect: d) == "NULL")
        #expect(QueryParameters.sql(for: "O'Brien", kind: .auto, dialect: d) == "'O''Brien'")
        #expect(QueryParameters.sql(for: "42", kind: .text, dialect: d) == "'42'")
        #expect(QueryParameters.sql(for: "now()", kind: .sql, dialect: d) == "now()")
        #expect(QueryParameters.sql(for: "", kind: .auto, dialect: d) == "''")
        #expect(QueryParameters.sql(for: "it's", kind: .auto, dialect: MySQLDialect()) == #"'it\'s'"#)
    }

    @Test func substitutesEveryOccurrence() {
        let statements = ["SELECT * FROM t WHERE a = :id OR b = :id", "SELECT ?, 'é' || :id"]
        let found = QueryParameters.find(in: statements, dialect: .sqlite, styles: [.named, .positional])
        let out = QueryParameters.substitute(statements, found.occurrences, values: [":id": "7", "?1": "'x'"])
        #expect(out == ["SELECT * FROM t WHERE a = 7 OR b = 7", "SELECT 'x', 'é' || 7"])
        // A key without a value stays.
        #expect(QueryParameters.substitute(statements, found.occurrences, values: [:]) == statements)
    }
}
