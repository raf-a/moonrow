import CoreGraphics
import DBKit
import Foundation

/// The ER diagram's model: a schema's tables with their columns, and their foreign keys as
/// edges. Read-only.
public struct SchemaDiagram: Sendable {
    public struct Table: Sendable {
        public var ref: TableRef
        public var columns: [ColumnInfo]
        public var foreignKeys: [ForeignKeyInfo]

        public init(ref: TableRef, columns: [ColumnInfo], foreignKeys: [ForeignKeyInfo] = []) {
            self.ref = ref
            self.columns = columns
            self.foreignKeys = foreignKeys
        }
    }

    /// A foreign key from `child` to `parent` (indexes into `tables`).
    public struct Edge: Sendable, Hashable {
        public var child: Int
        public var parent: Int
        public var columns: [String]
        public var referencedColumns: [String]
    }

    public var tables: [Table]
    public var edges: [Edge]
    /// Tables left out past `limit`.
    public var omitted: Int

    public init(tables: [Table], omitted: Int = 0) {
        self.tables = tables
        self.omitted = omitted
        var index: [TableRef: Int] = [:]
        for (i, t) in tables.enumerated() { index[TableRef(schema: nil, t.ref.name.lowercased())] = i }
        edges = tables.enumerated().flatMap { i, t in
            t.foreignKeys.compactMap { key in
                // Keys into another schema aren't drawn.
                if let s = key.referencedTable.schema, let own = t.ref.schema, s != own { return nil }
                guard let parent = index[TableRef(schema: nil, key.referencedTable.name.lowercased())] else { return nil }
                return Edge(child: i, parent: parent, columns: key.columns, referencedColumns: key.referencedColumns)
            }
        }
    }

    /// Most tables a diagram reads (each costs a few statements).
    public static let limit = 300

    /// Reads the columns and foreign keys of `tables` (the first `limit`).
    public static func load(_ tables: [TableRef], on connection: any DatabaseConnection) async throws -> SchemaDiagram {
        var out: [Table] = []
        for ref in tables.prefix(limit) {
            try Task.checkCancellation()
            out.append(Table(ref: ref, columns: try await connection.columns(of: ref),
                             foreignKeys: try await connection.foreignKeys(of: ref)))
        }
        return SchemaDiagram(tables: out, omitted: max(0, tables.count - limit))
    }

    // MARK: - Layout

    public static let columnGap: CGFloat = 80
    public static let rowGap: CGFloat = 28
    public static let groupGap: CGFloat = 60

    /// Where each table's box goes (top-left corners, y growing down), given the boxes' sizes.
    ///
    /// Tables joined by foreign keys form groups, largest first, stacked top to bottom. Within a
    /// group, referenced tables sit left of the tables that reference them (one column per
    /// level), each column ordered to stay close to its parents. Tables without keys follow in
    /// a grid, by name.
    public func layout(sizes: [CGSize]) -> [CGPoint] {
        precondition(sizes.count == tables.count)
        var positions = Array(repeating: CGPoint.zero, count: tables.count)
        let links = edges.filter { $0.child != $0.parent }
        var neighbours = Array(repeating: Set<Int>(), count: tables.count)
        for e in links {
            neighbours[e.child].insert(e.parent)
            neighbours[e.parent].insert(e.child)
        }

        // Groups (connected components).
        var group = Array(repeating: -1, count: tables.count)
        var groups: [[Int]] = []
        for start in tables.indices where group[start] < 0 && !neighbours[start].isEmpty {
            var members: [Int] = []
            var stack = [start]
            group[start] = groups.count
            while let n = stack.popLast() {
                members.append(n)
                for m in neighbours[n] where group[m] < 0 {
                    group[m] = groups.count
                    stack.append(m)
                }
            }
            groups.append(members)
        }
        groups.sort { ($0.count, -($0.min() ?? 0)) > ($1.count, -($1.min() ?? 0)) }

        // Levels: a table sits one column right of the furthest table it references. Cycles stop
        // after as many rounds as there are tables.
        var level = Array(repeating: 0, count: tables.count)
        for _ in 0..<tables.count {
            var changed = false
            for e in links where level[e.child] < level[e.parent] + 1 && level[e.parent] + 1 < tables.count {
                level[e.child] = level[e.parent] + 1
                changed = true
            }
            if !changed { break }
        }
        let name = { (i: Int) in tables[i].ref.name.lowercased() }

        var top: CGFloat = 0
        var widest: CGFloat = 0
        for members in groups {
            let levels = Dictionary(grouping: members) { level[$0] }.sorted { $0.key < $1.key }
            var x: CGFloat = 0
            var rank: [Int: CGFloat] = [:]
            var height: CGFloat = 0
            for (_, column) in levels {
                // Closest to the parents' average position, then by name.
                let ordered = column.sorted { a, b in
                    func centre(_ n: Int) -> CGFloat {
                        let ranks = links.filter { $0.child == n }.compactMap { rank[$0.parent] }
                        return ranks.isEmpty ? .infinity : ranks.reduce(0, +) / CGFloat(ranks.count)
                    }
                    let (ca, cb) = (centre(a), centre(b))
                    return ca != cb ? ca < cb : name(a) < name(b)
                }
                var y = top
                for (i, n) in ordered.enumerated() {
                    positions[n] = CGPoint(x: x, y: y)
                    rank[n] = CGFloat(i)
                    y += sizes[n].height + Self.rowGap
                }
                height = max(height, y - top - Self.rowGap)
                x += (column.map { sizes[$0].width }.max() ?? 0) + Self.columnGap
            }
            widest = max(widest, x - Self.columnGap)
            top += height + Self.groupGap
        }

        // Tables without keys: rows as wide as the widest group (at least four boxes).
        let loose = tables.indices.filter { group[$0] < 0 }.sorted { name($0) < name($1) }
        let rowWidth = max(widest, (loose.map { sizes[$0].width }.max() ?? 0) * 4 + Self.columnGap * 3)
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for n in loose {
            if x > 0, x + sizes[n].width > rowWidth {
                x = 0
                top += rowHeight + Self.rowGap
                rowHeight = 0
            }
            positions[n] = CGPoint(x: x, y: top)
            x += sizes[n].width + Self.columnGap
            rowHeight = max(rowHeight, sizes[n].height)
        }
        return positions
    }
}
