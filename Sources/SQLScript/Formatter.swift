/// SQL "Beautify" (`format`) and "Uglify" (`compact`). Works on lexer tokens only; our own
/// layout rules, written from the SQL grammars, not taken from any other tool.
///
/// Safety (both functions):
/// - Only the whitespace between tokens changes, plus keyword case in `format`. Strings,
///   quoted identifiers, comments and `$$` bodies are copied verbatim.
/// - Operator characters typed together (`>=`, `->>`, `::`, `@>`, `?|`) are never pulled apart.
///   The one exception: a trailing `+`/`-` is split off where PostgreSQL's lexer splits it too
///   (`=-1` → `= -1`; never in a run containing `~ ! @ # % ^ & | \` ?`, so `#-` stays whole).
///   Two separate operators always keep a space between them, so `- -1` never becomes `--1`.
/// - Every formatted statement is re-lexed and compared with its input (kinds and texts,
///   keywords case-insensitively). If they differ it falls back to normalized spacing, and if
///   that differs too the statement is kept exactly as typed.
///
/// `format` layout:
/// - Statements come from `SQLSplitter` (so each dialect's splitting rules apply), each keeps
///   its own terminator (`;`, or the MySQL `DELIMITER` in force), and they are separated by a
///   blank line. A last statement without a terminator stays without one. Text between
///   statements (`DELIMITER` lines, comments after the last statement, stray `;`) is kept as its
///   own block with normalized spacing, each `DELIMITER` line on its own line. A trailing
///   newline in the input is kept; whitespace-only input is returned as is.
/// - Keywords are upper-cased (`uppercaseKeywords`); words (identifiers, function names) and
///   quoted names keep their case.
/// - Clauses start a line at the block's indent: SELECT, FROM, WHERE, GROUP BY, HAVING,
///   ORDER BY, LIMIT, OFFSET, UNION/INTERSECT/EXCEPT [ALL], INSERT INTO, REPLACE INTO, VALUES,
///   UPDATE, SET, DELETE FROM, RETURNING, ON CONFLICT, ON DUPLICATE KEY UPDATE, WITH, WINDOW,
///   FOR UPDATE/SHARE.
/// - List clauses (SELECT, FROM, SET, GROUP BY, ORDER BY, RETURNING, VALUES, WITH, WINDOW,
///   ON DUPLICATE KEY UPDATE) always put their body on the next line, one level deeper, one
///   item per line (a break after each top-level comma). `SELECT DISTINCT [ON (…)]`,
///   `UNION ALL` and `WITH RECURSIVE` keep their modifier on the clause's line.
/// - Condition clauses (WHERE, HAVING) put the condition on the next line, one level deeper;
///   each top-level AND / OR starts a line at that level. The AND of `BETWEEN x AND y` doesn't.
/// - Inline clauses (LIMIT, OFFSET, INSERT INTO, UPDATE, DELETE FROM, ON CONFLICT, FOR UPDATE)
///   keep their argument on the clause's line. UNION / INTERSECT / EXCEPT stand on a line alone.
/// - JOINs (`JOIN`, `LEFT [OUTER] JOIN`, `CROSS JOIN`, `NATURAL … JOIN`, `STRAIGHT_JOIN`)
///   start a line one level deeper than their clause; ON / USING stay on that line, and the
///   ON condition's top-level AND / OR go one level deeper again.
/// - A parenthesis whose content starts with SELECT, WITH or VALUES is a subquery: `(` ends
///   its line, the subquery is laid out one level deeper than that line, `)` starts a line at
///   that line's indent. Other parentheses stay inline, with no space inside them.
/// - `CREATE … TABLE name (…)`: the first top-level parenthesis puts one column or
///   constraint per line, `)` alone on the last line.
/// - CASE: each WHEN and ELSE starts a line one level deeper than the line CASE is on; END
///   starts a line at that line's indent. THEN stays on the WHEN line.
/// - Spacing: one space between tokens, except none before `,` `)` and after `(`; none around
///   `.` and `::`; none inside `[ ]`; `f(x)` with no space after a function name (a space
///   after a table name following INTO / TABLE / VIEW / EXISTS, and after OVER / FILTER /
///   CONFLICT / LATERAL / MATERIALIZED). After a keyword, `(` keeps whatever spacing it had.
///   A prefix operator (`-1`, `~x`, `-(a + b)`) stays attached if it was typed attached.
///   Operators containing `@` or `:` (other than `::`) keep their typed spacing on both sides,
///   since those characters also start names (`@var`, `:name`, `'u'@'host'`, `a[1:2]`).
/// - Comments: a comment that started its own line keeps its own line (at the current indent);
///   one that trailed code stays at the end of that line. A line comment (or a block comment
///   that was followed by a line break) is always followed by a line break, so it can never
///   swallow code.
/// - Statements the formatter doesn't model (CREATE, ALTER, DROP, SET, GRANT, … anything not
///   starting with SELECT, WITH, INSERT, REPLACE, UPDATE, DELETE, VALUES, EXPLAIN or `(`) go
///   on one line with normalized spacing; a top-level SELECT / WITH / VALUES right after AS
///   (`CREATE VIEW v AS SELECT …`) switches the rest to query layout.
/// - Statements with semicolons inside (SQLite trigger bodies, MySQL procedures between
///   `DELIMITER` lines) are not re-flowed: their line breaks and indentation stay as typed,
///   other whitespace runs become one space.
///
/// `compact`:
/// - Whitespace runs become one space; whitespace before `;` is dropped and one space follows
///   it, so statements read `a; b`. Keyword case is left alone.
/// - A line comment becomes a block comment `/* text */` unless its text contains `*/` (or
///   `/*` where block comments nest, PostgreSQL); then it stays a line comment, followed by a
///   line break.
/// - MySQL `DELIMITER` lines stay on their own line (the client reads them up to the line end).
public enum SQLFormatter {
    public struct Options: Sendable, Hashable {
        /// One level of indentation.
        public var indent: String
        public var uppercaseKeywords: Bool

