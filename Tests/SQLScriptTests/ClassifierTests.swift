import Testing
@testable import SQLScript

private func kind(_ sql: String, _ d: LexerDialect = .postgres) -> SQLStatementKind {
    SQLClassifier.kind(of: sql, dialect: d)
}

@Suite struct ClassifierTests {
    @Test func reads() {
        for sql in [
            "select * from users", "  -- note\nSELECT 1", "(select 1) union (select 2)",
            "with t as (select 1) select * from t", "values (1), (2)", "table users",
            "show tables", "describe users", "desc users", "explain select * from t",
            "explain (costs off) select 1", "explain query plan select 1", "explain analyze select 1",
            "select * from t for update", "select 'insert into x'", "select \"update\" from t",
        ] {
            #expect(kind(sql) == .read, "\(sql)")
        }
        #expect(kind("SHOW DATABASES", .mysql) == .read)
        #expect(kind("select `delete` from t", .mysql) == .read)
    }

    @Test func writes() {
        for sql in [
            "insert into t values (1)", "update t set a = 1", "delete from t", "truncate t",
            "create table t (a int)", "drop table t", "alter table t add b int", "grant select on t to u",
            "set search_path to public", "begin", "commit", "call p()", "pragma foreign_keys = off",
            "pragma table_info(t)", "vacuum", "copy t from stdin", "do $$ begin end $$",
            "select * into backup from t", "with d as (delete from t returning *) select * from d",
            "with t as (select 1) insert into x select * from t",
            "explain analyze delete from t", "explain (analyze, buffers) update t set a = 1",
            "merge into t using s on t.id = s.id when matched then delete",
        ] {
            #expect(kind(sql) == .write, "\(sql)")
        }
        #expect(kind("select 1 into @x", .mysql) == .write)
        #expect(kind("replace into t values (1)", .mysql) == .write)
        #expect(kind("use shop", .mysql) == .write)
        #expect(kind("explain analyze insert into t values (1)", .mysql) == .write)
    }

    @Test func emptyIsRead() {
        #expect(kind("") == .read)
        #expect(kind("-- only a comment") == .read)
    }
}
