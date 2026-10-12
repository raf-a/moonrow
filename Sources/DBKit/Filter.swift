import Foundation


/// Operators offered by the grid's filter bar.
public enum FilterOperator: String, Sendable, Hashable, CaseIterable {
    case equal = "="
    case notEqual = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case `in` = "IN"
    case notIn = "NOT IN"
    case between = "BETWEEN"
    case notBetween = "NOT BETWEEN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case isEmpty = "EMPTY"
    /// The value is the pattern as typed: `%` and `_` stay wildcards.
    case like = "LIKE"
    case ilike = "ILIKE"
    case contains = "Contains"
    case notContains = "Not contains"
    case hasPrefix = "Has prefix"
    case hasSuffix = "Has suffix"
    /// The value is a raw SQL predicate, inserted as-is.
    case raw = "Raw SQL"

    public var takesValue: Bool { ![.isNull, .isNotNull, .isEmpty].contains(self) }
    public var takesSecondValue: Bool { self == .between || self == .notBetween }
}

public enum FilterTarget: Sendable, Hashable {
    case column(String)
    /// The condition holds for at least one column.
    case anyColumn
}

public struct FilterCondition: Sendable, Hashable {
    public var target: FilterTarget
    public var op: FilterOperator
    /// As typed. For IN / NOT IN, comma-separated.
    public var value: String
    public var secondValue: String
    /// For the Contains / prefix / suffix family.
    public var caseSensitive: Bool

    public init(
        _ target: FilterTarget, _ op: FilterOperator, _ value: String = "",
        _ secondValue: String = "", caseSensitive: Bool = false
    ) {
        self.target = target
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.caseSensitive = caseSensitive
    }
}

public struct Filter: Sendable, Hashable {
    public var conditions: [FilterCondition]
    /// AND when true, OR when false.
    public var matchAll: Bool

    public init(_ conditions: [FilterCondition], matchAll: Bool = true) {
        self.conditions = conditions
        self.matchAll = matchAll
    }
}

extension Dialect {
    /// The predicate for a filter, without the `WHERE` keyword. Nil if there's nothing to filter.
    /// `columns` is needed for `.anyColumn`.
    public func predicate(for filter: Filter, columns: [String]) -> SQLFragment? {
        let parts = filter.conditions.compactMap { predicate(for: $0, columns: columns) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0] }
        return parts.map { "(" + $0 + ")" }.joined(separator: filter.matchAll ? " AND " : " OR ")
    }

    public func predicate(for condition: FilterCondition, columns: [String]) -> SQLFragment? {
        if condition.op == .raw {
            let raw = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : SQLFragment(raw)
        }
        switch condition.target {
        case .column(let name):
            return predicate(condition, on: quoteIdentifier(name), anyColumn: false)
        case .anyColumn:
            guard !columns.isEmpty else { return nil }
            let each = columns.map { predicate(condition, on: quoteIdentifier($0), anyColumn: true) }
            if each.count == 1 { return each[0] }
            // NOT-style operators must hold for every column to mean "no column matches".
            let joiner = [.notEqual, .notIn, .notContains].contains(condition.op) ? " AND " : " OR "
            return "(" + each.joined(separator: joiner) + ")"
        }
    }

    private func predicate(_ c: FilterCondition, on column: String, anyColumn: Bool) -> SQLFragment {
        // Compare as text when one value is matched against columns of mixed types.
        let lhs = anyColumn ? textCast(column) : column
        let value = DBValue.text(c.value)
        switch c.op {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual:
            return "\(lhs) \(c.op.rawValue) " + .value(value)
        case .in, .notIn:
            let items = c.value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if items.isEmpty { return SQLFragment(c.op == .in ? "1 = 0" : "1 = 1") }
            let list = items.map { SQLFragment.value(.text($0)) }.joined(separator: ", ")
            return "\(lhs) \(c.op.rawValue) (" + list + ")"
        case .between, .notBetween:
            return "\(lhs) \(c.op.rawValue) " + .value(value) + " AND " + .value(.text(c.secondValue))
        case .isNull:
            return SQLFragment("\(column) IS NULL")
        case .isNotNull:
            return SQLFragment("\(column) IS NOT NULL")
        case .isEmpty:
            return SQLFragment("\(textCast(column)) = ''")
        case .like:
            return "\(lhs) LIKE " + .value(value)
        case .ilike:
            return caseInsensitiveLike(lhs, value)
        case .contains, .notContains:
            return patternMatch(textCast(column), .contains, c.value,
                                caseSensitive: c.caseSensitive, negated: c.op == .notContains)
        case .hasPrefix:
            return patternMatch(textCast(column), .hasPrefix, c.value,
                                caseSensitive: c.caseSensitive, negated: false)
        case .hasSuffix:
            return patternMatch(textCast(column), .hasSuffix, c.value,
                                caseSensitive: c.caseSensitive, negated: false)
        case .raw:
            return SQLFragment(c.value)
        }
    }
}
