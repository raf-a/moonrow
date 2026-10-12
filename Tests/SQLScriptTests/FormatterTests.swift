import Testing
@testable import SQLScript

private func format(_ sql: String, _ d: LexerDialect = .postgres,
                    _ options: SQLFormatter.Options = .init()) -> String {
    SQLFormatter.format(sql, dialect: d, options: options)
}

/// Non-whitespace tokens as "kind text", keywords upper-cased. With `looseComments`, comments
/// compare by their text without delimiters (compact turns `-- x` into `/* x */`).
private func tokens(_ sql: String, _ d: LexerDialect, looseComments: Bool = false) -> [String] {
    let lexer = SQLLexer(sql, dialect: d)
    return lexer.tokens().compactMap { t -> String? in
        var text = lexer.text(t.range)
        switch t.kind {
        case .whitespace:
            return nil
        case .keyword:
            return "keyword \(text.uppercased())"
        case .lineComment, .blockComment:
            guard looseComments else { return "\(t.kind) \(text)" }
            if text.hasPrefix("--") { text.removeFirst(2) }
            else if text.hasPrefix("#") { text.removeFirst() }
            else { text = String(text.dropFirst(2).dropLast(2)) }
            return "comment \(SQLFormatter.trimmed(text))"
        default:
            return "\(t.kind) \(text)"
        }
    }
}

/// Every line comment in the output is followed by a line break (or ends the text).
private func lineCommentsEndLines(_ sql: String, _ d: LexerDialect) -> Bool {
    let lexer = SQLLexer(sql, dialect: d)
    let toks = lexer.tokens()
    for (i, t) in toks.enumerated() where t.kind == .lineComment && i + 1 < toks.count {
        let next = toks[i + 1]
        if next.kind != .whitespace || !lexer.units[next.range].contains(10) { return false }
    }
    return true
}

private let dialects: [LexerDialect] = [.sqlite, .postgres, .mysql]

/// Inputs that try to trip the formatter up.
private let tricky: [String] = [
    "select '--not a comment; really', 'a;b' from t where x = 'y -- z'",
    "select $$;$$, $body$ begin; return 1; end $body$ from t",
    #"select E'\'' as q, 'it''s' from t"#,
    #"select 'a\';b', `weird``name`, `select` from `t` # trailing ; note"#,
    "/* outer /* inner; */ still; */ select 1",
    "select x::text, x::int[], arr[1:2], -1, a - -1, a-1, a=-1, a*-1, -(a+b), - -1 from t",
    "select json ->> 'k', j#>'{a,b}', j ? 'k', j ?| array['a'], j @> '{}' from t",
    "select * from t where a = ? and b = $1 and c = :name and d=:other and e = @v and f=@@w",
    "select a -- comment one\n, b -- two\nfrom t -- three\nwhere c /* inline */ = 1 -- four",
    "select 1 # hash; comment\n; select 2 -- dash\n",
    "SELECT CASE WHEN a THEN (SELECT 1) ELSE -1 END, count(*) FILTER (WHERE x) OVER (PARTITION BY y ORDER BY z) FROM t",
    "insert into t(a,b) values (1,'x'),(2,'y') on conflict (a) do update set b = excluded.b returning *",
    "update t set a=a+1, b=default where c in (select c from u) and d between 1 and 2",
    "with recursive r(n) as (select 1 union all select n+1 from r where n<5) select * from r",
    "create table t (id int primary key, name varchar(255) default 'x;y', check (id > -1)); drop table t",
    "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nSELECT 3;",
    "CREATE TRIGGER tr AFTER INSERT ON a BEGIN\n  UPDATE b SET n = n + 1;\n  DELETE FROM c;\nEND;\nSELECT 1;",
    "select 1;; -- orphan\n/* tail */",
    "select a from t1 natural left outer join t2 using (id) cross join t3 straight_join t4 on x",
    "select 1.5e-3, .5, 1., x.y.z, \"Mixed Case\".\"Col\", [bracket name] from t",
    "select a from t where a is distinct from b or not exists(select 1) limit 5, 10",
    "select 'unterminated",
    "select (((1))) as x, f()",
    "select 1 union select 2 intersect select 3 except all select 4 order by 1 desc",
]

/// Formatted fixtures from the tests below, for idempotence.
private let fixtures: [(String, LexerDialect)] = [
    (selectSQL, .postgres), (selectSQL, .mysql), (selectSQL, .sqlite),
    ("insert into users (id, name) values (1, 'a'), (2, 'b');", .postgres),
    ("update users set name = 'x', age = age + 1 where id = 1", .sqlite),
    (cteSQL, .postgres), (caseSQL, .postgres),
] + dialects.flatMap { d in tricky.map { ($0, d) } }

