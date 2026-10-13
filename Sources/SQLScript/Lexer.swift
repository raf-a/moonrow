/// Lexical rules that differ between databases.
public struct LexerDialect: Sendable, Hashable {
    /// `"x"` is an identifier (ANSI). When false (MySQL default) it is a string.
    public var doubleQuoteIsIdentifier: Bool
    public var backtickIdentifiers: Bool
    public var bracketIdentifiers: Bool
    /// PostgreSQL `$tag$ … $tag$` bodies.
    public var dollarQuotedStrings: Bool
    public var hashLineComments: Bool
    /// `\'` escapes inside `'…'` (MySQL default; PostgreSQL only for `E'…'`).
    public var backslashEscapes: Bool
    public var nestedBlockComments: Bool
    /// Client-side `DELIMITER //` lines (MySQL clients).
    public var delimiterCommand: Bool
    /// `CREATE TRIGGER … BEGIN …; …; END;` keeps its inner semicolons (SQLite).
    public var triggerBodies: Bool
    /// `/*! … */` and `/*M! … */` are code the server runs (MySQL, MariaDB), not comments.
    public var executableComments: Bool
    public var keywords: Set<String>

    public init(
        doubleQuoteIsIdentifier: Bool = true,
        backtickIdentifiers: Bool = false,
        bracketIdentifiers: Bool = false,
        dollarQuotedStrings: Bool = false,
        hashLineComments: Bool = false,
        backslashEscapes: Bool = false,
        nestedBlockComments: Bool = false,
        delimiterCommand: Bool = false,
        triggerBodies: Bool = false,
        executableComments: Bool = false,
        keywords: Set<String> = SQLKeywords.common
    ) {
        self.doubleQuoteIsIdentifier = doubleQuoteIsIdentifier
        self.backtickIdentifiers = backtickIdentifiers
        self.bracketIdentifiers = bracketIdentifiers
        self.dollarQuotedStrings = dollarQuotedStrings
        self.hashLineComments = hashLineComments
        self.backslashEscapes = backslashEscapes
        self.nestedBlockComments = nestedBlockComments
        self.delimiterCommand = delimiterCommand
        self.triggerBodies = triggerBodies
        self.executableComments = executableComments
        self.keywords = keywords
    }

    public static let sqlite = LexerDialect(
        backtickIdentifiers: true, bracketIdentifiers: true, triggerBodies: true)
    public static let postgres = LexerDialect(
        dollarQuotedStrings: true, nestedBlockComments: true)
    public static let mysql = LexerDialect(
        doubleQuoteIsIdentifier: false, backtickIdentifiers: true, hashLineComments: true,
        backslashEscapes: true, delimiterCommand: true, executableComments: true)
}

public enum TokenKind: Sendable, Hashable {
    case whitespace
    case lineComment
    case blockComment
    case string
    case quotedIdentifier
    case word
    case keyword
    case number
    /// `?`, `$1`
    case parameter
    case semicolon
    /// `(`, `)`, `,`, `.`
    case punctuation
    case `operator`

    public var isComment: Bool { self == .lineComment || self == .blockComment }
    public var isTrivia: Bool { self == .whitespace || isComment }
    public var isOpaque: Bool { isTrivia || self == .string || self == .quotedIdentifier }
}

/// A token. `range` is in UTF-16 code units, so it maps directly onto `NSRange`.
public struct Token: Sendable, Hashable {
    public var kind: TokenKind
    public var range: Range<Int>
}

public struct SQLLexer: Sendable {
    public let units: [UInt16]
    public let dialect: LexerDialect

    public init(_ text: String, dialect: LexerDialect) {
        self.units = Array(text.utf16)
        self.dialect = dialect
    }

    public func text(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    public func tokens() -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < units.count {
            let start = i
            let kind = scan(&i)
            out.append(Token(kind: kind, range: start..<i))
        }
        return out
    }

    // MARK: - Scanning

    private func at(_ i: Int) -> UInt16? { i < units.count ? units[i] : nil }

