/// Whether a statement only reads, for safe mode's "warn on everything but reads" levels.
///
/// Reads are the statement families that return data without changing it: SELECT, a WITH whose
/// parts are all queries, VALUES, TABLE, SHOW, DESCRIBE and EXPLAIN (unless it is EXPLAIN
/// ANALYZE of a write, which runs the write). Everything else counts as a write, including
/// session commands (SET, USE, BEGIN), PRAGMA and CALL: when in doubt, ask.
///
/// A SELECT that calls a function with side effects still counts as a read; nothing short of
/// running it can tell.
public enum SQLStatementKind: Sendable, Hashable {
    case read
    case write
}

public enum SQLClassifier {
    public static func kind(of sql: String, dialect: LexerDialect) -> SQLStatementKind {
        let lexer = SQLLexer(sql, dialect: dialect)
        let words = lexer.tokens().compactMap { token -> Word? in
            switch token.kind {
            case .word, .keyword: Word(text: lexer.text(token.range).uppercased(), depth: 0)
            case .punctuation:
                switch lexer.units[token.range.lowerBound] {
                case ch("("): Word(text: "(", depth: 0)
                case ch(")"): Word(text: ")", depth: 0)
                default: nil
                }
            default: nil
            }
        }
        return kind(of: withDepth(words)[...])
    }

    private struct Word {
        var text: String
        /// Parentheses around the word.
        var depth: Int
    }

    /// Drops the parentheses, recording how deep each word sits.
    private static func withDepth(_ words: [Word]) -> [Word] {
        var depth = 0
        var out: [Word] = []
        for var w in words {
            if w.text == "(" { depth += 1; continue }
            if w.text == ")" { depth = max(0, depth - 1); continue }
            w.depth = depth
            out.append(w)
        }
        return out
    }

    private static let readFirstWords: Set<String> = ["SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE"]
    private static let writeWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE", "TRUNCATE"]
    /// Words that can start the statement an EXPLAIN describes.
    private static let explainable: Set<String> = [
        "SELECT", "WITH", "VALUES", "TABLE", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE",
        "CREATE", "DECLARE", "EXECUTE",
    ]

    private static func kind(of words: ArraySlice<Word>) -> SQLStatementKind {
        guard let first = words.first else { return .read }
        // `(SELECT …) UNION (SELECT …)` starts inside parentheses.
        let top = first.depth
        switch first.text {
        case "SELECT":
            // SELECT … INTO creates a table (Postgres) or writes a file or variables (MySQL).
            return words.contains { $0.text == "INTO" } ? .write : .read
        case "WITH":
            return words.contains { writeWords.contains($0.text) || $0.text == "INTO" } ? .write : .read
        case "EXPLAIN":
            let rest = words.dropFirst()
            guard let start = rest.firstIndex(where: { explainable.contains($0.text) && $0.depth == top }) else { return .read }
            let analyzes = rest[..<start].contains { $0.text == "ANALYZE" || $0.text == "ANALYSE" }
            return analyzes ? kind(of: words[start...]) : .read
        default:
            return readFirstWords.contains(first.text) ? .read : .write
        }
    }
}
