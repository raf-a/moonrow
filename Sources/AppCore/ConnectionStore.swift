import Foundation

/// Saved connections, persisted as JSON. Writes are atomic; every change saves immediately.
@MainActor
public final class ConnectionStore {
    /// Posted after every successful change.
    public static let didChange = Notification.Name("ConnectionStore.didChange")

    public enum StoreError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: any Error)
        case unsupportedVersion(URL, Int)

        public var description: String {
            switch self {
            case .unreadable(let url, let error):
                "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            case .unsupportedVersion(let url, let v):
                "\(url.lastPathComponent) was written by a newer version (format \(v))."
            }
        }
    }

    public static let formatVersion = 1

    public let fileURL: URL
    /// In display order: by name, case-insensitively.
    public private(set) var connections: [ConnectionConfig] = []
    /// The welcome window's folders, by name. Connections name theirs with `groupID`.
    public private(set) var groups: [ConnectionGroup] = []
    /// The tags connections can have, in the order they're offered.
    public private(set) var tags: [ConnectionTag] = ConnectionTag.defaults

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Moonrow/connections.json`.
    public static func defaultFileURL(in base: URL = .applicationSupportDirectory) -> URL {
        base.appending(path: "Moonrow", directoryHint: .isDirectory)
            .appending(path: "connections.json")
    }

    /// Moves the data folder from when the app had its working name, `Tabula`, to where
    /// `defaultFileURL(in:)` looks, unless that folder already exists. Returns whether it moved.
    @discardableResult
    public static func adoptLegacyDirectory(in base: URL = .applicationSupportDirectory) -> Bool {
        let legacy = base.appending(path: "Tabula", directoryHint: .isDirectory)
        let current = defaultFileURL(in: base).deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return false }
        return (try? fm.moveItem(at: legacy, to: current)) != nil
    }

    /// A missing file means no connections yet. Anything else that fails throws, and the
    /// store stays empty and unsaved so a bad file is never overwritten by accident.
    public func load() throws {
        connections = []
        groups = []
        tags = ConnectionTag.defaults
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            throw StoreError.unreadable(fileURL, underlying: error)
        }
        let file: StoreFile
        do {
            file = try JSONDecoder().decode(StoreFile.self, from: data)
        } catch {
            throw StoreError.unreadable(fileURL, underlying: error)
        }
        guard file.version <= Self.formatVersion else {
            throw StoreError.unsupportedVersion(fileURL, file.version)
        }
        connections = Self.sorted(file.connections)
        groups = Self.sorted(file.groups ?? [])
        tags = file.tags ?? ConnectionTag.defaults
    }

    /// Renames an unreadable file to `connections.json.bak` (replacing an older backup)
    /// so the app can start fresh. Returns the backup's URL.
    @discardableResult
    public func moveAsideUnreadableFile() throws -> URL {
        let backup = fileURL.appendingPathExtension("bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        try fm.moveItem(at: fileURL, to: backup)
        connections = []
        groups = []
        tags = ConnectionTag.defaults
        return backup
    }

    public func connection(id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    /// Adds the connection, or replaces the one with the same id.
    public func save(_ connection: ConnectionConfig) throws {
        var next = connections.filter { $0.id != connection.id }
        next.append(connection)
        try write(next)
    }

    public func delete(id: UUID) throws {
        try write(connections.filter { $0.id != id })
    }

    /// Saves a copy named "<name> copy" and returns it.
    @discardableResult
    public func duplicate(id: UUID) throws -> ConnectionConfig? {
        guard var copy = connection(id: id) else { return nil }
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        try save(copy)
        return copy
    }

    // MARK: - Tags

    public func tag(id: UUID?) -> ConnectionTag? {
        id.flatMap { id in tags.first { $0.id == id } }
    }

    /// The connection's tag, nil when it has none or the store no longer has it.
    public func tag(of connection: ConnectionConfig) -> ConnectionTag? { tag(id: connection.tagID) }

    /// Replaces the tags, in this order. Names are trimmed; a tag without a name, or named like
    /// one before it (ignoring case), is left out. Connections whose tag is gone lose it.
    public func setTags(_ list: [ConnectionTag]) throws {
        var kept: [ConnectionTag] = []
        for var t in list {
            t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.name.isEmpty, !kept.contains(where: { $0.id == t.id || $0.name.lowercased() == t.name.lowercased() })
            else { continue }
            kept.append(t)
        }
        let ids = Set(kept.map(\.id))
        let untagged = connections.map { c -> ConnectionConfig in
            var c = c
            if let id = c.tagID, !ids.contains(id) { c.tagID = nil }
            return c
        }
        guard kept != tags || untagged != connections else { return }
        try write(untagged, tags: kept)
    }

    // MARK: - Groups

    public func group(id: UUID) -> ConnectionGroup? {
        groups.first { $0.id == id }
    }

    /// Connections in the group (nil: the ungrouped ones), in display order. A connection whose
    /// group no longer exists counts as ungrouped.
    public func connections(in group: UUID?) -> [ConnectionConfig] {
        let known = Set(groups.map(\.id))
        return connections.filter { c in
            guard let id = c.groupID, known.contains(id) else { return group == nil }
            return id == group
        }
    }

    /// Adds an expanded group named `name` (trimmed; "New Group" when empty).
    @discardableResult
    public func addGroup(named name: String) throws -> ConnectionGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ConnectionGroup(name: trimmed.isEmpty ? "New Group" : trimmed)
        try write(connections, groups: groups + [group])
        return group
    }

    public func renameGroup(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try write(connections, groups: groups.map { $0.id == id ? $0.renamed(trimmed) : $0 })
    }

    public func setGroup(_ id: UUID, collapsed: Bool) throws {
        guard let g = group(id: id), g.isCollapsed != collapsed else { return }
        var changed = g
        changed.isCollapsed = collapsed
        try write(connections, groups: groups.map { $0.id == id ? changed : $0 })
    }

    /// Removes the group; its connections become ungrouped (none is deleted).
    public func deleteGroup(_ id: UUID) throws {
        let moved = connections.map { c -> ConnectionConfig in
            var c = c
            if c.groupID == id { c.groupID = nil }
            return c
        }
        try write(moved, groups: groups.filter { $0.id != id })
    }

    /// Files connections into `group` (nil: out of any group).
    public func move(_ ids: [UUID], to group: UUID?) throws {
        guard group.map({ self.group(id: $0) != nil }) ?? true else { return }
        let set = Set(ids)
        let moved = connections.map { c -> ConnectionConfig in
            var c = c
            if set.contains(c.id) { c.groupID = group }
            return c
        }
        guard moved != connections else { return }
        try write(moved, groups: groups)
    }

    private func write(_ list: [ConnectionConfig], groups newGroups: [ConnectionGroup]? = nil,
                       tags newTags: [ConnectionTag]? = nil) throws {
        let sorted = Self.sorted(list)
        let sortedGroups = Self.sorted(newGroups ?? groups)
        let tagList = newTags ?? tags
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StoreFile(
            version: Self.formatVersion, connections: sorted, groups: sortedGroups.isEmpty ? nil : sortedGroups,
            tags: tagList == ConnectionTag.defaults ? nil : tagList))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        connections = sorted
        groups = sortedGroups
        tags = tagList
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func sorted(_ list: [ConnectionGroup]) -> [ConnectionGroup] {
        list.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    private static func sorted(_ list: [ConnectionConfig]) -> [ConnectionConfig] {
        list.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

private struct StoreFile: Codable {
    var version: Int
    var connections: [ConnectionConfig]
    /// Left out while there are none, so files without groups stay as they were.
    var groups: [ConnectionGroup]?
    /// Left out while they're the defaults; an empty list means every tag was removed.
    var tags: [ConnectionTag]?
}

/// A folder of connections in the welcome window.
public struct ConnectionGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    func renamed(_ name: String) -> ConnectionGroup {
        var g = self
        g.name = name
        return g
    }

    private enum CodingKeys: String, CodingKey { case id, name, isCollapsed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        isCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    }
}
