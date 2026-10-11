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
    public func describe(total: Int) -> String {
        let rows = rows(total: total)
        let of = total.formatted(.number)
        if rows.isEmpty { return total == 0 ? "No rows" : "No rows at offset \(offset.formatted(.number)) of \(of)" }
        if pageSize == nil && offset == 0 { return "\(of) \(total == 1 ? "row" : "rows")" }
        return "\((rows.lowerBound + 1).formatted(.number))–\(rows.upperBound.formatted(.number)) of \(of)"
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

    /// The SELECT for part of the current page. `offset` is relative to the page.
    public func select(_ query: GridQuery, offset: Int, limit: Int) -> SQLFragment {
        let request = BrowseRequest(
            table, filter: query.filter, sort: query.sort, limit: limit, offset: query.page.offset + offset)
        return dialect.select(request, allColumns: columns.map(\.name))
    }

    /// Fetches blocks of the current page for `RowCache`. Without a sort, rows come in the
    /// database's natural order; SQLite's table scans are stable across OFFSETs.
    public func fetcher(_ query: GridQuery) -> RowCache.Fetch {
        let browser = self
        return { offset, limit in
            try await browser.connection.execute(browser.select(query, offset: offset, limit: limit)).rows
        }
    }

    // MARK: - Editing

    /// Whether rows can be told apart by a primary key. Without one, edits match every column.
    public var hasPrimaryKey: Bool { !columns.primaryKey.isEmpty }

    public func changeSet(_ edits: StagedEdits) -> ChangeSet {
        edits.changeSet(for: table, columns: columns, dialect: dialect)
    }

    /// The statements a commit runs, with values written inline, each ending in `;`.
    public func preview(_ edits: StagedEdits) -> [String] {
        dialect.statements(for: changeSet(edits)).map { $0.inlined(for: dialect) + ";" }
    }

    /// Runs the edits in one transaction; see `DatabaseConnection.commit`.
    public func commit(_ edits: StagedEdits) async throws {
        let changes = changeSet(edits)
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
