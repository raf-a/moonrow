import Testing
@testable import SQLScript

@Suite struct BracketsTests {
    private let sql = "select count(*) from (select f(a, ')') from t /* ( */) x"

    private func offset(of needle: String, nth: Int = 0) -> Int {
        var from = sql.startIndex
        var found = sql.startIndex
        for _ in 0...nth {
            found = sql[from...].range(of: needle)!.lowerBound
            from = sql.index(after: found)
        }
        return sql.utf16.distance(from: sql.utf16.startIndex, to: found)
    }

    @Test func matchesAcrossNesting() {
        let open = offset(of: "(", nth: 1)       // after `from`
        let close = offset(of: ") x")
        #expect(SQLBrackets.match(at: open + 1, in: sql, dialect: .postgres) == close)
        #expect(SQLBrackets.match(at: close + 1, in: sql, dialect: .postgres) == open)
        // Just after the cursor, when the character before isn't one.
        #expect(SQLBrackets.match(at: open, in: sql, dialect: .postgres) == close)
        let count = offset(of: "(*)")
        #expect(SQLBrackets.match(at: count + 1, in: sql, dialect: .postgres) == count + 2)
    }

    @Test func ignoresStringsAndComments() {
        let inString = offset(of: "')'") + 1
        #expect(SQLBrackets.match(at: inString + 1, in: sql, dialect: .postgres) == nil)
        let inComment = offset(of: "/* (") + 3
        #expect(SQLBrackets.match(at: inComment + 1, in: sql, dialect: .postgres) == nil)
        #expect(SQLBrackets.match(at: 3, in: sql, dialect: .postgres) == nil)
        #expect(SQLBrackets.match(at: 1, in: "(select 1", dialect: .postgres) == nil)
    }
}
