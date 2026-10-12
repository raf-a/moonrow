public struct SortKey: Sendable, Hashable {
    public var column: String
    public var ascending: Bool

    public init(_ column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// One page of a table, as the data grid asks for it.
public struct BrowseRequest: Sendable, Hashable {
    public var table: TableRef
    /// Nil selects every column.
    public var columns: [String]?
    public var filter: Filter?
    public var sort: [SortKey]
    public var limit: Int?
    public var offset: Int

    public init(
        _ table: TableRef, columns: [String]? = nil, filter: Filter? = nil,
        sort: [SortKey] = [], limit: Int? = nil, offset: Int = 0
    ) {
        self.table = table
        self.columns = columns
        self.filter = filter
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }
}

extension Dialect {
    /// `allColumns` is the table's column list, used by `.anyColumn` filters.
    public func select(_ request: BrowseRequest, allColumns: [String]) -> SQLFragment {
        let list = request.columns?.map(quoteIdentifier).joined(separator: ", ") ?? "*"
        var sql = SQLFragment("SELECT \(list) FROM \(qualified(request.table))")
        sql.append(whereClause(request.filter, allColumns: allColumns))
        if !request.sort.isEmpty {
            let keys = request.sort.map { quoteIdentifier($0.column) + ($0.ascending ? " ASC" : " DESC") }
            sql.append(" ORDER BY " + keys.joined(separator: ", "))
        }
        sql.append(limitClause(limit: request.limit, offset: request.offset))
        return sql
    }

    public func count(_ table: TableRef, filter: Filter? = nil, allColumns: [String]) -> SQLFragment {
        SQLFragment("SELECT COUNT(*) FROM \(qualified(table))")
            + whereClause(filter, allColumns: allColumns)
    }

    /// A planner estimate of the table's rows, cheaper than COUNT(*); nil where the database
    /// keeps none worth showing. The result is one integer, negative when unknown.
    public func estimatedCount(_ table: TableRef) -> SQLFragment? {
        guard self is PostgresDialect else { return nil }
        // reltuples is -1 until the table is first vacuumed or analyzed (PG 14+).
        return "SELECT reltuples::bigint FROM pg_class WHERE oid = " + .value(.text(qualified(table))) + "::regclass"
    }

    private func whereClause(_ filter: Filter?, allColumns: [String]) -> SQLFragment {
        guard let filter, let p = predicate(for: filter, columns: allColumns) else { return SQLFragment() }
        return " WHERE " + p
    }
}
