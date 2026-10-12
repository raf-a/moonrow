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
    /// `expression ILIKE pattern`, the pattern as given.
    func caseInsensitiveLike(_ expression: String, _ pattern: DBValue) -> SQLFragment
    func limitClause(limit: Int?, offset: Int) -> String
    func insertDefaultValues(into table: String) -> String
    /// What `SET column = …` writes to restore the column's default.
    func defaultValue(for column: ColumnInfo) -> String

    var beginTransaction: String { get }
    var commitTransaction: String { get }
    var rollbackTransaction: String { get }

    /// Whether an unsorted page is ordered by the primary key. Postgres's scan order can change
    /// between OFFSETs (synchronized scans); MySQL's pages are ordered too.
    /// SQLite's rowid scan is stable.
    var pagesNeedKeyOrder: Bool { get }
    /// Whether DDL can run inside a transaction and roll back with it. MySQL commits each DDL
    /// statement (TRUNCATE included) as it runs.
    var transactionalDDL: Bool { get }

    /// Makes `schema` where unqualified names resolve for the rest of the session; nil where
    /// the database has a single namespace.
    func useSchema(_ schema: String) -> String?

    // MARK: DDL (see DDL.swift)

    /// Column types the structure editor offers; any other type can be typed in.
    var commonTypes: [String] { get }
    /// DDL that turns `change.original` into `change.design`. Throws when the database can't
    /// make the change.
    func alterTable(_ change: StructureChange) throws -> DDLPlan
    func createTable(_ design: TableDesign, schema: String?) -> DDLPlan
    func drop(_ object: DatabaseObject, options: DropOptions) throws -> DDLPlan
    /// `hasAutoIncrement`: SQLite keeps an AUTOINCREMENT counter apart from the rows.
    func truncate(_ table: TableRef, options: TruncateOptions, hasAutoIncrement: Bool) -> DDLPlan
    func rename(_ object: DatabaseObject, to name: String) throws -> DDLPlan
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

    /// No ILIKE outside Postgres: lower-case both sides.
    public func caseInsensitiveLike(_ expression: String, _ pattern: DBValue) -> SQLFragment {
        "LOWER(\(expression)) LIKE LOWER(" + .value(pattern) + ")"
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
    public var pagesNeedKeyOrder: Bool { false }
    public var transactionalDDL: Bool { true }
    public func useSchema(_ schema: String) -> String? { nil }

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
