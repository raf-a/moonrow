/// Autocomplete for the query editor: works out what the cursor is in the middle of typing and
/// ranks names that fit there. Pure and synchronous; the app supplies the schema it knows.
///
/// Ranking is our own design: a prefix match beats a match on word starts (`ui` → `user_id`),
/// which beats a fuzzy one (the letters in order). Within a tier, recently accepted names come
/// first, then the kinds that suit the context, then shorter names. Before anything is typed
/// (right after `t.`), names keep their declared order.
public enum SQLCompletion {
    /// What the editor is completing.
    public struct Context: Sendable, Hashable {
        /// The partial word before the cursor (quotes stripped).
        public var prefix: String
        /// UTF-16 range the accepted completion replaces (the partial word, with its quote).
        public var replaceRange: Range<Int>
        /// `u` in `u.na|`: names after a dot are columns of that table or alias.
        public var qualifier: String?
        public var expects: Expectation
        /// Tables the statement reads or writes, with their aliases.
        public var tables: [TableReference]
        /// Names a `WITH` clause defines.
        public var commonTableExpressions: [String]
    }

    public enum Expectation: Sendable, Hashable {
        /// After FROM, JOIN, UPDATE, INTO, TABLE.
        case table
        /// After `x.`.
        case column
        case any
    }

    public struct TableReference: Sendable, Hashable {
        public var name: String
        public var alias: String?

        public init(name: String, alias: String? = nil) {
            self.name = name
            self.alias = alias
        }
    }

    public enum Kind: Int, Sendable, Hashable, Comparable {
        /// A name defined by `WITH`.
        case column, alias, commonTable, table, view, function, keyword

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item: Sendable, Hashable {
        /// What gets inserted.
        public var text: String
        public var kind: Kind
        /// Shown beside the name: a column's table, a table's type.
        public var detail: String?

        public init(_ text: String, kind: Kind, detail: String? = nil) {
            self.text = text
            self.kind = kind
            self.detail = detail
        }
    }

    /// What the app knows about the database. Lookups ignore case.
    public struct Catalog: Sendable {
        public var tables: [String]
        public var views: [String]
        public var functions: [String]
        /// Columns of tables whose structure has been loaded, keyed by lowercased table name.
        public var columns: [String: [String]]

        public init(tables: [String] = [], views: [String] = [], functions: [String] = [],
                    columns: [String: [String]] = [:]) {
            self.tables = tables
            self.views = views
            self.functions = functions
            self.columns = columns
        }

        public func columns(of table: String) -> [String]? { columns[table.lowercased()] }
    }

    // MARK: - Context

    /// The completion context for a cursor at `offset` (UTF-16), or nil inside a string, a
    /// comment or a quoted identifier that's already closed.
    public static func context(in text: String, at offset: Int, dialect: LexerDialect) -> Context? {
        let lexer = SQLLexer(text, dialect: dialect)
        let units = lexer.units
        guard offset >= 0, offset <= units.count else { return nil }
        let statement = SQLSplitter.split(lexer).first {
            $0.fullRange.contains(offset) || $0.fullRange.upperBound == offset
        }
        let bounds = statement?.fullRange ?? (offset..<offset)
        let allTokens = lexer.tokens()
        let tokens = allTokens.filter { $0.range.overlaps(bounds) || $0.range.upperBound == offset }

        // The token the cursor is in or touching on its left.
        var prefix = ""
        var replaceStart = offset
        var before = tokens.filter { $0.range.upperBound <= offset }
        if let t = allTokens.first(where: { $0.range.lowerBound < offset && offset <= $0.range.upperBound }) {
            switch t.kind {
            case .word, .keyword:
                prefix = lexer.text(t.range.lowerBound..<offset)
                replaceStart = t.range.lowerBound
                before = tokens.filter { $0.range.upperBound <= t.range.lowerBound }
            case .quotedIdentifier:
                // Completing inside an unclosed quote: `"us|`.
                let raw = lexer.text(t.range.lowerBound..<offset)
                guard offset == t.range.upperBound, !isClosedQuote(lexer.text(t.range)) else { return nil }
                prefix = String(raw.dropFirst())
                replaceStart = t.range.lowerBound
                before = tokens.filter { $0.range.upperBound <= t.range.lowerBound }
            case .string, .lineComment, .blockComment:
                return nil
            case .number:
                return nil
            default:
                break
            }
        }
        let significant = before.filter { !$0.kind.isTrivia }

        var qualifier: String?
        var expects = Expectation.any
        if let dot = significant.last, lexer.text(dot.range) == ".",
           significant.count >= 2, isName(significant[significant.count - 2].kind) {
            qualifier = unquote(lexer.text(significant[significant.count - 2].range))
            expects = .column
        } else if let last = significant.last {
            let word = last.kind == .keyword || last.kind == .word ? lexer.text(last.range).uppercased() : ""
            if Self.tableKeywords.contains(word) {
                expects = .table
            } else if lexer.text(last.range) == ",", lastClauseKeyword(significant, lexer) == "FROM" {
                expects = .table
            }
        }

        let all = tokens.filter { !$0.kind.isTrivia && $0.range.upperBound <= bounds.upperBound }
        let (tables, ctes) = references(all.filter { $0.range.lowerBound != replaceStart }, lexer)
        return Context(
            prefix: prefix, replaceRange: replaceStart..<offset, qualifier: qualifier, expects: expects,
            tables: tables, commonTableExpressions: ctes)
    }

