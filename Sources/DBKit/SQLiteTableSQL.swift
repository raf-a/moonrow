import Foundation
import SQLScript

/// A SQLite `CREATE TABLE` statement taken apart at the clause level, so a rebuild can change
/// the clauses it understands and keep the rest (CHECK, COLLATE, generated columns, conflict
/// clauses) as they were written.
struct SQLiteTableSQL: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case primaryKey, notNull, null, unique, check, defaultValue, collate, references, generated, foreignKey, other
    }

    /// A column constraint or a table constraint, as written (a leading `CONSTRAINT name` included).
    struct Clause: Sendable, Hashable {
        var kind: Kind
        var text: String
        /// PRIMARY KEY / UNIQUE / FOREIGN KEY table constraints: their columns.
        var columns: [String] = []
        /// REFERENCES / FOREIGN KEY: the parent table.
        var referencedTable: String?
        /// Identifiers mentioned anywhere in the clause (for CHECK and generated expressions).
        var identifiers: Set<String> = []
    }

    struct Column: Sendable, Hashable {
        var name: String
        var type: String
        var clauses: [Clause]
    }

    var columns: [Column] = []
    var constraints: [Clause] = []
    /// What follows the closing parenthesis: `WITHOUT ROWID`, `STRICT`.
    var options: String = ""

    /// Nil for `CREATE TABLE … AS SELECT` and text that doesn't parse.
    init?(_ sql: String) {
        let lexer = SQLLexer(sql, dialect: .sqlite)
        let tokens = lexer.tokens().filter { !$0.kind.isTrivia }
        func text(_ t: Token) -> String { lexer.text(t.range) }
        func upper(_ t: Token) -> String { text(t).uppercased() }
        func isPunct(_ t: Token, _ p: String) -> Bool { t.kind == .punctuation && text(t) == p }

        guard let open = tokens.firstIndex(where: { isPunct($0, "(") }),
              !tokens[..<open].contains(where: { upper($0) == "AS" && $0.kind != .quotedIdentifier })
        else { return nil }
        var depth = 0
        var close: Int?
        var elements: [[Token]] = [[]]
        for i in (open + 1)..<tokens.count {
            let t = tokens[i]
            if isPunct(t, "(") { depth += 1 }
            if isPunct(t, ")") {
                if depth == 0 { close = i; break }
                depth -= 1
            }
            if depth == 0, isPunct(t, ",") { elements.append([]) } else { elements[elements.count - 1].append(t) }
        }
        guard let close else { return nil }
        options = lexer.text(tokens[close].range.upperBound..<lexer.units.count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ";")))

        func slice(_ ts: ArraySlice<Token>) -> String {
            guard let a = ts.first, let b = ts.last else { return "" }
            return lexer.text(a.range.lowerBound..<b.range.upperBound)
        }
        func names(inFirstParensOf ts: ArraySlice<Token>) -> [String] {
            guard let o = ts.firstIndex(where: { isPunct($0, "(") }) else { return [] }
            var out: [String] = []
            var d = 0
            var expectName = true
            // The first identifier of each key part (`a COLLATE x DESC` names `a`).
            for t in ts[(o + 1)...] {
                if isPunct(t, "(") { d += 1 }
                if isPunct(t, ")") { if d == 0 { break }; d -= 1 }
                guard d == 0 else { continue }
                if isPunct(t, ",") {
                    expectName = true
                } else if expectName, t.kind == .word || t.kind == .keyword || t.kind == .quotedIdentifier {
                    out.append(Self.unquote(text(t)))
                    expectName = false
                }
            }
            return out
        }
        func referencedTable(_ ts: ArraySlice<Token>) -> String? {
            guard let r = ts.firstIndex(where: { upper($0) == "REFERENCES" }), r + 1 < ts.endIndex else { return nil }
            return Self.unquote(text(ts[r + 1]))
        }
        func identifiers(_ ts: ArraySlice<Token>) -> Set<String> {
            Set(ts.filter { $0.kind == .word || $0.kind == .quotedIdentifier }.map { Self.unquote(text($0)).lowercased() })
        }
        func kind(of word: String) -> Kind? {
            switch word {
            case "PRIMARY": .primaryKey
            case "NOT": .notNull
            case "NULL": .null
            case "UNIQUE": .unique
            case "CHECK": .check
            case "DEFAULT": .defaultValue
            case "COLLATE": .collate
            case "REFERENCES": .references
            case "GENERATED", "AS": .generated
            case "FOREIGN": .foreignKey
            default: nil
            }
        }

        let tableConstraintWords: Set<String> = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"]
        for element in elements where !element.isEmpty {
            let ts = element[...]
            if element[0].kind != .quotedIdentifier, tableConstraintWords.contains(upper(element[0])) {
                var head = 0
                if upper(element[0]) == "CONSTRAINT", element.count > 2 { head = 2 }
                let k = kind(of: upper(element[head])) ?? .other
                var clause = Clause(kind: k, text: slice(ts), identifiers: identifiers(ts))
                if k == .primaryKey || k == .unique || k == .foreignKey { clause.columns = names(inFirstParensOf: ts) }
                if k == .foreignKey { clause.referencedTable = referencedTable(ts) }
                constraints.append(clause)
                continue
            }

            // A column: name, type words, then clauses. A clause starts at one of its keywords,
            // except where that keyword continues the previous clause (NOT NULL, DEFAULT NULL,
            // SET NULL, GENERATED ALWAYS AS, NOT DEFERRABLE).
            var clauseStarts: [Int] = []
            var d = 0
            for i in 1..<element.count {
                let t = element[i]
                if isPunct(t, "(") { d += 1 }
                if isPunct(t, ")") { d -= 1 }
                guard d == 0, t.kind == .word || t.kind == .keyword else { continue }
                let w = upper(t)
                let previous = i > 1 ? upper(element[i - 1]) : ""
                let next = i + 1 < element.count ? upper(element[i + 1]) : ""
                var begins = false
                switch w {
                case "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "COLLATE", "REFERENCES", "GENERATED":
                    begins = true
                case "AS": begins = previous != "ALWAYS"
                case "NOT": begins = next == "NULL"
                case "NULL": begins = !["NOT", "DEFAULT", "SET"].contains(previous)
                case "DEFAULT": begins = previous != "SET"
                default: break
                }
                if begins, previous == "CONSTRAINT" || (clauseStarts.last.map { upper(element[$0]) == "CONSTRAINT" && $0 == i - 2 } ?? false) {
                    begins = false  // the clause after `CONSTRAINT name` belongs to it
                }
                if begins { clauseStarts.append(i) }
            }
            let typeEnd = clauseStarts.first ?? element.count
            var column = Column(
                name: Self.unquote(text(element[0])), type: typeEnd > 1 ? slice(ts[1..<typeEnd]) : "", clauses: [])
            for (n, s) in clauseStarts.enumerated() {
                let end = n + 1 < clauseStarts.count ? clauseStarts[n + 1] : element.count
                let part = ts[s..<end]
                var head = s
                if upper(element[s]) == "CONSTRAINT", s + 2 < end { head = s + 2 }
                let k = kind(of: upper(element[head])) ?? .other
                var clause = Clause(kind: k, text: slice(part), identifiers: identifiers(part))
                if k == .references { clause.referencedTable = referencedTable(part) }
                column.clauses.append(clause)
            }
            columns.append(column)
        }
    }

    static func unquote(_ s: String) -> String {
        guard let first = s.first, let last = s.last, s.count >= 2 else { return s }
        switch (first, last) {
        case ("\"", "\""): return s.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
        case ("`", "`"): return s.dropFirst().dropLast().replacingOccurrences(of: "``", with: "`")
        case ("[", "]"): return String(s.dropFirst().dropLast())
        default: return s
        }
    }

    func column(named name: String) -> Column? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether the column is declared with AUTOINCREMENT.
    func isAutoIncrement(_ name: String) -> Bool {
        column(named: name)?.clauses.contains {
            $0.kind == .primaryKey && $0.text.uppercased().contains("AUTOINCREMENT")
        } ?? false
    }

    /// The column's generated clause (`GENERATED ALWAYS AS (…) STORED`), if it has one.
    func generatedClause(_ name: String) -> String? {
        column(named: name)?.clauses.first { $0.kind == .generated }?.text
    }
}

/// Replaces identifiers in SQL text: `renames` maps lowercased old names to new names, which
/// are written quoted. Strings and comments are left alone.
func renameIdentifiers(in sql: String, _ renames: [String: String], quote: (String) -> String) -> String {
    guard !renames.isEmpty else { return sql }
    let lexer = SQLLexer(sql, dialect: .sqlite)
    var out = ""
    for t in lexer.tokens() {
        let text = lexer.text(t.range)
        if t.kind == .word || t.kind == .quotedIdentifier || t.kind == .keyword,
           let new = renames[SQLiteTableSQL.unquote(text).lowercased()] {
            out += quote(new)
        } else {
            out += text
        }
    }
    return out
}
