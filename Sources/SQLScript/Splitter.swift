/// One statement found in a script. Ranges are UTF-16 offsets (NSRange-compatible).
public struct SQLStatementRange: Sendable, Hashable {
    /// The statement itself: leading comments included, surrounding whitespace and the
    /// delimiter excluded.
    public var range: Range<Int>
    /// From the end of the previous delimiter through this statement's delimiter.
    public var fullRange: Range<Int>
    public var text: String
    /// The delimiter in effect when the statement ended (MySQL's `DELIMITER` can change it).
    public var delimiter: String = ";"
}

public enum SQLSplitter {
    /// Splits a script into statements. Statements that contain only comments are dropped.
    /// `delimiter` is the one in effect at the start (a script continued after `DELIMITER //`).
    public static func split(_ sql: String, dialect: LexerDialect, delimiter: String = ";") -> [SQLStatementRange] {
        split(SQLLexer(sql, dialect: dialect), delimiter: Array(delimiter.utf16))
    }

    /// The statement the editor should run for a cursor at `offset` (UTF-16).
    ///
    /// Inside a statement (or touching its end) → that statement. In the gap between two
    /// statements → the previous one if the cursor is still on its last line, else the next.
    /// A comment after `;` leads the next statement, so the end of `select 1; -- note`
    /// runs the next one.
    public static func statement(
        at offset: Int, in sql: String, dialect: LexerDialect
    ) -> SQLStatementRange? {
        let lexer = SQLLexer(sql, dialect: dialect)
        let statements = split(lexer)
        if let hit = statements.first(where: {
            $0.range.contains(offset) || $0.range.upperBound == offset
        }) {
            return hit
        }
        let previous = statements.last { $0.range.upperBound <= offset }
        let next = statements.first { $0.range.lowerBound > offset }
        if let previous {
            let gap = lexer.units[previous.range.upperBound..<offset]
            if !gap.contains(ch("\n")) || next == nil { return previous }
        }
        return next
    }

    static func split(_ lexer: SQLLexer, delimiter initial: [UInt16] = [ch(";")]) -> [SQLStatementRange] {
        let units = lexer.units
        let dialect = lexer.dialect
        var out: [SQLStatementRange] = []

        var delimiter: [UInt16] = initial.isEmpty ? [ch(";")] : initial
        var segmentStart = 0
        var first: Int?
        var lastEnd = 0
        var hasCode = false
        var leadingWords: [String] = []
        var lastWord: String?
        var skipUntil = 0

        func finish(at end: Int) {
            if hasCode, let first {
                out.append(SQLStatementRange(
                    range: first..<lastEnd,
                    fullRange: segmentStart..<end,
                    text: lexer.text(first..<lastEnd),
                    delimiter: String(decoding: delimiter, as: UTF16.self)))
            }
            segmentStart = end
            first = nil
            hasCode = false
            leadingWords = []
            lastWord = nil
        }

        func isTrigger() -> Bool {
            guard dialect.triggerBodies, leadingWords.first == "CREATE" else { return false }
            let rest = leadingWords.dropFirst().drop { $0 == "TEMP" || $0 == "TEMPORARY" }
            return rest.first == "TRIGGER"
        }

        for token in lexer.tokens() where token.range.lowerBound >= skipUntil {
            let kind = token.kind

            // MySQL-client `DELIMITER xx` line at the start of a statement.
            if dialect.delimiterCommand, !hasCode, kind == .word || kind == .keyword,
               lexer.text(token.range).uppercased() == "DELIMITER" {
                var lineEnd = token.range.upperBound
                while lineEnd < units.count, units[lineEnd] != ch("\n") { lineEnd += 1 }
                let newDelimiter = Array(units[token.range.upperBound..<lineEnd].drop(while: isSpace))
                    .reversed().drop(while: isSpace).reversed()
                if !newDelimiter.isEmpty {
                    delimiter = Array(newDelimiter)
                    skipUntil = lineEnd
                    first = nil
                    segmentStart = lineEnd
                    continue
                }
            }

            if !kind.isOpaque, matches(units, delimiter, at: token.range.lowerBound) {
                let inTriggerBody = delimiter == [ch(";")] && isTrigger() && lastWord != "END"
                if !inTriggerBody {
                    let end = token.range.lowerBound + delimiter.count
                    finish(at: end)
                    skipUntil = end
                    continue
                }
            }

            // A comment after the delimiter, even on its line, starts the next statement
            // (`select 1; -- note` → the note leads statement 2).
            if kind == .whitespace { continue }
            if first == nil { first = token.range.lowerBound }
            lastEnd = token.range.upperBound
            if kind.isComment, !(kind == .blockComment && dialect.executableComments && isExecutable(units, token.range)) {
                continue
            }
            hasCode = true
            if kind == .word || kind == .keyword {
                let word = lexer.text(token.range).uppercased()
                if leadingWords.count < 3 { leadingWords.append(word) }
                lastWord = word
            } else {
                if leadingWords.count < 3 { leadingWords.append("") }
                lastWord = nil
            }
        }
        finish(at: units.count)
        return out
    }

    /// `/*!…*/` or `/*M!…*/`.
    private static func isExecutable(_ units: [UInt16], _ range: Range<Int>) -> Bool {
        let start = range.lowerBound + 2
        guard start < range.upperBound else { return false }
        return units[start] == ch("!") || (units[start] == ch("M") && start + 1 < range.upperBound && units[start + 1] == ch("!"))
    }

    private static func matches(_ units: [UInt16], _ needle: [UInt16], at i: Int) -> Bool {
        guard i + needle.count <= units.count else { return false }
        for k in needle.indices where units[i + k] != needle[k] { return false }
        return true
    }
}