    static let tableKeywords: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"]
    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "SET", "VALUES", "ON", "JOIN",
        "UNION", "RETURNING", "USING",
    ]
    /// Words that end a table reference instead of naming its alias.
    private static let notAliases: Set<String> = [
        "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER", "ON", "USING",
        "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "SET", "VALUES",
        "WINDOW", "RETURNING", "DEFAULT", "SELECT", "AS", "WITH",
    ]

    private static func lastClauseKeyword(_ tokens: [Token], _ lexer: SQLLexer) -> String? {
        var depth = 0
        for t in tokens.reversed() {
            let s = lexer.text(t.range)
            if s == ")" { depth += 1 } else if s == "(" { if depth == 0 { return nil }; depth -= 1 }
            guard depth == 0, t.kind == .keyword || t.kind == .word else { continue }
            let word = s.uppercased()
            if clauseKeywords.contains(word) { return word }
        }
        return nil
    }

    /// Tables after FROM / JOIN / UPDATE / INTO (with aliases), and names defined by WITH.
    static func references(_ tokens: [Token], _ lexer: SQLLexer) -> ([TableReference], [String]) {
        var tables: [TableReference] = []
        var ctes: [String] = []
        func word(_ i: Int) -> String? {
            guard i < tokens.count, tokens[i].kind == .keyword || tokens[i].kind == .word else { return nil }
            return lexer.text(tokens[i].range).uppercased()
        }
        func text(_ i: Int) -> String? { i < tokens.count ? lexer.text(tokens[i].range) : nil }

        /// Reads `[schema.]name [[AS] alias]` at `i`; returns the index after it.
        func readTable(at start: Int) -> Int? {
            var i = start
            guard i < tokens.count, isName(tokens[i].kind) else { return nil }
            var name = unquote(lexer.text(tokens[i].range))
            if tokens[i].kind == .keyword, notAliases.contains(name.uppercased()) { return nil }
            i += 1
            while text(i) == ".", i + 1 < tokens.count, isName(tokens[i + 1].kind) {
                name = unquote(lexer.text(tokens[i + 1].range))
                i += 2
            }
            var alias: String?
            if word(i) == "AS" { i += 1 }
            if i < tokens.count, isName(tokens[i].kind) {
                let candidate = lexer.text(tokens[i].range)
                if !(tokens[i].kind == .keyword && notAliases.contains(candidate.uppercased()))
                    && !notAliases.contains(candidate.uppercased()) {
                    alias = unquote(candidate)
                    i += 1
                }
            }
            tables.append(TableReference(name: name, alias: alias))
            return i
        }

        var i = 0
        while i < tokens.count {
            let w = word(i)
            if w == "WITH" || (text(i) == "," && !ctes.isEmpty && word(i + 2) == "AS" && text(i + 3) == "(") {
                var j = i + 1
                if word(j) == "RECURSIVE" { j += 1 }
                if j < tokens.count, isName(tokens[j].kind), word(j + 1) == "AS" || text(j + 1) == "(" {
                    ctes.append(unquote(lexer.text(tokens[j].range)))
                }
                i += 1
                continue
            }
            if let w, w == "FROM" || w == "JOIN" || w == "UPDATE" || w == "INTO" {
                var j = i + 1
                while let next = readTable(at: j) {
                    j = next
                    // `FROM a x, b y`: a comma continues the list (FROM only).
                    guard w == "FROM", text(j) == "," else { break }
                    j += 1
                }
                i = max(i + 1, j)
                continue
            }
            i += 1
        }
        return (tables, ctes)
    }

    // MARK: - Candidates

