import Foundation

/// Queries the user saved by name, per connection: plain `.sql` files in
/// `Queries/<connection-id>/`, so they can be edited outside the app too.
@MainActor
public final class SavedQueries {
    /// Posted (object: the store) after a query is saved, renamed or deleted.
    public static let didChange = Notification.Name("SavedQueries.didChange")

    public struct Query: Sendable, Hashable {
        public var name: String
        public var url: URL
        public var modified: Date
    }

    public enum StoreError: Error, CustomStringConvertible {
        case invalidName
        case exists(String)

        public var description: String {
            switch self {
            case .invalidName: "A query needs a name."
            case .exists(let name): "A query named “\(name)” already exists."
            }
        }
    }

    public let directory: URL
    /// Sorted by name.
    public private(set) var queries: [Query] = []

    public init(directory: URL) {
        self.directory = directory
        reload()
    }

    /// `<root>/Queries/<id>/`.
    public static func directory(root: URL, connection id: UUID) -> URL {
        root.appending(path: "Queries", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        queries = urls.filter { $0.pathExtension.lowercased() == "sql" }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Query(name: url.deletingPathExtension().lastPathComponent, url: url, modified: modified ?? .distantPast)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func query(named name: String) -> Query? {
        let file = Self.fileName(for: name) + ".sql"
        return queries.first { $0.url.lastPathComponent == file }
    }

    public func text(of query: Query) throws -> String {
        try String(contentsOf: query.url, encoding: .utf8)
    }

    /// Writes `sql` under `name`, replacing a query with that name only when `overwrite` is set.
    @discardableResult
    public func save(_ sql: String, as name: String, overwrite: Bool = false) throws -> Query {
        let file = Self.fileName(for: name)
        guard !file.isEmpty else { throw StoreError.invalidName }
        let url = directory.appending(path: file + ".sql")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw StoreError.exists(url.deletingPathExtension().lastPathComponent)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(sql.utf8).write(to: url, options: .atomic)
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return queries.first { $0.url.lastPathComponent == url.lastPathComponent }
            ?? Query(name: file, url: url, modified: Date())
    }

    @discardableResult
    public func rename(_ query: Query, to name: String) throws -> Query {
        let file = Self.fileName(for: name)
        guard !file.isEmpty else { throw StoreError.invalidName }
        let url = directory.appending(path: file + ".sql")
        if url.lastPathComponent != query.url.lastPathComponent {
            // A case-only rename is the same file on a case-insensitive volume.
            let sameFile = url.lastPathComponent.lowercased() == query.url.lastPathComponent.lowercased()
            if !sameFile, FileManager.default.fileExists(atPath: url.path) { throw StoreError.exists(file) }
            try FileManager.default.moveItem(at: query.url, to: url)
        }
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return queries.first { $0.url.lastPathComponent == url.lastPathComponent } ?? query
    }

    public func delete(_ query: Query) throws {
        try FileManager.default.removeItem(at: query.url)
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A file name for a query name: slashes and colons become dashes, leading dots and
    /// surrounding whitespace go, and a trailing `.sql` is dropped.
    public static func fileName(for name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".sql") { s.removeLast(4) }
        s = String(s.map { $0 == "/" || $0 == ":" || $0.isNewline ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}
