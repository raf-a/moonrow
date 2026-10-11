/// A finished statement: SQL with dialect placeholders plus the values to bind.
public struct SQLStatement: Sendable, Hashable {
    public var sql: String
    public var bindings: [DBValue]

    public init(_ sql: String, bindings: [DBValue] = []) {
        self.sql = sql
        self.bindings = bindings
    }
}

/// SQL under construction. Values stay separate from the text, so the same fragment can
/// become a parameterized statement (to execute) or literal SQL (to preview).
public struct SQLFragment: Sendable, Hashable {
    public enum Part: Sendable, Hashable {
        case sql(String)
        case value(DBValue)
    }

    public private(set) var parts: [Part]

    public init(_ sql: String = "") {
        parts = sql.isEmpty ? [] : [.sql(sql)]
    }

    public static func value(_ v: DBValue) -> SQLFragment {
        var f = SQLFragment()
        f.parts = [.value(v)]
        return f
    }

    public var isEmpty: Bool { parts.isEmpty }

    public mutating func append(_ sql: String) { if !sql.isEmpty { parts.append(.sql(sql)) } }
    public mutating func append(_ other: SQLFragment) { parts += other.parts }
    public mutating func append(value: DBValue) { parts.append(.value(value)) }

    public static func + (lhs: SQLFragment, rhs: SQLFragment) -> SQLFragment {
        var f = lhs
        f.append(rhs)
        return f
    }

    public static func + (lhs: SQLFragment, rhs: String) -> SQLFragment {
        var f = lhs
        f.append(rhs)
        return f
    }

    public static func + (lhs: String, rhs: SQLFragment) -> SQLFragment {
        SQLFragment(lhs) + rhs
    }

    /// Parameterized form for execution.
    public func statement(for dialect: any Dialect) -> SQLStatement {
        var sql = ""
        var bindings: [DBValue] = []
        for part in parts {
            switch part {
            case .sql(let s): sql += s
            case .value(let v):
                bindings.append(v)
                sql += dialect.placeholder(bindings.count)
            }
        }
        return SQLStatement(sql, bindings: bindings)
    }

    /// Literal form for previews and copying. Not for execution.
    public func inlined(for dialect: any Dialect) -> String {
        parts.map {
            switch $0 {
            case .sql(let s): s
            case .value(let v): dialect.literal(v)
            }
        }.joined()
    }
}

extension Array where Element == SQLFragment {
    public func joined(separator: String) -> SQLFragment {
        var out = SQLFragment()
        for (i, f) in enumerated() {
            if i > 0 { out.append(separator) }
            out.append(f)
        }
        return out
    }
}
