import DBKit
import Foundation

/// Search in Database: a text across every column of the chosen tables. Each table gets one
/// `COUNT(*)` with the filter bar's "Any column" condition, so opening a table with that
/// condition shows exactly the rows counted. It runs on a session of its own; stopping the
/// consumer cancels the statement running.
public enum DatabaseSearch {
    public enum Operator: String, Sendable, Hashable, CaseIterable {
        case contains, notContains, equals, hasPrefix, hasSuffix

        public var title: String {
            switch self {
            case .contains: "Contains"
            case .notContains: "Doesn't contain"
            case .equals: "="
            case .hasPrefix: "Starts with"
            case .hasSuffix: "Ends with"
            }
        }

        var filterOperator: FilterOperator {
            switch self {
            case .contains: .contains
            case .notContains: .notContains
            case .equals: .equal
            case .hasPrefix: .hasPrefix
            case .hasSuffix: .hasSuffix
            }
        }
    }

    public struct Request: Sendable, Hashable {
        public var term: String
        public var op: Operator
        /// In the order searched.
        public var tables: [TableRef]

        public init(term: String, op: Operator = .contains, tables: [TableRef]) {
            self.term = term
            self.op = op
            self.tables = tables
        }

        /// The filter bar condition that shows a table's matching rows.
        public var condition: FilterCondition { FilterCondition(.anyColumn, op.filterOperator, term) }
    }

    /// A table with matching rows.
    public struct Hit: Sendable, Hashable {
        public var table: TableRef
        public var count: Int
    }

    public enum Event: Sendable {
        /// About to search `table` (`index` of `count`, from 0).
        case searching(TableRef, index: Int, count: Int)
        /// A table with at least one matching row.
        case found(Hit)
        /// A table that couldn't be searched; the search goes on.
        case failed(TableRef, String)
    }

    /// The `COUNT(*)` for one table, or nil when there's nothing to search.
    public static func statement(_ request: Request, table: TableRef, columns: [String], dialect: any Dialect) -> SQLFragment? {
        guard !request.term.isEmpty,
              let predicate = dialect.predicate(for: Filter([request.condition]), columns: columns) else { return nil }
        return "SELECT COUNT(*) FROM \(dialect.qualified(table)) WHERE " + predicate
    }

    /// Searches table by table. Ends after the last table; cancelling the consumer stops it.
    public static func run(_ request: Request, on connection: any DatabaseConnection) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                for (i, table) in request.tables.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(.searching(table, index: i, count: request.tables.count))
                    do {
                        let columns = try await connection.columns(of: table).map(\.name)
                        guard let sql = statement(request, table: table, columns: columns, dialect: connection.dialect)
                        else { continue }
                        let result = try await connection.execute(sql)
                        if Task.isCancelled { break }
                        let count: Int = switch result.rows.first?.first {
                        case .integer(let n): Int(n)
                        case .text(let s): Int(s) ?? 0
                        default: 0
                        }
                        if count > 0 { continuation.yield(.found(Hit(table: table, count: count))) }
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.failed(table, "\(error)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
