import DBKit
import Foundation

/// Sorting a query result in memory, by one of its columns. The sort is stable: rows with equal
/// values keep the order the server returned them in. Ascending puts NULLs first, then numbers,
/// text and binary values; descending is the reverse.
public enum ResultSort {
    /// Indices into `rows`, in sorted order.
    public static func order(_ rows: [[DBValue]], column: Int, ascending: Bool) -> [Int] {
        let keys = rows.map { Key(column < $0.count ? $0[column] : .null) }
        return rows.indices.sorted { a, b in
            switch keys[a].compare(keys[b]) {
            case .orderedAscending: ascending
            case .orderedDescending: !ascending
            case .orderedSame: a < b
            }
        }
    }

    public static func compare(_ a: DBValue, _ b: DBValue) -> ComparisonResult {
        Key(a).compare(Key(b))
    }

    /// A value reduced to what it sorts by. Text that reads as a number (Postgres sends
    /// `numeric` as text) sorts as one.
    private enum Key {
        case null
        case number(Double)
        case text(String)
        case blob(Data)

        init(_ value: DBValue) {
            switch value {
            case .null: self = .null
            case .integer(let v): self = .number(Double(v))
            case .double(let v): self = .number(v)
            case .bool(let v): self = .number(v ? 1 : 0)
            case .text(let s): self = Double(s).map { $0.isNaN ? .text(s) : .number($0) } ?? .text(s)
            case .blob(let d): self = .blob(d)
            }
        }

        private var rank: Int {
            switch self {
            case .null: 0
            case .number: 1
            case .text: 2
            case .blob: 3
            }
        }

        func compare(_ other: Key) -> ComparisonResult {
            switch (self, other) {
            case (.number(let a), .number(let b)):
                return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case (.text(let a), .text(let b)):
                return a.localizedStandardCompare(b)
            case (.blob(let a), .blob(let b)):
                if a == b { return .orderedSame }
                return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
            default:
                return rank < other.rank ? .orderedAscending : rank > other.rank ? .orderedDescending : .orderedSame
            }
        }
    }
}