        public init(indent: String = "    ", uppercaseKeywords: Bool = true) {
            self.indent = indent
            self.uppercaseKeywords = uppercaseKeywords
        }
    }

    /// Reformats a script: every statement laid out on its own, separated by a blank line.
    public static func format(_ text: String, dialect: LexerDialect, options: Options = Options()) -> String {
        let lexer = SQLLexer(text, dialect: dialect)
        guard lexer.units.contains(where: { !isSpace($0) }) else { return text }
        var chunks: [String] = []
        var pos = 0

        func addGap(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let gap = normalized(SQLLexer(lexer.text(range), dialect: dialect),
                                 keepIndent: false, uppercase: false, delimiterLines: true)
            if !gap.isEmpty { chunks.append(gap) }
        }

        for statement in SQLSplitter.split(lexer) {
            addGap(pos..<statement.range.lowerBound)
            var body = formatStatement(statement.text, dialect: dialect, options: options)
            let terminator = trimmed(lexer.text(statement.range.upperBound..<statement.fullRange.upperBound))
            if !terminator.isEmpty {
                // `-- note;` would comment out the terminator.
                if SQLLexer(statement.text, dialect: dialect).tokens().last?.kind == .lineComment {
                    body += "\n"
                }
                body += terminator
            }
            chunks.append(body)
            pos = statement.fullRange.upperBound
        }
        addGap(pos..<lexer.units.count)

        var result = chunks.joined(separator: "\n\n")
        if lexer.units.last == ch("\n") { result += "\n" }
        return result
    }

    /// Collapses a script onto as few lines as possible (see the rules above).
    public static func compact(_ text: String, dialect: LexerDialect) -> String {
        let lexer = SQLLexer(text, dialect: dialect)
        let tokens = lexer.tokens()
        guard tokens.contains(where: { $0.kind != .whitespace }) else { return text }
        let statements = dialect.delimiterCommand ? SQLSplitter.split(lexer).map(\.range) : []

        enum Gap { case none, space, newline }
        var out = ""
        var gap = Gap.none
        var skipUntil = 0
        for token in tokens where token.range.lowerBound >= skipUntil {
            switch token.kind {
            case .whitespace:
                if gap == .none { gap = .space }
                continue
            case .semicolon:
                if gap == .space { gap = .none }
            default:
                break
            }
            if let end = delimiterLineEnd(lexer, token),
               !statements.contains(where: { $0.contains(token.range.lowerBound) }) {
                if !out.isEmpty { out += "\n" }
                out += trimmed(lexer.text(token.range.lowerBound..<end))
                gap = .newline
                skipUntil = end
                continue
            }
            if !out.isEmpty {
                switch gap {
                case .none: break
                case .space: out += " "
                case .newline: out += "\n"
                }
            }
            gap = .none
            var piece = lexer.text(token.range)
            if token.kind == .lineComment {
                guard let block = blockComment(piece, dialect: dialect) else {
                    out += piece
                    gap = .newline
                    continue
                }
                piece = block
            }
            out += piece
            if token.kind == .semicolon { gap = .space }
        }
        return out
    }