private let selectSQL = """
    select u.id, u.name, count(o.id) as n from users u left join orders o on o.user_id = u.id and o.total > 0
    inner join teams t on t.id = u.team_id where u.active = true and u.name like 'a%' or u.age between 18 and 65
    group by u.id, u.name having count(o.id) > 1 order by n desc, u.name limit 10 offset 20
    """

private let selectExpected = """
    SELECT
        u.id,
        u.name,
        count(o.id) AS n
    FROM
        users u
        LEFT JOIN orders o ON o.user_id = u.id
            AND o.total > 0
        INNER JOIN teams t ON t.id = u.team_id
    WHERE
        u.active = TRUE
        AND u.name LIKE 'a%'
        OR u.age BETWEEN 18 AND 65
    GROUP BY
        u.id,
        u.name
    HAVING
        count(o.id) > 1
    ORDER BY
        n DESC,
        u.name
    LIMIT 10
    OFFSET 20
    """

private let cteSQL = """
    with recent as (select user_id, sum(total) as spent from orders where created_at > now() - interval '7 days' group by user_id)
    select u.name, r.spent from users u join recent r on r.user_id = u.id where r.spent > (select avg(spent) from recent)
    """

private let caseSQL = """
    select id, case when total > 100 then 'big' when total > 10 then 'medium' else 'small' end as size,
    case status when 1 then 'open' else 'closed' end from orders
    """

@Suite struct FormatterTests {
    // MARK: Layout

    @Test func selectPostgres() {
        #expect(format(selectSQL) == selectExpected)
    }

