import Testing
@testable import SQLScript

private func texts(_ sql: String, _ d: LexerDialect = .postgres) -> [String] {
    SQLSplitter.split(sql, dialect: d).map(\.text)
}

@Suite struct SplitterTests {
    @Test func basic() {
        #expect(texts("select 1; select 2;\n\nselect 3") == ["select 1", "select 2", "select 3"])
    }

    @Test func semicolonsInsideOpaqueTokens() {
        let sql = """
            select 'a;b', "c;d" from t; -- x; y
            /* z; */ select 2
            """
        #expect(texts(sql) == ["select 'a;b', \"c;d\" from t", "/* z; */ select 2"])
    }

    @Test func commentOnlySegmentsAreDropped() {
        #expect(texts("select 1; -- trailing\n;; /* nothing */") == ["select 1"])
    }

    @Test func doubledQuotesAndBackslashes() {
        #expect(texts("select 'it''s;'; select 2") == ["select 'it''s;'", "select 2"])
        // Backslash escapes only count in MySQL (or PG E'' strings).
        #expect(texts(#"select 'a\';b'; select 2"#, .mysql) == [#"select 'a\';b'"#, "select 2"])
        #expect(texts(#"select 'a\'; select 2"#, .postgres) == [#"select 'a\'"#, "select 2"])
        #expect(texts(#"select E'a\';b'; select 2"#, .postgres) == [#"select E'a\';b'"#, "select 2"])
    }

    @Test func postgresDollarQuotes() {
        let sql = """
            create function f() returns int as $body$ begin; return 1; end $body$ language plpgsql;
            select $$;$$, $1;
            """
        #expect(texts(sql).count == 2)
        #expect(texts(sql)[1] == "select $$;$$, $1")
    }

    @Test func nestedBlockComments() {
        #expect(texts("/* a /* b; */ c; */ select 1; select 2") == ["/* a /* b; */ c; */ select 1", "select 2"])
    }

    @Test func mysqlDelimiterCommand() {
        let sql = """
            DELIMITER //
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//
            DELIMITER ;
            SELECT 3;
            """
        #expect(texts(sql, .mysql) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "SELECT 3"])
    }

    @Test func mysqlHashComments() {
        #expect(texts("select 1 # a;b\n; select 2", .mysql) == ["select 1 # a;b", "select 2"])
    }

    @Test func sqliteTriggerBodies() {
        let sql = """
            CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN
              UPDATE b SET n = n + 1;
              DELETE FROM c;
            END;
            SELECT 1;
            """
        let parts = texts(sql, .sqlite)
        #expect(parts.count == 2)
        #expect(parts[0].hasSuffix("END"))
        #expect(parts[1] == "SELECT 1")
    }

    @Test func rangesAreUTF16() {
        let sql = "select '😀'; select 2"
        let s = SQLSplitter.split(sql, dialect: .postgres)
        #expect(s[0].range == 0..<11)   // the emoji is 2 UTF-16 units
        #expect(s[0].fullRange == 0..<12)
        #expect(s[1].range.lowerBound == 13)
    }

    @Test func currentStatement() {
        let sql = "select 1;  \nselect 2;\n\nselect 3"
        func at(_ i: Int) -> String? { SQLSplitter.statement(at: i, in: sql, dialect: .postgres)?.text }
        #expect(at(0) == "select 1")
        #expect(at(8) == "select 1")      // touching the end
        #expect(at(10) == "select 1")     // same line, after the semicolon
        #expect(at(12) == "select 2")     // start of next line
        #expect(at(22) == "select 3")     // blank line between → next
        #expect(at(sql.utf16.count) == "select 3")
    }
}

@Suite struct LexerTests {
    @Test func tokenKinds() {
        let lexer = SQLLexer("SELECT x, \"Y\" FROM t WHERE a = ? -- c", dialect: .postgres)
        let kinds = lexer.tokens().filter { $0.kind != .whitespace }.map(\.kind)
        #expect(kinds == [.keyword, .word, .punctuation, .quotedIdentifier, .keyword, .word,
                          .keyword, .word, .operator, .parameter, .lineComment])
    }

    @Test func mysqlDoubleQuotesAreStrings() {
        let tokens = SQLLexer(#"select "a""#, dialect: .mysql).tokens()
        #expect(tokens.last?.kind == .string)
    }

    @Test func unterminatedRunsToEnd() {
        let lexer = SQLLexer("select 'abc", dialect: .postgres)
        #expect(lexer.tokens().last?.range == 7..<11)
    }
}