    private func scan(_ i: inout Int) -> TokenKind {
        let c = units[i]
        let next = at(i + 1)

        if isSpace(c) {
            while let u = at(i), isSpace(u) { i += 1 }
            return .whitespace
        }
        if (c == ch("-") && next == ch("-")) || (c == ch("#") && dialect.hashLineComments) {
            while let u = at(i), u != ch("\n") { i += 1 }
            return .lineComment
        }
        if c == ch("/") && next == ch("*") {
            scanBlockComment(&i)
            return .blockComment
        }
        if c == ch("'") {
            scanQuoted(&i, close: c, backslash: dialect.backslashEscapes)
            return .string
        }
        if c == ch("\"") {
            let isIdent = dialect.doubleQuoteIsIdentifier
            scanQuoted(&i, close: c, backslash: !isIdent && dialect.backslashEscapes)
            return isIdent ? .quotedIdentifier : .string
        }
        if c == ch("`") && dialect.backtickIdentifiers {
            scanQuoted(&i, close: c, backslash: false)
            return .quotedIdentifier
        }
        if c == ch("[") && dialect.bracketIdentifiers {
            while let u = at(i + 1), u != ch("]") { i += 1 }
            i = min(i + 2, units.count)
            return .quotedIdentifier
        }
        if c == ch("$") {
            if let n = next, isDigit(n) {
                i += 1
                while let u = at(i), isDigit(u) { i += 1 }
                return .parameter
            }
            if dialect.dollarQuotedStrings, scanDollarQuoted(&i) { return .string }
            i += 1
            return .operator
        }
        if isDigit(c) || (c == ch(".") && next.map(isDigit) == true) {
            scanNumber(&i)
            return .number
        }
        if isIdentStart(c) {
            let wordStart = i
            while let u = at(i), isIdentPart(u) { i += 1 }
            // One-letter string prefixes: E'…' (backslash escapes), X'…', B'…', N'…'.
            let lower = c | 0x20
            if i - wordStart == 1, at(i) == ch("'"),
               [ch("e"), ch("x"), ch("b"), ch("n")].contains(lower) {
                scanQuoted(&i, close: ch("'"),
                           backslash: lower == ch("e") || dialect.backslashEscapes)
                return .string
            }
            return dialect.keywords.contains(text(wordStart..<i).uppercased()) ? .keyword : .word
        }
        i += 1
        switch c {
        case ch(";"): return .semicolon
        case ch("("), ch(")"), ch(","), ch("."): return .punctuation
        case ch("?"): return .parameter
        default: return .operator
        }
    }

    private func scanQuoted(_ i: inout Int, close: UInt16, backslash: Bool) {
        i += 1
        while let u = at(i) {
            if backslash && u == ch("\\") { i += 2; continue }
            if u == close {
                if at(i + 1) == close { i += 2; continue }
                i += 1
                return
            }
            i += 1
        }
        i = units.count
    }

    private func scanBlockComment(_ i: inout Int) {
        var depth = 1
        i += 2
        while let u = at(i) {
            if dialect.nestedBlockComments && u == ch("/") && at(i + 1) == ch("*") {
                depth += 1; i += 2
            } else if u == ch("*") && at(i + 1) == ch("/") {
                depth -= 1; i += 2
                if depth == 0 { return }
            } else {
                i += 1
            }
        }
    }

    /// `$tag$ … $tag$`. Returns false (and leaves `i`) if this `$` doesn't open one.
    private func scanDollarQuoted(_ i: inout Int) -> Bool {
        var j = i + 1
        while let u = at(j), isIdentPart(u), u != ch("$") { j += 1 }
        guard at(j) == ch("$") else { return false }
        let tag = Array(units[i...j])
        var k = j + 1
        while k + tag.count <= units.count {
            if units[k] == ch("$") && Array(units[k..<(k + tag.count)]) == tag {
                i = k + tag.count
                return true
            }
            k += 1
        }
        i = units.count
        return true
    }

    private func scanNumber(_ i: inout Int) {
        while let u = at(i), isDigit(u) || u == ch(".") { i += 1 }
        if let e = at(i), e | 0x20 == ch("e") {
            var j = i + 1
            if let s = at(j), s == ch("+") || s == ch("-") { j += 1 }
            if let d = at(j), isDigit(d) {
                i = j
                while let u = at(i), isDigit(u) { i += 1 }
            }
        }
    }
}

// MARK: - Character classes (ASCII; anything >= 0x80 counts as an identifier unit)

@inline(__always) func ch(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
@inline(__always) func isSpace(_ u: UInt16) -> Bool { u == 0x20 || (u >= 0x09 && u <= 0x0D) }
@inline(__always) func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
@inline(__always) func isIdentStart(_ u: UInt16) -> Bool {
    (u | 0x20 >= 0x61 && u | 0x20 <= 0x7A) || u == ch("_") || u >= 0x80
}
@inline(__always) func isIdentPart(_ u: UInt16) -> Bool {
    isIdentStart(u) || isDigit(u) || u == ch("$")
}
