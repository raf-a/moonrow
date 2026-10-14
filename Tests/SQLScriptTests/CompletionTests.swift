import Foundation
import Testing
@testable import SQLScript

/// `|` marks the cursor.
private func context(_ marked: String, _ d: LexerDialect = .sqlite) -> SQLCompletion.Context? {
    let offset = marked.utf16.firstIndex(of: UInt16(UInt8(ascii: "|")))
        .map { marked.utf16.distance(from: marked.utf16.startIndex, to: $0) }!
    return SQLCompletion.context(in: marked.replacingOccurrences(of: "|", with: ""), at: offset, dialect: d)
}

private let catalog = SQLCompletion.Catalog(
    tables: ["users", "orders", "order_items", "Weird Name"],
    views: ["active_users"],
    functions: ["upper", "count"],
    columns: ["users": ["id", "created_at", "name", "user_id"], "orders": ["id", "user_id", "total"]])

private func names(_ marked: String, recent: [String] = []) -> [String] {
    guard let ctx = context(marked) else { return [] }
    return SQLCompletion.candidates(for: ctx, catalog: catalog, keywords: ["SELECT", "SET", "UPDATE", "USING"],
                                    recent: recent).map(\.text)
}

@Suite struct CompletionTests {
    @Test func prefixAndReplaceRange() {
        let c = context("select na| from users")!
        #expect(c.prefix == "na")
        #expect(c.replaceRange == 7..<9)
        #expect(c.expects == .any)
        #expect(c.tables == [.init(name: "users")])
    }

    @Test func tablesAfterFromJoinUpdateInto() {
        #expect(context("select * from |")?.expects == .table)
        #expect(context("select * from us|")?.expects == .table)
        #expect(context("select * from users u join o|")?.expects == .table)
        #expect(context("update |")?.expects == .table)
        #expect(context("insert into |")?.expects == .table)
        #expect(context("select * from users, |")?.expects == .table)
        #expect(context("select a, |")?.expects == .any)
        #expect(context("insert into t (a, |")?.expects == .any)
    }

    @Test func aliasesResolveToTheirTables() {
        let c = context("select u.| from users u join orders as o on o.user_id = u.id")!
        #expect(c.expects == .column)
        #expect(c.qualifier == "u")
        #expect(c.tables == [.init(name: "users", alias: "u"), .init(name: "orders", alias: "o")])
        // Declared order while nothing is typed.
        let expected = ["id", "created_at", "name", "user_id"]
        #expect(names("select u.| from users u") == expected)
        #expect(names("select o.to| from users u, orders o") == ["total"])
        // The table name works as a qualifier too.
        #expect(names("select orders.t| from orders") == ["total"])
    }

    @Test func aliasesStopAtClauseKeywords() {
        let c = context("select * from users where |")!
        #expect(c.tables == [.init(name: "users")])
        let d = context("select * from main.users x left join orders on true|")!
        #expect(d.tables == [.init(name: "users", alias: "x"), .init(name: "orders")])
    }

    @Test func columnsOfTablesInScopeComeFirst() {
        let list = names("select u| from users")
        #expect(list.first == "user_id")
        #expect(list.contains("users"))
        #expect(list.contains("UPDATE"))
        #expect(list.contains("upper"))
    }

    @Test func tierOrder() {
        #expect(SQLCompletion.matchTier("user_id", query: "use") == 3)
        #expect(SQLCompletion.matchTier("user_id", query: "ui") == 2)
        #expect(SQLCompletion.matchTier("user_id", query: "usid") == 2)
        #expect(SQLCompletion.matchTier("orderItems", query: "oi") == 2)
        #expect(SQLCompletion.matchTier("user_id", query: "id") == 2)
        #expect(SQLCompletion.matchTier("user_id", query: "sr") == 1)
        #expect(SQLCompletion.matchTier("user_id", query: "x") == nil)
        #expect(SQLCompletion.matchTier("user_id", query: "") == 3)
        // prefix > word start > fuzzy
        #expect(names("select * from oi|") == ["order_items"])
        #expect(names("select * from o|").prefix(2) == ["orders", "order_items"])
    }

    @Test func recencyWinsWithinATier() {
        #expect(names("select * from o|", recent: ["order_items"]).prefix(2) == ["order_items", "orders"])
        // ...but never lifts a weaker match above a stronger one.
        let list = names("select ui| from users", recent: ["USING"])
        #expect(list.first == "user_id")
        #expect(list.contains("USING"))
    }

