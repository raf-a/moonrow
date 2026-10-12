import DBKit
import Foundation

/// Which rows of a table the grid shows: filter, sort and page.
public struct GridQuery: Sendable, Hashable {
    public var filter: Filter?
    public var sort: [SortKey]
    public var page: Paging

    public init(filter: Filter? = nil, sort: [SortKey] = [], page: Paging = Paging()) {
        self.filter = filter
        self.sort = sort
        self.page = page
    }

    /// Header clicks cycle a column through ascending, descending and unsorted. One column
    /// sorts at a time.
    public mutating func cycleSort(_ column: String) {
        switch sort.first(where: { $0.column == column })?.ascending {
        case nil: sort = [SortKey(column, ascending: true)]
        case true?: sort = [SortKey(column, ascending: false)]
        case false?: sort = []
        }
    }
}

/// A window of `pageSize` rows starting at `offset`. Without a page size the grid shows every
/// row (it is virtual, so that stays fast).
public struct Paging: Sendable, Hashable {
    public static let defaultPageSize = 300

    public var pageSize: Int?
    public var offset: Int

    public init(pageSize: Int? = Paging.defaultPageSize, offset: Int = 0) {
        self.pageSize = pageSize.flatMap { $0 > 0 ? $0 : nil }
        self.offset = max(0, offset)
    }

    /// Absolute row numbers on this page, for a result of `total` rows.
    public func rows(total: Int) -> Range<Int> {
        let start = min(offset, max(0, total))
        let end = pageSize.map { min(total, start + $0) } ?? total
        return start..<max(start, end)
    }

    public func next(total: Int) -> Paging? {
        guard let size = pageSize, offset + size < total else { return nil }
        return Paging(pageSize: size, offset: offset + size)
    }

    public var previous: Paging? {
        guard let size = pageSize, offset > 0 else { return nil }
        return Paging(pageSize: size, offset: max(0, offset - size))
    }

    /// "301–600 of 1,000" style description of the page.
    public func describe(total: Int, estimated: Bool = false) -> String {
        let rows = rows(total: total)
        let of = (estimated ? "~" : "") + total.formatted(.number)
        if rows.isEmpty { return total == 0 ? "No rows" : "No rows at offset \(offset.formatted(.number)) of \(of)" }
        if pageSize == nil && offset == 0 { return "\(of) \(total == 1 ? "row" : "rows")" }
        return "\((rows.lowerBound + 1).formatted(.number))–\(rows.upperBound.formatted(.number)) of \(of)"
    }
}

/// How many rows a table has, exactly or as the planner estimates it.
public struct RowCount: Sendable, Hashable {
    public var value: Int
    public var isEstimate: Bool

    public init(_ value: Int, isEstimate: Bool = false) {
        self.value = value
        self.isEstimate = isEstimate
    }
}

/// Everything the grid needs to show one table: its columns, its row count and a block fetcher.
public struct TableBrowser: Sendable {
    public let connection: any DatabaseConnection
    public let table: TableRef
    public let columns: [ColumnInfo]

    /// Reads the table's columns. Fails for objects that no longer exist.
    public static func open(_ table: TableRef, on connection: any DatabaseConnection) async throws -> TableBrowser {
        TableBrowser(connection: connection, table: table, columns: try await connection.columns(of: table))
    }

    public var dialect: any Dialect { connection.dialect }

    /// Rows matching the filter, across all pages.
    public func count(filter: Filter? = nil) async throws -> Int {
        let result = try await connection.execute(
            dialect.count(table, filter: filter, allColumns: columns.map(\.name)))
        guard case .integer(let n)? = result.rows.first?.first else {
            throw DatabaseError("COUNT(*) returned no integer")
        }
        return Int(n)
    }

    /// Unfiltered tables with at least this many rows (by the planner's estimate) show the
    /// estimate instead of being counted.
    public static let estimateThreshold = 1_000_000

    /// The row count the grid shows: the planner's estimate for a large unfiltered table where
    /// the database keeps one (Postgres), else `COUNT(*)`.
    public func rowCount(filter: Filter? = nil) async throws -> RowCount {
        if filter == nil, let sql = dialect.estimatedCount(table),
           case .integer(let n)? = try? await connection.execute(sql).rows.first?.first,
           n >= Self.estimateThreshold {
            return RowCount(Int(n), isEstimate: true)
        }
        return RowCount(try await count(filter: filter))
    }

    /// The SELECT for part of the current page. `offset` is relative to the page.
    public func select(_ query: GridQuery, offset: Int, limit: Int) -> SQLFragment {
        var sort = query.sort
        // Unsorted pages stay put across OFFSETs only where the scan order is stable; elsewhere
        // the primary key orders them (the header still shows no sort).
        if sort.isEmpty, dialect.pagesNeedKeyOrder { sort = columns.primaryKey.map { SortKey($0) } }
        let request = BrowseRequest(
            table, filter: query.filter, sort: sort, limit: limit, offset: query.page.offset + offset)
        return dialect.select(request, allColumns: columns.map(\.name))
    }

    /// Fetches blocks of the current page for `RowCache`. Without a sort, rows come in the
    /// database's natural order where that is stable (SQLite).
    public func fetcher(_ query: GridQuery) -> RowCache.Fetch {
        let browser = self
        return { offset, limit in
            try await browser.connection.execute(browser.select(query, offset: offset, limit: limit)).rows
        }
    }

    // MARK: - Editing

    /// Whether rows can be told apart by a primary key. Without one, edits match every column.
    public var hasPrimaryKey: Bool { !columns.primaryKey.isEmpty }

    /// Empty edits for this table, ready to stage into.
    public func newEdits() -> TableEdits { TableEdits(table: table, columns: columns) }

    /// The statements a commit of these edits alone runs, with values written inline, each
    /// ending in `;`.
    public func preview(_ edits: TableEdits) -> [String] {
        dialect.statements(for: edits.changeSet(dialect: dialect)).map { $0.inlined(for: dialect) + ";" }
    }

    /// Runs these edits alone in one transaction; see `DatabaseConnection.commit`.
    public func commit(_ edits: TableEdits) async throws {
        let changes = edits.changeSet(dialect: dialect)
        guard !changes.isEmpty else { return }
        try await connection.commit(changes)
    }
}

/// How values appear in a grid cell.
public enum CellText {
    /// Longest text a cell renders; the full value belongs in a detail view.
    public static let maxLength = 300

    /// A single line, cut at `maxLength`. Nil stands for SQL NULL, which the grid styles itself.
    public static func display(_ value: DBValue) -> String? {
        switch value {
        case .null:
            return nil
        case .text(let s):
            return singleLine(s)
        default:
            return value.displayString
        }
    }

    /// Tab-separated rows, NULL as an empty field, for the pasteboard.
    public static func tsv(_ rows: [[DBValue]]) -> String {
        rows.map { row in
            row.map { value in
                if case .null = value { return "" }
                return value.displayString.replacing(/[\t\r\n]/, with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private static func singleLine(_ s: String) -> String {
        var out = ""
        var length = 0
        for c in s {
            if length == maxLength {
                out.append("…")
                break
            }
            out.append(c.isNewline || c == "\t" ? " " : c)
            length += 1
        }
        return out
    }
}
