import DBKit
import Foundation
import SQLScript

/// Quick Open (⌘P): every table, view, materialized view and function in every schema of the
/// workspace, plus the connection's saved queries, ranked against what's typed.
public enum QuickOpen {
    public struct Item: Sendable, Hashable {
        public enum Kind: Int, Sendable, Hashable, Comparable {
            case table, view, materializedView, function, savedQuery

            public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

            init?(_ kind: ObjectKind) {
                switch kind {
                case .table: self = .table
                case .view: self = .view
                case .materializedView: self = .materializedView
                case .function: self = .function
                case .sequence: return nil
                }
            }
        }

        public var name: String
        public var kind: Kind
        /// The object's schema (or MySQL database); nil for SQLite and saved queries.
        public var schema: String?
        /// Set for database objects.
        public var object: DatabaseObject?
        /// Set for saved queries.
        public var savedQuery: URL?

        public init(_ object: DatabaseObject) {
            name = object.ref.name
            kind = Kind(object.kind) ?? .table
            schema = object.ref.schema
            self.object = object
        }

        public init(savedQuery name: String, url: URL) {
            self.name = name
            kind = .savedQuery
            savedQuery = url
        }

        /// `schema.name`, or the name alone.
        public var qualifiedName: String { schema.map { "\($0).\(name)" } ?? name }
    }

    /// Items for `objects` (sequences are left out) and saved queries.
    public static func items(objects: [DatabaseObject], savedQueries: [SavedQueries.Query]) -> [Item] {
        objects.filter { Item.Kind($0.kind) != nil }.map(Item.init)
            + savedQueries.map { Item(savedQuery: $0.name, url: $0.url) }
    }

    /// Matches ranked best first. A query with a dot (`sales.ord`) matches the schema before
    /// the dot and the name after it. Ties go to recently opened items (`recent`, most recent
    /// first), then the current schema, then tables before views, functions and queries, then
    /// shorter and alphabetically earlier names. An empty query lists recent items first, then
    /// the current schema's, alphabetically.
    public static func rank(_ items: [Item], query: String, currentSchema: String?, recent: [Item] = [],
                            limit: Int = 200) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var schemaQuery: String?
        var nameQuery = trimmed
        if let dot = trimmed.lastIndex(of: ".") {
            schemaQuery = String(trimmed[..<dot])
            nameQuery = String(trimmed[trimmed.index(after: dot)...])
        }
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        var ranked: [(item: Item, tier: Int, recent: Int, inSchema: Bool)] = []
        for item in items {
            if let schemaQuery {
                // Saved queries have no schema, so a dotted query leaves them out.
                guard let schema = item.schema, SQLCompletion.matchTier(schema, query: schemaQuery) != nil else { continue }
            }
            guard let tier = SQLCompletion.matchTier(item.name, query: nameQuery) else { continue }
            let inSchema = item.schema == nil || item.schema == currentSchema
            ranked.append((item, tier, recency[item] ?? Int.max, inSchema))
        }
        ranked.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.recent != b.recent { return a.recent < b.recent }
            if a.inSchema != b.inSchema { return a.inSchema }
            if a.item.kind != b.item.kind { return a.item.kind < b.item.kind }
            // With nothing typed, names stay alphabetical.
            if !nameQuery.isEmpty, a.item.name.count != b.item.name.count { return a.item.name.count < b.item.name.count }
            let order = a.item.name.localizedStandardCompare(b.item.name)
            if order != .orderedSame { return order == .orderedAscending }
            return (a.item.schema ?? "") < (b.item.schema ?? "")
        }
        return ranked.prefix(limit).map(\.item)
    }
}
