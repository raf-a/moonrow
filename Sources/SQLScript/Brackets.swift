/// Matching parentheses for the editor. Parentheses inside strings, comments and quoted names
/// don't count.
public enum SQLBrackets {
    /// For a cursor at `offset` (UTF-16) next to a parenthesis, the offset of its partner: the
    /// one just before the cursor first, else the one just after it. Nil when neither is a
    /// parenthesis or it has no partner.
    public static func match(at offset: Int, in text: String, dialect: LexerDialect) -> Int? {
        let lexer = SQLLexer(text, dialect: dialect)
        let units = lexer.units
        let open = ch("("), close = ch(")")
        let candidates = [offset - 1, offset].filter { $0 >= 0 && $0 < units.count && (units[$0] == open || units[$0] == close) }
        guard !candidates.isEmpty else { return nil }
        let brackets = lexer.tokens().filter { $0.kind == .punctuation && $0.range.count == 1 }
            .map(\.range.lowerBound).filter { units[$0] == open || units[$0] == close }
        for at in candidates {
            guard let index = brackets.firstIndex(of: at) else { continue }
            var depth = 0
            if units[at] == open {
                for i in brackets[index...] {
                    depth += units[i] == open ? 1 : -1
                    if depth == 0 { return i }
                }
            } else {
                for i in brackets[...index].reversed() {
                    depth += units[i] == close ? 1 : -1
                    if depth == 0 { return i }
                }
            }
        }
        return nil
    }
}
