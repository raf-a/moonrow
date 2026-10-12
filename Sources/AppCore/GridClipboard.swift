import DBKit
import Foundation

/// Pasting text into the grid: tab-separated rows (what ⌘C and ⇧⌘C copy, and what spreadsheets
/// put on the pasteboard).
public enum GridPaste {
    /// Splits pasteboard text into rows of fields. Lines end at LF, CRLF or CR; one trailing
    /// line break is ignored, and fields are separated by tabs. No quoting: a copied value never
    /// holds a tab or a line break (they're flattened to spaces when copying).
    public static func fields(_ text: String) -> [[String]] {
        var t = text
        // "\r\n" is one Character.
        if let last = t.last, last == "\n" || last == "\r\n" || last == "\r" { t.removeLast() }
        guard !t.isEmpty else { return [] }
        return t.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// One target cell and the text going into it.
    public struct Assignment: Sendable, Hashable {
        /// Grid row and display column (the grid's current column order).
        public var row: Int
        public var column: Int
        public var text: String

        public init(row: Int, column: Int, text: String) {
            self.row = row
            self.column = column
            self.text = text
        }
    }

    /// Where Paste into Selected Cells puts `block`, given the selected rows and the selected
    /// span of display columns, in a grid of `rowCount` rows and `columnCount` columns:
    /// - a single value fills every selected cell;
    /// - a block one row high repeats down every selected row, from the span's first column;
    /// - a block one column wide repeats across every selected column, down from the first
    ///   selected row;
    /// - any other block is pasted once from the top-left selected cell, over consecutive rows
    ///   and columns.
    /// Nothing goes past the grid's last row or column.
    public static func assignments(
        _ block: [[String]], rows: IndexSet, columns: ClosedRange<Int>, rowCount: Int, columnCount: Int
    ) -> [Assignment] {
        guard let firstRow = rows.first, !block.isEmpty, block.contains(where: { !$0.isEmpty }) else { return [] }
        let height = block.count
        let width = block.map(\.count).max() ?? 0
        func value(_ r: Int, _ c: Int) -> String {
            c < block[r].count ? block[r][c] : ""
        }
        var out: [Assignment] = []
        func add(_ row: Int, _ column: Int, _ text: String) {
            guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return }
            out.append(Assignment(row: row, column: column, text: text))
        }
        switch (height, width) {
        case (1, 1):
            for r in rows { for c in columns { add(r, c, value(0, 0)) } }
        case (1, _):
            for r in rows { for i in 0..<width { add(r, columns.lowerBound + i, value(0, i)) } }
        case (_, 1):
            for c in columns { for i in 0..<height { add(firstRow + i, c, value(i, 0)) } }
        default:
            for i in 0..<height { for j in 0..<width { add(firstRow + i, columns.lowerBound + j, value(i, j)) } }
        }
        return out
    }

    /// The value pasted text stands for in a column: an empty field is NULL where the column
    /// allows it (⌘C writes NULL as an empty field), else the empty string; anything else is
    /// read by the column's declared type, as typing it would be.
    public static func value(_ text: String, column: ColumnInfo) -> DBValue {
        if text.isEmpty { return column.isNullable ? .null : .text("") }
        return CellInput.parse(text, typeName: column.typeName)
    }

    /// Whether pasting may write a column: generated columns and ALWAYS identities are the
    /// database's to fill.
    public static func accepts(_ column: ColumnInfo) -> Bool {
        column.generated?.hasPrefix("GENERATED ALWAYS") != true
    }
}

/// The grid's Quick Filter menu: conditions on the clicked cell's column and value.
public enum QuickFilter {
    /// Equal and not equal for any value but a blob; less and greater for numbers and dates;
    /// Contains for other text; IS NULL and IS NOT NULL always. A NULL (or a cell still loading)
    /// offers only the last two.
    public static func conditions(column: String, value: DBValue?) -> [FilterCondition] {
        let target = FilterTarget.column(column)
        let nulls = [FilterCondition(target, .isNull), FilterCondition(target, .isNotNull)]
        guard let value, !value.isNull else { return nulls }
        if case .blob = value { return nulls }
        let text = CellInput.editingText(value)
        var out = [FilterCondition(target, .equal, text), FilterCondition(target, .notEqual, text)]
        switch value {
        case .integer, .double:
            out += [FilterCondition(target, .less, text), FilterCondition(target, .greater, text)]
        case .text(let s) where s.wholeMatch(of: /\d{4}-\d{2}-\d{2}([ T].*)?/) != nil:
            out += [FilterCondition(target, .less, text), FilterCondition(target, .greater, text)]
        case .text(let s) where !s.isEmpty && !s.contains(where: \.isNewline):
            out.append(FilterCondition(target, .contains, text))
        default:
            break
        }
        return out + nulls
    }

    /// `name = 'Alice'`, `age > 30`, `note IS NULL`; long values are cut.
    public static func title(_ c: FilterCondition) -> String {
        guard case .column(let name) = c.target else { return c.op.rawValue }
        var v = c.value.count > 40 ? String(c.value.prefix(40)) + "…" : c.value
        v = v.replacing(/\r\n|\r|\n/, with: " ")
        let shown = Double(c.value) != nil ? v : "'\(v)'"
        switch c.op {
        case .isNull, .isNotNull: return "\(name) \(c.op.rawValue)"
        case .notEqual: return "\(name) ≠ \(shown)"
        case .contains: return "\(name) contains \(shown)"
        default: return "\(name) \(c.op.rawValue) \(shown)"
        }
    }
}