    // MARK: - Statements

    static func formatStatement(_ text: String, dialect: LexerDialect, options: Options) -> String {
        let lexer = SQLLexer(text, dialect: dialect)
        let units = makeUnits(lexer, uppercase: options.uppercaseKeywords)
        let expected = signature(units)
        func verified(_ out: String) -> Bool {
            signature(makeUnits(SQLLexer(out, dialect: dialect), uppercase: false)) == expected
        }
        if !units.contains(where: { $0.kind == .semicolon }) {
            var printer = Printer(units: units, indent: options.indent)
            let out = printer.run()
            if verified(out) { return out }
        }
        let safe = normalized(lexer, keepIndent: true, uppercase: options.uppercaseKeywords,
                              delimiterLines: false)
        return verified(safe) ? safe : text
    }

    /// Tokens in order; a whitespace run with a line break becomes one line break (plus the
    /// next line's indentation when `keepIndent`), any other run one space.
    static func normalized(
        _ lexer: SQLLexer, keepIndent: Bool, uppercase: Bool, delimiterLines: Bool
    ) -> String {
        var out = ""
        var gap: String?
        var skipUntil = 0
        for token in lexer.tokens() where token.range.lowerBound >= skipUntil {
            if token.kind == .whitespace {
                let ws = lexer.units[token.range]
                if let nl = ws.lastIndex(of: ch("\n")) {
                    gap = "\n" + (keepIndent ? String(decoding: ws[(nl + 1)...], as: UTF16.self) : "")
                } else if gap == nil {
                    gap = " "
                }
                continue
            }
            var text = lexer.text(token.range)
            var isDelimiterLine = false
            if delimiterLines, let end = delimiterLineEnd(lexer, token) {
                text = trimmed(lexer.text(token.range.lowerBound..<end))
                gap = "\n"
                skipUntil = end
                isDelimiterLine = true
            } else if token.kind == .keyword, uppercase {
                text = upperKeyword(text)
            }
            if !out.isEmpty, let gap { out += gap }
            gap = isDelimiterLine ? "\n" : nil
            out += text
        }
        return out
    }

    /// End of a MySQL-client `DELIMITER xx` line starting at `token` (callers make sure the
    /// token is outside any statement).
    static func delimiterLineEnd(_ lexer: SQLLexer, _ token: Token) -> Int? {
        guard lexer.dialect.delimiterCommand, token.kind == .word || token.kind == .keyword,
              lexer.text(token.range).uppercased() == "DELIMITER" else { return nil }
        var end = token.range.upperBound
        while end < lexer.units.count, lexer.units[end] != ch("\n") { end += 1 }
        return end
    }

    /// `-- text` → `/* text */`, or nil when the text would end (or nest) the block comment.
    static func blockComment(_ comment: String, dialect: LexerDialect) -> String? {
        var body = Substring(comment)
        if body.hasPrefix("--") { body = body.dropFirst(2) } else if body.hasPrefix("#") { body = body.dropFirst() }
        let inner = trimmed(String(body))
        if inner.contains("*/") || (dialect.nestedBlockComments && inner.contains("/*")) { return nil }
        // The space after `/*` also keeps `--!x` from becoming a MySQL `/*!` executable comment.
        return inner.isEmpty ? "/* */" : "/* \(inner) */"
    }

    static func trimmed(_ s: String) -> String {
        let u = Array(s.utf16)
        var a = 0, b = u.count
        while a < b, isSpace(u[a]) { a += 1 }
        while b > a, isSpace(u[b - 1]) { b -= 1 }
        return String(decoding: u[a..<b], as: UTF16.self)
    }

    /// ASCII only: `ſelect` lexes as a keyword here but upper-cases to a different word.
    static func upperKeyword(_ text: String) -> String {
        text.utf16.allSatisfy { $0 < 0x80 } ? text.uppercased() : text
    }

    // MARK: - Units

