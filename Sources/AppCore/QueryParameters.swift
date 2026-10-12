import DBKit
import Foundation
import SQLScript

/// Placeholders in the query editor's statements that ask for a value before running:
/// `:name` everywhere, `$1` on Postgres and `?` on MySQL and SQLite (Postgres's `?` is a
/// jsonb operator). Strings, quoted names, comments and `$$` bodies never hold one.
///
/// `:name` starts at a `:` right before a name, unless the `:` follows `:` (a `::` cast), a
/// name, a number, a quoted name or a closing bracket (an array slice `a[1:n]`), so casts and
/// slices keep working. Equal names share one value; each `$n` is one value; each `?` is its
/// own value, numbered in the order they appear.
public enum QueryParameters {
    public enum Style: Sendable, Hashable {
        /// `:name`
        case named
        /// `$1`
        case numbered
        /// `?`
        case positional
    }

    /// The styles a database's SQL uses.
    public static func styles(for dialect: any Dialect) -> Set<Style> {
        dialect.placeholder(1) == "?" ? [.named, .positional] : [.named, .numbered]
    }

    /// One placeholder in one statement. `range` is in UTF-16 units of that statement's text.
    public struct Occurrence: Sendable, Hashable {
        public var statement: Int
        public var range: Range<Int>
        /// `:name`, `$1`, or `?1`, `?2`, … for positional ones.
        public var key: String
    }

    /// The placeholders of a run's statements, and their distinct keys in order of appearance.
    public static func find(in statements: [String], dialect: LexerDialect, styles: Set<Style>) -> (keys: [String], occurrences: [Occurrence]) {
        var keys: [String] = []
        var seen = Set<String>()
        var occurrences: [Occurrence] = []
        var positional = 0
        for (s, text) in statements.enumerated() {
            let lexer = SQLLexer(text, dialect: dialect)
            let tokens = lexer.tokens()
            for (i, token) in tokens.enumerated() {
                var key: String?
                var range = token.range
                let t = lexer.text(token.range)
                switch token.kind {
                case .parameter where t == "?" && styles.contains(.positional):
                    positional += 1
                    key = "?\(positional)"
                case .parameter where t.hasPrefix("$") && styles.contains(.numbered):
                    key = t
                case .operator where t == ":" && styles.contains(.named):
                    guard i + 1 < tokens.count, [.word, .keyword].contains(tokens[i + 1].kind),
                          tokens[i + 1].range.lowerBound == token.range.upperBound else { break }
                    if i > 0 {
                        let before = tokens[i - 1]
                        let b = lexer.text(before.range)
                        let adjacent = before.range.upperBound == token.range.lowerBound
                        if adjacent && ([.word, .keyword, .number, .quotedIdentifier].contains(before.kind) || b == ":" || b == "]" || b == ")") {
                            break
                        }
                    }
                    range = token.range.lowerBound..<tokens[i + 1].range.upperBound
                    key = ":" + lexer.text(tokens[i + 1].range)
                default:
                    break
                }
                guard let key else { continue }
                occurrences.append(Occurrence(statement: s, range: range, key: key))
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
        return (keys, occurrences)
    }

    /// How a typed value is written into the SQL.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        /// Numbers, NULL, TRUE and FALSE as typed; anything else as a quoted string.
        case auto
        /// Always a quoted string.
        case text
        /// As typed: an expression, a column, a list for IN (…).
        case sql
    }

    /// The SQL a value stands for.
    public static func sql(for input: String, kind: Kind, dialect: any Dialect) -> String {
        switch kind {
        case .sql:
            return input
        case .text:
            return dialect.literal(.text(input))
        case .auto:
            let t = input.trimmingCharacters(in: .whitespaces)
            if ["NULL", "TRUE", "FALSE"].contains(t.uppercased()) { return t.uppercased() }
            if t.wholeMatch(of: /[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?/) != nil { return t }
            return dialect.literal(.text(input))
        }
    }

    /// The statements with every placeholder replaced by its value's SQL. Keys without a value
    /// are left as written.
    public static func substitute(_ statements: [String], _ occurrences: [Occurrence], values: [String: String]) -> [String] {
        statements.enumerated().map { s, text in
            var units = Array(text.utf16)
            // Back to front, so earlier ranges stay valid.
            for o in occurrences.filter({ $0.statement == s }).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                guard let value = values[o.key] else { continue }
                units.replaceSubrange(o.range, with: Array(value.utf16))
            }
            return String(decoding: units, as: UTF16.self)
        }
    }
}