    /// Ranked candidates for `context`. `recent` lists accepted completions, most recent first.
    public static func candidates(
        for context: Context, catalog: Catalog, keywords: Set<String>, recent: [String] = [],
        limit: Int = 200
    ) -> [Item] {
        var pool: [Item] = []
        func columns(of table: String) -> [Item] {
            (catalog.columns(of: table) ?? []).map { Item($0, kind: .column, detail: table) }
        }

        switch context.expects {
        case .column:
            let q = context.qualifier?.lowercased() ?? ""
            if let ref = context.tables.first(where: { $0.alias?.lowercased() == q })
                ?? context.tables.first(where: { $0.name.lowercased() == q }) {
                pool = columns(of: ref.name)
            } else {
                pool = columns(of: q)
            }
        case .table:
            pool = context.commonTableExpressions.map { Item($0, kind: .commonTable) }
                + catalog.tables.map { Item($0, kind: .table) }
                + catalog.views.map { Item($0, kind: .view) }
        case .any:
            var seen = Set<String>()
            for ref in context.tables where seen.insert(ref.name.lowercased()).inserted {
                pool += columns(of: ref.name)
            }
            pool += context.tables.compactMap { $0.alias }.map { Item($0, kind: .alias) }
            pool += context.commonTableExpressions.map { Item($0, kind: .commonTable) }
            pool += catalog.tables.map { Item($0, kind: .table) }
            pool += catalog.views.map { Item($0, kind: .view) }
            pool += catalog.functions.map { Item($0, kind: .function) }
            pool += keywords.map { Item($0, kind: .keyword) }
        }

        let recency = Dictionary(recent.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: min)
        var seen = Set<String>()
        var ranked: [(item: Item, tier: Int, recent: Int, order: Int)] = []
        for item in pool {
            // Same name twice (a column in two joined tables): keep the first.
            guard seen.insert("\(item.kind.rawValue):\(item.text.lowercased())").inserted,
                  let tier = matchTier(item.text, query: context.prefix) else { continue }
            ranked.append((item, tier, recency[item.text.lowercased()] ?? Int.max, ranked.count))
        }
        ranked.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.recent != b.recent { return a.recent < b.recent }
            if a.item.kind != b.item.kind { return a.item.kind < b.item.kind }
            // Nothing typed yet (`t.|`): columns in their declared order.
            if context.prefix.isEmpty { return a.order < b.order }
            if a.item.text.count != b.item.text.count { return a.item.text.count < b.item.text.count }
            return a.item.text.lowercased() < b.item.text.lowercased()
        }
        return ranked.prefix(limit).map(\.item)
    }

    /// 3 = prefix, 2 = word starts, 1 = fuzzy, nil = no match. Ignores case. An empty query
    /// matches everything as a prefix.
    public static func matchTier(_ candidate: String, query: String) -> Int? {
        if query.isEmpty { return 3 }
        let c = Array(candidate.lowercased()), q = Array(query.lowercased())
        if c.starts(with: q) { return 3 }
        if matchesWordStarts(Array(candidate), q) { return 2 }
        var i = 0
        for ch in c where i < q.count && ch == q[i] { i += 1 }
        return i == q.count ? 1 : nil
    }

    /// Each query letter continues the current word or starts a later one: `ui` and `usid`
    /// match `user_id`; `oi` matches `orderItems`.
    private static func matchesWordStarts(_ candidate: [Character], _ query: [Character]) -> Bool {
        // Word starts: index 0, after `_`/`$`/digits boundary, and lower→upper case changes.
        var starts: [Int] = []
        for (i, ch) in candidate.enumerated() {
            if i == 0 { starts.append(i); continue }
            let prev = candidate[i - 1]
            if ch == "_" || ch == "$" { continue }
            if prev == "_" || prev == "$" || (prev.isLowercase && ch.isUppercase)
                || (prev.isLetter && ch.isNumber) {
                starts.append(i)
            }
        }
        let lower = candidate.map { Character($0.lowercased()) }
        // Depth-first over (query index, candidate index); failed pairs are remembered.
        var failed = Set<Int>()
        func match(_ qi: Int, _ ci: Int, continuing: Bool) -> Bool {
            if qi == query.count { return true }
            let key = qi << 16 | ci << 1 | (continuing ? 1 : 0)
            if failed.contains(key) { return false }
            if continuing, ci < lower.count, lower[ci] == query[qi], match(qi + 1, ci + 1, continuing: true) {
                return true
            }
            for s in starts where s >= ci && lower[s] == query[qi] {
                if match(qi + 1, s + 1, continuing: true) { return true }
            }
            failed.insert(key)
            return false
        }
        return match(0, 0, continuing: false)
    }

    // MARK: - Inserting

    /// The text to insert for `item`: keywords in upper case, names quoted when they need it.
    public static func insertion(for item: Item, dialect: LexerDialect) -> String {
        if item.kind == .keyword { return item.text.uppercased() }
        return quoteIfNeeded(item.text, dialect: dialect)
    }

    public static func quoteIfNeeded(_ name: String, dialect: LexerDialect) -> String {
        let units = Array(name.utf16)
        let plain = !units.isEmpty && isIdentStart(units[0]) && units.allSatisfy(isIdentPart)
            && !dialect.keywords.contains(name.uppercased())
        if plain { return name }
        let q: Character = dialect.doubleQuoteIsIdentifier ? "\"" : "`"
        return String(q) + name.flatMap { $0 == q ? [q, q] : [$0] } + String(q)
    }

    // MARK: - Helpers

    private static func isName(_ kind: TokenKind) -> Bool {
        kind == .word || kind == .quotedIdentifier || kind == .keyword
    }

    static func unquote(_ s: String) -> String {
        guard let first = s.first, "\"`[".contains(first) else { return s }
        let close: Character = first == "[" ? "]" : first
        var inner = s.dropFirst()
        if inner.last == close { inner = inner.dropLast() }
        var out = ""
        var pendingClose = false
        for ch in inner {
            if ch == close && pendingClose { pendingClose = false; continue }
            pendingClose = ch == close
            out.append(ch)
        }
        return out
    }

    private static func isClosedQuote(_ s: String) -> Bool {
        guard s.count >= 2, let first = s.first else { return false }
        let close: Character = first == "[" ? "]" : first
        return s.last == close
    }
}
