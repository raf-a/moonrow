import DBKit
import Foundation

/// Everything the grid needs to show one table: its columns, its row count and a block fetcher.
public struct TableBrowser: Sendable {
    public let connection: any DatabaseConnection
    public let table: TableRef
    public let columns: [ColumnInfo]

    /// Reads the table's columns. Fails for objects that no longer exist.
    public static func open(_ table: TableRef, on connection: any DatabaseConnection) async throws -> TableBrowser {
        TableBrowser(connection: connection, table: table, columns: try await connection.columns(of: table))
    }

    public func count() async throws -> Int {
        let result = try await connection.execute(
            connection.dialect.count(table, allColumns: columns.map(\.name)))
        guard case .integer(let n)? = result.rows.first?.first else {
            throw DatabaseError("COUNT(*) returned no integer")
        }
        return Int(n)
    }

    /// Rows in the database's natural order. Without ORDER BY a database may in principle return
    /// rows in a different order per query; SQLite's table scans are stable.
    public func fetcher() -> RowCache.Fetch {
        let connection = connection, table = table, names = columns.map(\.name)
        return { offset, limit in
            let request = BrowseRequest(table, limit: limit, offset: offset)
            return try await connection.execute(connection.dialect.select(request, allColumns: names)).rows
        }
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
