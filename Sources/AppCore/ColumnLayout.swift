import DBKit
import Foundation

/// Which of a table's columns the grid shows, and in what order (the Columns button, and
/// dragging headers). Columns are named, so the layout survives columns added or dropped
/// since: new ones show, after the column they follow in the table.
public struct ColumnLayout: Codable, Hashable, Sendable {
    /// Every column the layout knew about, in display order; hidden ones included.
    public var order: [String]
    public var hidden: [String]

    public init(order: [String] = [], hidden: [String] = []) {
        self.order = order
        self.hidden = hidden
    }

    /// The table's own order, every column shown.
    public var isDefault: Bool { order.isEmpty && hidden.isEmpty }

    /// Indices into `columns` (the table's declared order) in display order, all of them,
    /// hidden ones included. Unknown names are dropped; a column the layout doesn't know goes
    /// right after the column before it in the table (first if it's the first).
    public func arranged(_ columns: [String]) -> [Int] {
        let index = Dictionary(columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<Int>()
        var out = order.compactMap { index[$0] }.filter { seen.insert($0).inserted }
        for i in columns.indices where !seen.contains(i) {
            seen.insert(i)
            if i == 0 { out.insert(i, at: 0); continue }
            let at = out.firstIndex(of: i - 1).map { $0 + 1 } ?? out.count
            out.insert(i, at: at)
        }
        return out
    }

    /// The columns the grid shows, in order. At least one column always shows: a layout that
    /// would hide them all shows them all.
    public func visible(_ columns: [String]) -> [Int] {
        let hiddenSet = Set(hidden)
        let all = arranged(columns)
        let shown = all.filter { !hiddenSet.contains(columns[$0]) }
        return shown.isEmpty ? all : shown
    }

    public func isHidden(_ column: String) -> Bool { hidden.contains(column) }

    /// Shows or hides a column. Hiding the last shown column is refused (returns false).
    @discardableResult
    public mutating func setHidden(_ isHidden: Bool, _ column: String, columns: [String]) -> Bool {
        if isHidden {
            guard !hidden.contains(column), columns.contains(column) else { return true }
            guard visible(columns).count > 1 else { return false }
            if order.isEmpty { order = columns }
            hidden.append(column)
        } else {
            hidden.removeAll { $0 == column }
        }
        normalize(columns)
        return true
    }

    /// Moves the column at display position `from` (among all columns, `arranged`) to `to`.
    public mutating func move(from: Int, to: Int, columns: [String]) {
        var names = arranged(columns).map { columns[$0] }
        guard names.indices.contains(from), names.indices.contains(to), from != to else { return }
        names.insert(names.remove(at: from), at: to)
        order = names
        normalize(columns)
    }

    /// Sets the display order of the shown columns, as the grid has them after a header drag;
    /// hidden columns keep their places.
    public mutating func setShownOrder(_ shown: [String], columns: [String]) {
        var names = arranged(columns).map { columns[$0] }
        let shownSet = Set(shown)
        var queue = shown.makeIterator()
        for i in names.indices where shownSet.contains(names[i]) {
            if let next = queue.next() { names[i] = next }
        }
        order = names
        normalize(columns)
    }

    /// Forgets names that no longer exist, and the order when it's the table's own.
    private mutating func normalize(_ columns: [String]) {
        hidden = hidden.filter(columns.contains)
        order = arranged(columns).map { columns[$0] }
        if order == columns { order = [] }
    }
}

/// Column layouts of one connection's tables, saved in `Layouts/<connection-id>.json` next to
/// the connections file.
@MainActor
public final class ColumnLayouts {
    private struct Entry: Codable {
        var schema: String?
        var table: String
        var layout: ColumnLayout
    }

    public let fileURL: URL
    private var layouts: [TableRef: ColumnLayout] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in entries { layouts[TableRef(schema: e.schema, e.table)] = e.layout }
        }
    }

    public static func fileURL(root: URL, connection id: UUID) -> URL {
        root.appending(path: "Layouts", directoryHint: .isDirectory).appending(path: "\(id.uuidString).json")
    }

    public func layout(for table: TableRef) -> ColumnLayout {
        layouts[table] ?? ColumnLayout()
    }

    /// Saves at once; a default layout is forgotten. Saving is best effort.
    public func set(_ layout: ColumnLayout, for table: TableRef) {
        guard layouts[table] ?? ColumnLayout() != layout else { return }
        layouts[table] = layout.isDefault ? nil : layout
        let entries = layouts.map { Entry(schema: $0.key.schema, table: $0.key.name, layout: $0.value) }
            .sorted { ($0.schema ?? "", $0.table) < ($1.schema ?? "", $1.table) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // A layout that isn't saved only costs the user rearranging next time.
        }
    }

    /// Follows a table rename from a commit.
    public func rename(_ table: TableRef, to new: TableRef) {
        guard let layout = layouts[table] else { return }
        set(ColumnLayout(), for: table)
        set(layout, for: new)
    }
}
