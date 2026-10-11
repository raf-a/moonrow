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

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Tabula/connections.json`.
    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Tabula", directoryHint: .isDirectory)
            .appending(path: "connections.json")
    }

    /// A missing file means no connections yet. Anything else that fails throws, and the
    /// store stays empty and unsaved so a bad file is never overwritten by accident.
    public func load() throws {
        connections = []
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

    private func write(_ list: [ConnectionConfig]) throws {
        let sorted = Self.sorted(list)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StoreFile(version: Self.formatVersion, connections: sorted))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        connections = sorted
        NotificationCenter.default.post(name: Self.didChange, object: self)
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
}
