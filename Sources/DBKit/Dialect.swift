import Foundation
import SQLScript

public enum PatternKind: Sendable, Hashable {
    case contains, hasPrefix, hasSuffix
}

/// Everything about a database's SQL that the app needs to generate statements.
/// Pure: no connection, so it can be tested on its own.
public protocol Dialect: Sendable {
    var name: String { get }
    var lexer: LexerDialect { get }

    func quoteIdentifier(_ name: String) -> String
    /// Placeholder for the `index`th binding (1-based).
    func placeholder(_ index: Int) -> String
    /// SQL literal for previews.
    func literal(_ value: DBValue) -> String
    /// Converts any column expression to text, for text filters.
    func textCast(_ expression: String) -> String
    /// `expression [NOT] LIKE pattern`, in whatever form the database needs.
    func patternMatch(
        _ expression: String, _ kind: PatternKind, _ value: String,
        caseSensitive: Bool, negated: Bool
    ) -> SQLFragment
    func limitClause(limit: Int?, offset: Int) -> String
    func insertDefaultValues(into table: String) -> String
    /// What `SET column = …` writes to restore the column's default.
    func defaultValue(for column: ColumnInfo) -> String

    var beginTransaction: String { get }
    var commitTransaction: String { get }
    var rollbackTransaction: String { get }
}

extension Dialect {
    public func qualified(_ table: TableRef) -> String {
        if let schema = table.schema { return quoteIdentifier(schema) + "." + quoteIdentifier(table.name) }
        return quoteIdentifier(table.name)
    }

    public func placeholder(_ index: Int) -> String { "?" }

    public func textCast(_ expression: String) -> String { "CAST(\(expression) AS TEXT)" }

    public func patternMatch(
        _ expression: String, _ kind: PatternKind, _ value: String,
        caseSensitive: Bool, negated: Bool
    ) -> SQLFragment {
        let not = negated ? " NOT" : ""
        let pattern = DBValue.text(likePattern(kind, value))
        if caseSensitive {
            return "\(expression)\(not) LIKE " + .value(pattern)
        }
        return "LOWER(\(expression))\(not) LIKE LOWER(" + .value(pattern) + ")"
    }

    public func limitClause(limit: Int?, offset: Int) -> String {
        var s = ""
        if let limit { s += " LIMIT \(limit)" }
        if offset > 0 { s += " OFFSET \(offset)" }
        return s
    }

    public func insertDefaultValues(into table: String) -> String {
        "INSERT INTO \(table) DEFAULT VALUES"
    }

    public func defaultValue(for column: ColumnInfo) -> String { "DEFAULT" }

    public var beginTransaction: String { "BEGIN" }
    public var commitTransaction: String { "COMMIT" }
    public var rollbackTransaction: String { "ROLLBACK" }

    /// LIKE pattern with `\` as the escape character.
    public func likePattern(_ kind: PatternKind, _ value: String) -> String {
        var escaped = ""
        for c in value {
            if c == "\\" || c == "%" || c == "_" { escaped.append("\\") }
            escaped.append(c)
        }
        switch kind {
        case .contains: return "%\(escaped)%"
        case .hasPrefix: return "\(escaped)%"
        case .hasSuffix: return "%\(escaped)"
        }
    }

    /// `"…"` with embedded quote characters doubled.
    public func quote(_ s: String, with q: Character) -> String {
        var out = String(q)
        for c in s {
            if c == q { out.append(q) }
            out.append(c)
        }
        out.append(q)
        return out
    }

    func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
