import Foundation
import SQLScript

public struct SQLiteDialect: Dialect {
    public init() {}
    public var name: String { "SQLite" }
    public var lexer: LexerDialect { .sqlite }

    public func quoteIdentifier(_ name: String) -> String { quote(name, with: "\"") }

    public func literal(_ value: DBValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .double(let v): v.isNaN ? "NULL" : v.isInfinite ? (v < 0 ? "-9e999" : "9e999") : String(v)
        case .text(let v): quote(v, with: "'")
        case .blob(let d): "X'\(hex(d))'"
        case .bool(let v): v ? "1" : "0"
        }
    }

    public func patternMatch(
        _ expression: String, _ kind: PatternKind, _ value: String,
        caseSensitive: Bool, negated: Bool
    ) -> SQLFragment {
        let not = negated ? " NOT" : ""
        if caseSensitive {
            // SQLite's LIKE ignores ASCII case; GLOB doesn't.
            var escaped = ""
            for c in value {
                switch c {
                case "*": escaped += "[*]"
                case "?": escaped += "[?]"
                case "[": escaped += "[[]"
                default: escaped.append(c)
                }
            }
            let pattern = switch kind {
            case .contains: "*\(escaped)*"
            case .hasPrefix: "\(escaped)*"
            case .hasSuffix: "*\(escaped)"
            }
            return "\(expression)\(not) GLOB " + .value(.text(pattern))
        }
        return "\(expression)\(not) LIKE " + .value(.text(likePattern(kind, value))) + " ESCAPE '\\'"
    }

    /// SQLite has no `SET x = DEFAULT`; write the declared default instead.
    public func defaultValue(for column: ColumnInfo) -> String {
        guard let d = column.defaultExpression, !d.isEmpty else { return "NULL" }
        // pragma_table_info gives the expression as written; a bare function call such as
        // CURRENT_TIMESTAMP is fine, anything else is parenthesized to keep it one term.
        return d.first == "(" || d.allSatisfy({ $0.isLetter || $0 == "_" }) ? d : "(\(d))"
    }
}

public struct PostgresDialect: Dialect {
    public init() {}
    public var name: String { "PostgreSQL" }
    public var lexer: LexerDialect { .postgres }

    public func quoteIdentifier(_ name: String) -> String { quote(name, with: "\"") }
    public func placeholder(_ index: Int) -> String { "$\(index)" }
    public func textCast(_ expression: String) -> String { "\(expression)::text" }
    public var pagesNeedKeyOrder: Bool { true }

    /// The schema first, then `public`, so extensions installed there keep working.
    public func useSchema(_ schema: String) -> String? {
        schema == "public" ? "SET search_path TO public" : "SET search_path TO \(quoteIdentifier(schema)), public"
    }

    public func literal(_ value: DBValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .double(let v):
            v.isNaN ? "'NaN'::float8" : v.isInfinite ? (v < 0 ? "'-Infinity'::float8" : "'Infinity'::float8") : String(v)
        case .text(let v): quote(v, with: "'")
        case .blob(let d): "'\\x\(hex(d))'::bytea"
        case .bool(let v): v ? "TRUE" : "FALSE"
        }
    }

    public func patternMatch(
        _ expression: String, _ kind: PatternKind, _ value: String,
        caseSensitive: Bool, negated: Bool
    ) -> SQLFragment {
        let op = (negated ? "NOT " : "") + (caseSensitive ? "LIKE" : "ILIKE")
        return "\(expression) \(op) " + .value(.text(likePattern(kind, value)))
    }
}

public struct MySQLDialect: Dialect {
    public init() {}
    public var name: String { "MySQL" }
    public var lexer: LexerDialect { .mysql }

    public func quoteIdentifier(_ name: String) -> String { quote(name, with: "`") }
    public func textCast(_ expression: String) -> String { "CAST(\(expression) AS CHAR)" }

    public func literal(_ value: DBValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .double(let v): v.isFinite ? String(v) : "NULL"
        case .text(let v): Self.escapedString(v)
        case .blob(let d): "X'\(hex(d))'"
        case .bool(let v): v ? "1" : "0"
        }
    }

    /// `'…'` escaped the way the server writes bound strings into its logs (the C API's
    /// escape_string rules). Assumes the server default, backslash escapes on.
    static func escapedString(_ s: String) -> String {
        var out = "'"
        for u in s.unicodeScalars {
            switch u {
            case "\0": out += "\\0"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\"": out += "\\\""
            case "\u{1A}": out += "\\Z"
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "'"
    }

    public func patternMatch(
        _ expression: String, _ kind: PatternKind, _ value: String,
        caseSensitive: Bool, negated: Bool
    ) -> SQLFragment {
        let not = negated ? " NOT" : ""
        let pattern = DBValue.text(likePattern(kind, value))
        if caseSensitive {
            return "CAST(\(expression) AS BINARY)\(not) LIKE CAST(" + .value(pattern) + " AS BINARY)"
        }
        return "LOWER(\(expression))\(not) LIKE LOWER(" + .value(pattern) + ")"
    }

    public func insertDefaultValues(into table: String) -> String {
        "INSERT INTO \(table) () VALUES ()"
    }

    public var beginTransaction: String { "START TRANSACTION" }

    public func useSchema(_ schema: String) -> String? { "USE \(quoteIdentifier(schema))" }
}