    /// A token, or a run of operator characters typed together.
    struct Unit {
        var kind: TokenKind
        var text: String
        /// Upper-cased text for words and keywords, "" otherwise.
        var upper: String
        /// No whitespace before it in the source.
        var glued = false
        var newlineBefore = false
        var newlineAfter = false

        var isWordish: Bool { kind == .word || kind == .keyword }
        func `is`(_ kind: TokenKind, _ text: String) -> Bool { self.kind == kind && self.text == text }
    }

    static func makeUnits(_ lexer: SQLLexer, uppercase: Bool) -> [Unit] {
        var out: [Unit] = []
        var space = false, newline = false
        for token in lexer.tokens() {
            if token.kind == .whitespace {
                space = true
                if lexer.units[token.range].contains(ch("\n")) { newline = true }
                continue
            }
            var text = lexer.text(token.range)
            let glued = !space && !out.isEmpty
            // `[` `]` are brackets, not operator characters; `?|`, `?&`, `?-`, `?#` are PG operators.
            if token.kind == .operator, glued, text != "[", text != "]", let prev = out.last,
               (prev.kind == .operator && prev.text != "[" && prev.text != "]")
                || (prev.is(.parameter, "?") && ["|", "&", "-", "#"].contains(text)) {
                out[out.count - 1].kind = .operator
                out[out.count - 1].text += text
                continue
            }
            if !out.isEmpty { out[out.count - 1].newlineAfter = newline }
            let wordish = token.kind == .word || token.kind == .keyword
            let upper = wordish ? text.uppercased() : ""
            if token.kind == .keyword, uppercase { text = upperKeyword(text) }
            out.append(Unit(kind: token.kind, text: text, upper: upper, glued: glued, newlineBefore: newline))
            space = false
            newline = false
        }
        // Split a trailing sign off a run, as PostgreSQL does (MySQL and SQLite have no
        // multi-character operator ending in + or -).
        var i = 0
        while i < out.count {
            let u = out[i]
            if u.kind == .operator, u.text.count > 1, let sign = u.text.last, sign == "-" || sign == "+",
               !u.text.contains(where: { "~!@#%^&|`?".contains($0) }) {
                out[i].text.removeLast()
                out[i].newlineAfter = false
                out.insert(Unit(kind: .operator, text: String(sign), upper: "", glued: true,
                                newlineAfter: u.newlineAfter), at: i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    static func signature(_ units: [Unit]) -> [String] {
        units.map { "\($0.kind)\u{0}" + ($0.kind == .keyword ? $0.upper : $0.text) }
    }

    // MARK: - Layout

    private static let queryStarters: Set<String> = [
        "SELECT", "WITH", "INSERT", "REPLACE", "UPDATE", "DELETE", "VALUES", "EXPLAIN",
    ]
    private static let subqueryStarters: Set<String> = ["SELECT", "WITH", "VALUES"]
    private static let joinModifiers: Set<String> = ["NATURAL", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS"]
    private static let joinWords: Set<String> = ["JOIN", "STRAIGHT_JOIN"]
    private static let operandKeywords: Set<String> = [
        "NULL", "TRUE", "FALSE", "END", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
    ]
    /// Words followed by a parenthesis that isn't an argument list.
    private static let spacedWords: Set<String> = ["OVER", "FILTER", "CONFLICT", "LATERAL", "MATERIALIZED"]
    /// A table name after these takes a space before its column list.
    private static let nameIntroducers: Set<String> = ["INTO", "TABLE", "VIEW", "EXISTS"]

    private struct Printer {
        enum FrameKind { case generic, query, inline, ddl, caseExpression }
        enum Clause { case none, list, condition, inline }

        struct Frame {
            var kind: FrameKind
            var base: Int
            /// The `(` that opened it.
            var open: Int?
            /// `)` starts a line at this indent; nil keeps it inline.
            var closeIndent: Int?
            var clause = Clause.none
            /// Units before this index belong to the current clause's keywords.
            var headerEnd = 0
            var inJoin = false
            var inJoinOn = false
            var pendingBetween = 0
        }

        let units: [Unit]
        let indent: String
        var out = ""
        var lineIndent = 0
        /// A line break the next unit must take (after a line comment).
        var forced: Int?
        /// Line breaks clauses asked for before a later unit.
        var scheduled: [Int: Int] = [:]
        var frames: [Frame]
        var last: Int?
        var unary: [Bool]
        var prevCode: [Int?]
        var nextCode: [Int?]
        var ddlUsed = false
        /// The TABLE of a `CREATE … TABLE` statement.
        let createTable: Int?

        init(units: [Unit], indent: String) {
            self.units = units
            self.indent = indent
            unary = Array(repeating: false, count: units.count)
            prevCode = Array(repeating: nil, count: units.count)
            nextCode = Array(repeating: nil, count: units.count)
            var previous: Int?
            for i in units.indices {
                prevCode[i] = previous
                if !units[i].kind.isComment { previous = i }
            }
            var following: Int?
            for i in units.indices.reversed() {
                nextCode[i] = following
                if !units[i].kind.isComment { following = i }
            }
            let first = units.firstIndex { !$0.kind.isComment }
            let isQuery = first.map {
                SQLFormatter.queryStarters.contains(units[$0].upper) || units[$0].is(.punctuation, "(")
            } ?? false
            frames = [Frame(kind: isQuery ? .query : .generic, base: 0)]
            createTable = first.flatMap { units[$0].upper == "CREATE" ? units.firstIndex { $0.upper == "TABLE" } : nil }
        }

        mutating func run() -> String {
            for i in units.indices { step(i) }
            return out
        }

        // MARK: Steps

        mutating func step(_ i: Int) {
            let u = units[i]
            if u.kind.isComment { return comment(i) }
            if u.kind == .punctuation {
                switch u.text {
                case "(": return openParen(i)
                case ")": return closeParen(i)
                case ",": return comma(i)
                default: break
                }
            }
            var own: Int?
            if u.isWordish {
                if u.upper == "CASE" {
                    place(i, nil)
                    frames.append(Frame(kind: .caseExpression, base: lineIndent))
                    return
                }
                if let top = frames.last, top.kind == .caseExpression {
                    switch u.upper {
                    case "WHEN", "ELSE": return place(i, top.base + 1)
                    case "END":
                        place(i, top.base)
                        frames.removeLast()
                        return
                    default: break
                    }
                }
                // `CREATE VIEW v AS SELECT …`: the query part gets query layout.
                if frames.count == 1, frames[0].kind == .generic, u.kind == .keyword,
                   SQLFormatter.subqueryStarters.contains(u.upper), upper(prevCode[i]) == "AS" {
                    frames[0].kind = .query
                }
                if frames[frames.count - 1].kind == .query { own = clauseBreak(i) }
            }
            place(i, own)
        }

        mutating func openParen(_ i: Int) {
            let isSubquery = nextCode[i].map {
                units[$0].isWordish && SQLFormatter.subqueryStarters.contains(units[$0].upper)
            } ?? false
            let isTable = !isSubquery && !ddlUsed && frames.count == 1 && frames[0].kind == .generic
                && (createTable.map { $0 < i } ?? false)
                && (prevCode[i].map { [.word, .quotedIdentifier].contains(units[$0].kind) } ?? false)
            place(i, nil)
            if isSubquery || isTable {
                frames.append(Frame(kind: isSubquery ? .query : .ddl, base: lineIndent + 1,
                                    open: i, closeIndent: lineIndent))
                schedule(i + 1, lineIndent + 1)
                if isTable { ddlUsed = true }
            } else {
                frames.append(Frame(kind: .inline, base: lineIndent, open: i))
            }
        }

        mutating func closeParen(_ i: Int) {
            var own: Int?
            // Unclosed CASEs inside go with it.
            if let k = frames.lastIndex(where: { $0.open != nil }) {
                own = frames[k].closeIndent
                frames.removeSubrange(k...)
            }
            place(i, own)
        }

        mutating func comma(_ i: Int) {
            place(i, nil)
            let f = frames[frames.count - 1]
            switch f.kind {
            case .ddl: schedule(i + 1, f.base)
            case .query where f.clause == .list && i >= f.headerEnd: schedule(i + 1, f.base + 1)
            default: break
            }
        }

        mutating func comment(_ i: Int) {
            let u = units[i]
            var pending = scheduled.removeValue(forKey: i)
            let ownLine = u.newlineBefore || forced != nil
            if !ownLine, let p = pending {
                // A trailing comment stays on its line; the break moves past it.
                if i + 1 < units.count, scheduled[i + 1] == nil { scheduled[i + 1] = p }
                pending = nil
            }
            if !out.isEmpty {
                if ownLine { newline(pending ?? forced ?? lineIndent) } else { out += " " }
            }
            forced = nil
            out += u.text
            last = i
            if u.kind == .lineComment || u.newlineAfter { forced = lineIndent }
        }

        /// Breaks for clause keywords in a query frame; updates the frame's clause state.
        mutating func clauseBreak(_ i: Int) -> Int? {
            let top = frames.count - 1
            var f = frames[top]
            defer { frames[top] = f }
            guard i >= f.headerEnd else { return nil }

            let word = units[i].upper
            let prev = prevCode[i]
            let prevWord = upper(prev)
            let atStart = prev == nil || prev == f.open
            let afterLead = atStart || ["EXPLAIN", "ANALYZE", "VERBOSE", "AS"].contains(prevWord)
            let afterClose = prev.map { units[$0].is(.punctuation, ")") } ?? false
            let list = f.base + 1

            func code(_ k: Int) -> Int? {
                var j: Int? = i
                for _ in 0..<k { j = j.flatMap { nextCode[$0] } }
                return j
            }
            func next(_ k: Int, _ w: String) -> Bool { upper(code(k)) == w }
            func start(_ clause: Clause, through end: Int?, body: Int?) -> Int {
                let end = end ?? i
                f.clause = clause
                f.headerEnd = end + 1
                f.inJoin = false
                f.inJoinOn = false
                f.pendingBetween = 0
                if let body { schedule(end + 1, body) }
                return f.base
            }

            switch word {
            case "SELECT":
                var end = i
                if next(1, "DISTINCT") {
                    end = code(1)!
                    if next(2, "ON"), let open = code(3), units[open].is(.punctuation, "("),
                       let close = matching(open) {
                        end = close
                    }
                } else if next(1, "ALL") {
                    end = code(1)!
                }
                return start(.list, through: end, body: list)
            case "FROM":
                guard prevWord != "DISTINCT" else { return nil }   // IS DISTINCT FROM
                return start(.list, through: i, body: list)
            case "WHERE", "HAVING":
                return start(.condition, through: i, body: list)
            case "GROUP", "ORDER":
                guard next(1, "BY") else { return nil }
                return start(.list, through: code(1), body: list)
            case "SET", "RETURNING":
                return start(.list, through: i, body: list)
            case "LIMIT", "OFFSET":
                return start(.inline, through: i, body: nil)
            case "UNION", "INTERSECT", "EXCEPT":
                let end = next(1, "ALL") || next(1, "DISTINCT") ? code(1) : i
                return start(.none, through: end, body: f.base)
            case "INSERT":
                guard afterLead || afterClose else { return nil }
                return start(.inline, through: next(1, "INTO") ? code(1) : i, body: nil)
            case "REPLACE":
                guard afterLead || afterClose, next(1, "INTO") else { return nil }
                return start(.inline, through: code(1), body: nil)
            case "UPDATE":
                guard afterLead || afterClose else { return nil }
                return start(.inline, through: i, body: nil)
            case "DELETE":
                guard afterLead || afterClose else { return nil }
                return start(.inline, through: next(1, "FROM") ? code(1) : i, body: nil)
            case "VALUES":
                // Not MySQL's `VALUES(col)` function after `=` or `,`, nor DEFAULT VALUES.
                let prevKind = prev.map { units[$0].kind }
                guard atStart || afterClose
                    || ([.word, .quotedIdentifier, .keyword].contains(prevKind) && prevWord != "DEFAULT")
                else { return nil }
                return start(.list, through: i, body: list)
            case "WITH":
                guard afterLead else { return nil }   // not WITH TIME ZONE, WITH ORDINALITY…
                return start(.list, through: next(1, "RECURSIVE") ? code(1) : i, body: list)
            case "WINDOW":
                guard next(2, "AS") else { return nil }
                return start(.list, through: i, body: list)
            case "ON":
                if next(1, "CONFLICT") { return start(.inline, through: code(1), body: nil) }
                if next(1, "DUPLICATE"), next(2, "KEY"), next(3, "UPDATE") {
                    return start(.list, through: code(3), body: list)
                }
                if f.inJoin { f.inJoinOn = true }
                return nil
            case "FOR":
                guard ["UPDATE", "SHARE", "NO", "KEY"].contains(upper(code(1))) else { return nil }
                return start(.inline, through: i, body: nil)
            case "AND", "OR":
                guard f.clause == .condition || f.inJoinOn else { return nil }
                if word == "AND", f.pendingBetween > 0 {
                    f.pendingBetween -= 1
                    return nil
                }
                return f.base + (f.inJoinOn ? 2 : 1)
            case "BETWEEN":
                f.pendingBetween += 1
                return nil
            default:
                break
            }

            if SQLFormatter.joinModifiers.contains(word) || SQLFormatter.joinWords.contains(word) {
                var j = i
                while SQLFormatter.joinModifiers.contains(units[j].upper), let n = nextCode[j] { j = n }
                if SQLFormatter.joinWords.contains(units[j].upper) {
                    f.headerEnd = j + 1
                    f.inJoin = true
                    f.inJoinOn = false
                    f.pendingBetween = 0
                    return f.base + 1
                }
            }
            return nil
        }

        // MARK: Output

        mutating func place(_ i: Int, _ own: Int?) {
            let pending = scheduled.removeValue(forKey: i)
            let brk = own ?? pending ?? forced
            forced = nil
            if !out.isEmpty {
                if let brk {
                    newline(brk)
                } else if let last, needsSpace(last, i) {
                    out += " "
                }
            }
            out += units[i].text
            if units[i].kind == .operator { unary[i] = !isOperand(prevCode[i]) }
            last = i
        }

        mutating func newline(_ level: Int) {
            out += "\n" + String(repeating: indent, count: level)
            lineIndent = level
        }

        mutating func schedule(_ i: Int, _ level: Int) {
            if i < units.count { scheduled[i] = level }
        }

        func needsSpace(_ p: Int, _ n: Int) -> Bool {
            let a = units[p], b = units[n]
            if a.kind.isComment || b.kind.isComment { return true }
            if b.kind == .semicolon { return false }
            if b.is(.punctuation, ",") || b.is(.punctuation, ")") || a.is(.punctuation, "(") { return false }
            if a.is(.punctuation, ".") || b.is(.punctuation, ".") { return false }
            if a.is(.operator, "::") || b.is(.operator, "::") { return false }
            if a.is(.operator, "[") || b.is(.operator, "]") { return false }
            if b.is(.operator, "[") { return !b.glued }
            if b.is(.punctuation, "(") {
                switch a.kind {
                case .word, .quotedIdentifier:
                    return SQLFormatter.spacedWords.contains(a.upper) || followsNameIntroducer(p)
                case .keyword:
                    return !b.glued
                case .operator:
                    return !(unary[p] && b.glued)
                default:
                    return true
                }
            }
            if keepsSpacing(a) || keepsSpacing(b) { return !b.glued }
            if a.kind == .operator, unary[p], b.glued, b.kind != .operator { return false }
            return true
        }

        // MARK: Helpers

        func upper(_ i: Int?) -> String { i.map { units[$0].upper } ?? "" }

        /// `@` and `:` also start names (`@var`, `:name`, `'u'@'host'`), so a run holding one
        /// (other than `::`) keeps the spacing it was typed with.
        func keepsSpacing(_ u: Unit) -> Bool {
            u.kind == .operator && u.text != "::" && (u.text.contains("@") || u.text.contains(":"))
        }

        func isOperand(_ i: Int?) -> Bool {
            guard let i else { return false }
            let u = units[i]
            switch u.kind {
            case .word, .quotedIdentifier, .number, .string, .parameter: return true
            case .punctuation: return u.text == ")"
            case .operator: return u.text == "]"
            case .keyword: return SQLFormatter.operandKeywords.contains(u.upper)
            default: return false
            }
        }

        /// `INSERT INTO s.t (a)`: the name before `(` follows INTO / TABLE / VIEW / EXISTS.
        func followsNameIntroducer(_ p: Int) -> Bool {
            var j = p
            while let dot = prevCode[j], units[dot].is(.punctuation, "."), let q = prevCode[dot],
                  [.word, .quotedIdentifier].contains(units[q].kind) {
                j = q
            }
            return SQLFormatter.nameIntroducers.contains(upper(prevCode[j]))
        }

        func matching(_ open: Int) -> Int? {
            var depth = 0
            for j in open..<units.count where units[j].kind == .punctuation {
                if units[j].text == "(" { depth += 1 }
                if units[j].text == ")" {
                    depth -= 1
                    if depth == 0 { return j }
                }
            }
            return nil
        }
    }
}