    @Test func selectMySQL() {
        let sql = "select `id`, `name` from `users` u join `teams` t on t.id = u.team_id where `name` like 'a\\'b' # who\norder by `id` limit 5, 10"
        #expect(format(sql, .mysql) == """
            SELECT
                `id`,
                `name`
            FROM
                `users` u
                JOIN `teams` t ON t.id = u.team_id
            WHERE
                `name` LIKE 'a\\'b' # who
            ORDER BY
                `id`
            LIMIT 5, 10
            """)
        #expect(format(selectSQL, .mysql) == selectExpected)
    }

    @Test func selectSQLite() {
        let sql = "select [id], \"name\" from users cross join [my table] as m where m.x in (1,2,3) and rowid > ?"
        #expect(format(sql, .sqlite) == """
            SELECT
                [id],
                "name"
            FROM
                users
                CROSS JOIN [my table] AS m
            WHERE
                m.x IN (1, 2, 3)
                AND rowid > ?
            """)
        #expect(format(selectSQL, .sqlite) == selectExpected)
    }

    @Test func insertValues() {
        #expect(format("insert into users (id, name) values (1, 'a'), (2, 'b') returning id;") == """
            INSERT INTO users (id, name)
            VALUES
                (1, 'a'),
                (2, 'b')
            RETURNING
                id;
            """)
        #expect(format("insert into t(a) values(1) on conflict (a) do update set a = excluded.a") == """
            INSERT INTO t (a)
            VALUES
                (1)
            ON conflict (a) do UPDATE
            SET
                a = excluded.a
            """)
        #expect(format("insert into t (a) values (1) on duplicate key update a = values(a), b = 2", .mysql) == """
            INSERT INTO t (a)
            VALUES
                (1)
            ON duplicate KEY UPDATE
                a = VALUES(a),
                b = 2
            """)
    }

    @Test func updateSetWhere() {
        #expect(format("update users set name = 'x', age = age+1 where id = -1", .sqlite) == """
            UPDATE users
            SET
                name = 'x',
                age = age + 1
            WHERE
                id = -1
            """)
    }

    @Test func delete() {
        #expect(format("delete from users where id = :id and team_id is null", .sqlite) == """
            DELETE FROM users
            WHERE
                id = :id
                AND team_id IS NULL
            """)
    }

    @Test func cteWithSubquery() {
        #expect(format(cteSQL) == """
            WITH
                recent AS (
                    SELECT
                        user_id,
                        sum(total) AS spent
                    FROM
                        orders
                    WHERE
                        created_at > now() - interval '7 days'
                    GROUP BY
                        user_id
                )
            SELECT
                u.name,
                r.spent
            FROM
                users u
                JOIN recent r ON r.user_id = u.id
            WHERE
                r.spent > (
                    SELECT
                        avg(spent)
                    FROM
                        recent
                )
            """)
    }

    @Test func subqueryInFromAndSetOperations() {
        #expect(format("select * from (select a from t) as s union all select 1") == """
            SELECT
                *
            FROM
                (
                    SELECT
                        a
                    FROM
                        t
                ) AS s
            UNION ALL
            SELECT
                1
            """)
    }

    @Test func caseExpression() {
        #expect(format(caseSQL) == """
            SELECT
                id,
                CASE
                    WHEN total > 100 THEN 'big'
                    WHEN total > 10 THEN 'medium'
                    ELSE 'small'
                END AS size,
                CASE status
                    WHEN 1 THEN 'open'
                    ELSE 'closed'
                END
            FROM
                orders
            """)
    }

    @Test func createTableColumnsOnePerLine() {
        let sql = "create table if not exists users (id integer primary key, name varchar(255) not null, check (length(name) > 0));"
        #expect(format(sql, .sqlite) == """
            CREATE TABLE IF NOT EXISTS users (
                id integer PRIMARY KEY,
                name varchar(255) NOT NULL,
                CHECK (length(name) > 0)
            );
            """)
    }

    @Test func unmodeledStatementsGetSpacingOnly() {
        #expect(format("alter   table t\n  add column c int default -1") == "ALTER TABLE t ADD COLUMN c int DEFAULT -1")
        #expect(format("SET search_path = public,pg_catalog") == "SET search_path = public, pg_catalog")
        #expect(format("create view v as select a from t") == """
            CREATE VIEW v AS
            SELECT
                a
            FROM
                t
            """)
    }

    @Test func operatorsAndCasts() {
        let sql = "select x::text, x::int[], arr[1:2], a-1, a - -1, a=-1, -(a+b), json->>'k', j #> '{a}', a<>b, a>=b from t"
        #expect(format(sql) == """
            SELECT
                x::text,
                x::int[],
                arr[1:2],
                a - 1,
                a - -1,
                a = -1,
                -(a + b),
                json ->> 'k',
                j #> '{a}',
                a <> b,
                a >= b
            FROM
                t
            """)
        // Named parameters and variables stay attached to their prefix.
        #expect(format("select * from t where a=:a and b = @b and c = $1 and d = ?", .mysql) == """
            SELECT
                *
            FROM
                t
            WHERE
                a=:a
                AND b = @b
                AND c = $1
                AND d = ?
            """)
        #expect(format("CREATE USER 'u'@'localhost'", .mysql) == "CREATE USER 'u'@'localhost'")
    }

    // MARK: Statements and comments

    @Test func statementsSeparatedByBlankLine() {
        #expect(format("select 1;select 2;\n\n\nselect 3") == "SELECT\n    1;\n\nSELECT\n    2;\n\nSELECT\n    3")
        #expect(format("select 1;\n") == "SELECT\n    1;\n")
    }

    @Test func commentsKeptAndNeverSwallowCode() {
        let sql = "-- header\nselect a, -- first\n b /* inline */ from t -- trailing\nwhere x = 1 -- last\n; select 2"
        let out = format(sql)
        #expect(out == """
            -- header
            SELECT
                a, -- first
                b /* inline */
            FROM
                t -- trailing
            WHERE
                x = 1 -- last
            ;

            SELECT
                2
            """)
        #expect(lineCommentsEndLines(out, .postgres))
        #expect(tokens(out, .postgres) == tokens(sql, .postgres))
        // Own-line comments keep their own line.
        #expect(format("select a\n-- note\n, b from t") == "SELECT\n    a\n    -- note\n    ,\n    b\nFROM\n    t")
    }

    @Test func textBetweenStatementsIsKept() {
        #expect(format("select 1; -- trailing\n;; /* nothing */") == "SELECT\n    1;\n\n-- trailing\n;; /* nothing */")
        let mysql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nselect 3;"
        #expect(format(mysql, .mysql) == """
            DELIMITER //

            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//

            DELIMITER ;

            SELECT
                3;
            """)
    }

    @Test func statementsWithInnerSemicolonsKeepTheirLines() {
        let sql = "create trigger t after insert on a begin\n  update b set n = n  +  1;\n  delete from c;\nend;\nselect 1;"
        #expect(format(sql, .sqlite) == """
            CREATE TRIGGER t after INSERT ON a BEGIN
              UPDATE b SET n = n + 1;
              DELETE FROM c;
            END;

            SELECT
                1;
            """)
    }

    // MARK: Case and options

    @Test func keywordCaseLeavesNamesAlone() {
        let sql = #"select "Select", `From`, MyCol, count(*) from "Users" where Name = 'select'"#
        #expect(format(sql, .sqlite) == """
            SELECT
                "Select",
                `From`,
                MyCol,
                count(*)
            FROM
                "Users"
            WHERE
                Name = 'select'
            """)
        let lower = SQLFormatter.Options(indent: "\t", uppercaseKeywords: false)
        #expect(format("SELECT a, b From t", .postgres, lower) == "SELECT\n\ta,\n\tb\nFrom\n\tt")
        #expect(format("select a from t", .postgres, lower) == "select\n\ta\nfrom\n\tt")
    }

    @Test func emptyAndWhitespaceOnly() {
        for d in dialects {
            #expect(SQLFormatter.format("", dialect: d) == "")
            #expect(SQLFormatter.format("  \n\t ", dialect: d) == "  \n\t ")
            #expect(SQLFormatter.compact("", dialect: d) == "")
            #expect(SQLFormatter.compact(" \n ", dialect: d) == " \n ")
        }
        #expect(format("-- just a note") == "-- just a note")
    }

    // MARK: Compact

    @Test func compactScript() {
        let sql = """
            -- list users
            select id,
                   name   -- the name
            from users
            where id = 1 ;

            /* second */
            update users
            set name = 'a  b'
            where id = 2
            """
        #expect(SQLFormatter.compact(sql, dialect: .postgres) ==
            "/* list users */ select id, name /* the name */ from users where id = 1; /* second */ update users set name = 'a  b' where id = 2")
    }

    @Test func compactKeepsUnsafeLineComments() {
        // `*/` would end the block comment early; PostgreSQL also nests `/*`.
        #expect(SQLFormatter.compact("select 1 -- a */ b\nfrom t", dialect: .postgres) == "select 1 -- a */ b\nfrom t")
        #expect(SQLFormatter.compact("select 1 -- a /* b\nfrom t", dialect: .postgres) == "select 1 -- a /* b\nfrom t")
        #expect(SQLFormatter.compact("select 1 -- a /* b\nfrom t", dialect: .sqlite) == "select 1 /* a /* b */ from t")
        #expect(SQLFormatter.compact("select 1 #!x\nfrom t", dialect: .mysql) == "select 1 /* !x */ from t")
    }

    @Test func compactKeepsDelimiterLines() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND//\nDELIMITER ;\nSELECT 2;"
        #expect(SQLFormatter.compact(sql, dialect: .mysql) ==
            "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2;")
    }

    // MARK: Properties

    @Test(arguments: dialects.indices)
    func formatPreservesTokens(_ d: Int) {
        let dialect = dialects[d]
        for sql in tricky + [selectSQL, cteSQL, caseSQL] {
            let out = SQLFormatter.format(sql, dialect: dialect)
            #expect(tokens(out, dialect) == tokens(sql, dialect), "\(sql)")
            #expect(lineCommentsEndLines(out, dialect), "\(sql)")
            #expect(SQLSplitter.split(out, dialect: dialect).count == SQLSplitter.split(sql, dialect: dialect).count,
                    "\(sql)")
        }
    }

    @Test(arguments: dialects.indices)
    func compactPreservesTokens(_ d: Int) {
        let dialect = dialects[d]
        for sql in tricky + [selectSQL, cteSQL, caseSQL] {
            let out = SQLFormatter.compact(sql, dialect: dialect)
            #expect(tokens(out, dialect, looseComments: true) == tokens(sql, dialect, looseComments: true), "\(sql)")
            #expect(lineCommentsEndLines(out, dialect), "\(sql)")
            #expect(SQLSplitter.split(out, dialect: dialect).count == SQLSplitter.split(sql, dialect: dialect).count,
                    "\(sql)")
            #expect(SQLFormatter.compact(out, dialect: dialect) == out, "\(sql)")
        }
    }

    @Test func formatIsIdempotent() {
        for (sql, dialect) in fixtures {
            let once = SQLFormatter.format(sql, dialect: dialect)
            #expect(SQLFormatter.format(once, dialect: dialect) == once, "\(sql)")
        }
    }

    @Test func formatUndoesCompact() {
        for (sql, dialect) in [(selectSQL, LexerDialect.postgres), (cteSQL, .postgres), (caseSQL, .postgres)] {
            let formatted = SQLFormatter.format(sql, dialect: dialect)
            #expect(SQLFormatter.format(SQLFormatter.compact(formatted, dialect: dialect), dialect: dialect) == formatted)
        }
    }
}
