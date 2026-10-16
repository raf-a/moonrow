import DBKit
import Foundation

/// What an open workspace window showed, so it can be reopened at the next launch: its
/// connection, schema, panes and tabs, unsaved query text included. Staged changes aren't kept.
public struct WorkspaceSession: Codable, Sendable, Hashable {
    public struct Tab: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case table, query }

        public var kind: Kind
        // Tables and views.
        public var schema: String?
        public var name: String?
        /// An `ObjectKind` raw value.
        public var objectKind: String?
        /// A Postgres routine's arguments (`DatabaseObject.signature`).
        public var signature: String?
        public var structure: Bool
        /// A view's tab showing its definition.
        public var definition: Bool
        public var isPreview: Bool
        // Query tabs.
        public var text: String?
        /// The saved query the tab edits, by name.
        public var savedQuery: String?
        /// The SQL file the tab was opened from; its text is `text`, as edited.
        public var file: String?

        public static func table(_ object: DatabaseObject, structure: Bool = false, definition: Bool = false,
                                 isPreview: Bool = false) -> Tab {
            Tab(kind: .table, schema: object.ref.schema, name: object.ref.name, objectKind: object.kind.rawValue,
                signature: object.signature, structure: structure, definition: definition, isPreview: isPreview)
        }

        public static func query(text: String, savedQuery: String? = nil, file: String? = nil, isPreview: Bool = false) -> Tab {
            Tab(kind: .query, structure: false, isPreview: isPreview, text: text, savedQuery: savedQuery, file: file)
        }

        /// The table or view, for table tabs.
        public var object: DatabaseObject? {
            guard kind == .table, let name, !name.isEmpty else { return nil }
            return DatabaseObject(TableRef(schema: schema, name), kind: objectKind.flatMap(ObjectKind.init(rawValue:)) ?? .table,
                                  signature: signature)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, schema, name, objectKind, signature, structure, definition, isPreview, text, savedQuery, file
        }

        init(kind: Kind, schema: String? = nil, name: String? = nil, objectKind: String? = nil, signature: String? = nil,
             structure: Bool, definition: Bool = false, isPreview: Bool, text: String? = nil, savedQuery: String? = nil,
             file: String? = nil) {
            self.kind = kind
            self.schema = schema
            self.name = name
            self.objectKind = objectKind
            self.signature = signature
            self.definition = definition
            self.structure = structure
            self.isPreview = isPreview
            self.text = text
            self.savedQuery = savedQuery
            self.file = file
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            schema = try c.decodeIfPresent(String.self, forKey: .schema)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            objectKind = try c.decodeIfPresent(String.self, forKey: .objectKind)
            signature = try c.decodeIfPresent(String.self, forKey: .signature)
            structure = try c.decodeIfPresent(Bool.self, forKey: .structure) ?? false
            definition = try c.decodeIfPresent(Bool.self, forKey: .definition) ?? false
            isPreview = try c.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
            text = try c.decodeIfPresent(String.self, forKey: .text)
            savedQuery = try c.decodeIfPresent(String.self, forKey: .savedQuery)
            file = try c.decodeIfPresent(String.self, forKey: .file)
        }
    }

    public struct Pane: Codable, Sendable, Hashable {
        public var tabs: [Tab]
        public var selected: Int?

        public init(tabs: [Tab] = [], selected: Int? = nil) {
            self.tabs = tabs
            self.selected = selected
        }

        private enum CodingKeys: String, CodingKey { case tabs, selected }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A tab this version can't read is left out; the others still open.
            tabs = (try c.decodeIfPresent([Lossy<Tab>].self, forKey: .tabs) ?? []).compactMap(\.value)
            selected = (try? c.decodeIfPresent(Int.self, forKey: .selected)).flatMap { $0 }
            if let s = selected, !tabs.indices.contains(s) { selected = tabs.isEmpty ? nil : tabs.count - 1 }
        }
    }

    public var connectionID: UUID
    /// Postgres: the database the workspace had switched to with ⌘K, when it isn't the saved
    /// connection's; the workspace reconnects there.
    public var database: String?
    public var schema: String?
    public var panes: [Pane]
    public var activePane: Int

    public init(connectionID: UUID, database: String? = nil, schema: String? = nil, panes: [Pane] = [Pane()], activePane: Int = 0) {
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
        self.panes = panes
        self.activePane = activePane
    }

    private enum CodingKeys: String, CodingKey { case connectionID, database, schema, panes, activePane }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try c.decode(UUID.self, forKey: .connectionID)
        database = try? c.decodeIfPresent(String.self, forKey: .database)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        panes = (try c.decodeIfPresent([Lossy<Pane>].self, forKey: .panes) ?? []).compactMap(\.value)
        if panes.isEmpty { panes = [Pane()] }
        activePane = min(max(0, (try? c.decodeIfPresent(Int.self, forKey: .activePane)).flatMap { $0 } ?? 0), panes.count - 1)
    }
}

/// The workspaces to reopen at launch: `session.json` next to the connections file.
@MainActor
public final class SessionStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func fileURL(root: URL) -> URL { root.appending(path: "session.json") }

    private struct File: Codable {
        var version: Int
        var workspaces: [Lossy<WorkspaceSession>]
    }

    /// Nothing saved, or a file that can't be read, reopens nothing.
    public func load() -> [WorkspaceSession] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version <= 1 else { return [] }
        return file.workspaces.compactMap(\.value)
    }

    public func save(_ workspaces: [WorkspaceSession]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: 1, workspaces: workspaces.map { Lossy(value: $0) }))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Decodes to nil instead of failing, so one bad element doesn't lose a whole list.
struct Lossy<T: Codable & Sendable>: Codable, Sendable {
    var value: T?

    init(value: T?) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