    @Test func noCompletionInStringsOrComments() {
        #expect(context("select 'us|'") == nil)
        #expect(context("select 1 -- us|") == nil)
        #expect(context("/* us| */") == nil)
    }

    @Test func quotedIdentifiers() {
        let c = context(#"select * from "Wei|"#)!
        #expect(c.prefix == "Wei")
        #expect(c.replaceRange == 14..<18)
        #expect(SQLCompletion.quoteIfNeeded("Weird Name", dialect: .sqlite) == #""Weird Name""#)
        #expect(SQLCompletion.quoteIfNeeded("users", dialect: .sqlite) == "users")
        #expect(SQLCompletion.quoteIfNeeded("order", dialect: .mysql) == "`order`")
        #expect(SQLCompletion.insertion(for: .init("select", kind: .keyword), dialect: .sqlite) == "SELECT")
        let q = context(#"select "u".| from users "u""#)!
        #expect(q.qualifier == "u")
        #expect(q.tables == [.init(name: "users", alias: "u")])
    }

    @Test func onlyTheCurrentStatementCounts() {
        let c = context("select * from orders o;\nselect o.| from users o")!
        #expect(c.tables == [.init(name: "users", alias: "o")])
    }

    @Test func commonTableExpressions() {
        let c = context("with recent as (select * from orders), big as (select 1) select * from |")!
        #expect(c.commonTableExpressions == ["recent", "big"])
        #expect(c.expects == .table)
        let list = SQLCompletion.candidates(for: c, catalog: catalog, keywords: [])
        #expect(list.prefix(2).map(\.text) == ["recent", "big"])
    }

    @Test func postgresQuotesNamesWithCapitals() {
        #expect(SQLCompletion.quoteIfNeeded("Users", dialect: .postgres) == #""Users""#)
        #expect(SQLCompletion.quoteIfNeeded("orderItems", dialect: .postgres) == #""orderItems""#)
        #expect(SQLCompletion.quoteIfNeeded("order_items", dialect: .postgres) == "order_items")
        // MySQL and SQLite read mixed case back as written.
        #expect(SQLCompletion.quoteIfNeeded("Users", dialect: .mysql) == "Users")
        #expect(SQLCompletion.quoteIfNeeded("orderItems", dialect: .sqlite) == "orderItems")
    }

    @Test func keywordsFollowTheTypedCase() {
        let select = SQLCompletion.Item("SELECT", kind: .keyword)
        #expect(SQLCompletion.insertion(for: select, typed: "sel", dialect: .sqlite) == "select")
        #expect(SQLCompletion.insertion(for: select, typed: "SEL", dialect: .sqlite) == "SELECT")
        #expect(SQLCompletion.insertion(for: select, typed: "Sel", dialect: .sqlite) == "SELECT")
        #expect(SQLCompletion.insertion(for: select, typed: "", dialect: .sqlite) == "SELECT")
        // Names keep their own case.
        #expect(SQLCompletion.insertion(for: .init("Users", kind: .table), typed: "us", dialect: .mysql) == "Users")
    }

    @Test func returnEndsTheLineAfterACompleteWord() {
        let and = SQLCompletion.Item("AND", kind: .keyword)
        #expect(!SQLCompletion.returnAccepts(and, typed: "and", dialect: .sqlite, chosen: false))
        #expect(!SQLCompletion.returnAccepts(and, typed: "AND", dialect: .sqlite, chosen: false))
        #expect(SQLCompletion.returnAccepts(and, typed: "an", dialect: .sqlite, chosen: false))
        #expect(SQLCompletion.returnAccepts(and, typed: "and", dialect: .sqlite, chosen: true))
        let users = SQLCompletion.Item("users", kind: .table)
        #expect(!SQLCompletion.returnAccepts(users, typed: "users", dialect: .sqlite, chosen: false))
        #expect(!SQLCompletion.returnAccepts(users, typed: "USERS", dialect: .sqlite, chosen: false))
        // Accepting would quote it.
        let mixed = SQLCompletion.Item("Users", kind: .table)
        #expect(SQLCompletion.returnAccepts(mixed, typed: "Users", dialect: .postgres, chosen: false))
    }
}
