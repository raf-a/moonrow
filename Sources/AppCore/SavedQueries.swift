import Foundation

/// Queries the user saved by name, per connection: plain `.sql` files in
/// `Queries/<connection-id>/`, so they can be edited outside the app too. One level of folders
/// groups them: a folder is a subdirectory, and names are unique within a folder.
@MainActor
public final class SavedQueries {
    /// Posted (object: the store) after a query is saved, renamed or deleted.
    public static let didChange = Notification.Name("SavedQueries.didChange")

    public struct Query: Sendable, Hashable {
        public var name: String
        public var url: URL
        public var modified: Date
        /// Empty at the top level.
        public var folder: String = ""

        public init(name: String, url: URL, modified: Date, folder: String = "") {
            self.name = name
            self.url = url
            self.modified = modified
            self.folder = folder
        }

        /// `folder/name`, or the name at the top level; what a restored session refers to.
        public var path: String { folder.isEmpty ? name : folder + "/" + name }
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
    /// Every query, folders' included, sorted by folder (top level first) then name.
    public private(set) var queries: [Query] = []
    /// Folder names, sorted; empty folders included.
    public private(set) var folders: [String] = []

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
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func queries(in dir: URL, folder: String) -> [Query] {
            list(dir).filter { $0.pathExtension.lowercased() == "sql" }.map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return Query(name: url.deletingPathExtension().lastPathComponent, url: url, modified: modified ?? .distantPast, folder: folder)
            }
        }
        let top = list(directory)
        folders = top.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.queries = (queries(in: directory, folder: "") + folders.flatMap { queries(in: folderURL($0), folder: $0) })
            .sorted { a, b in
                if a.folder != b.folder {
                    return a.folder.isEmpty || (!b.folder.isEmpty && a.folder.localizedStandardCompare(b.folder) == .orderedAscending)
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    private func folderURL(_ folder: String) -> URL {
        folder.isEmpty ? directory : directory.appending(path: folder, directoryHint: .isDirectory)
    }

    public func queries(in folder: String) -> [Query] { queries.filter { $0.folder == folder } }

    public func query(named name: String, in folder: String = "") -> Query? {
        let file = Self.fileName(for: name) + ".sql"
        return queries.first { $0.folder == folder && $0.url.lastPathComponent == file }
    }

    /// `folder/name`, or a plain name at the top level.
    public func query(path: String) -> Query? {
        guard let slash = path.firstIndex(of: "/") else { return query(named: path) }
        return query(named: String(path[path.index(after: slash)...]), in: String(path[..<slash]))
    }

    public func text(of query: Query) throws -> String {
        try String(contentsOf: query.url, encoding: .utf8)
    }

    /// Writes `sql` under `name` in `folder`, replacing a query with that name only when
    /// `overwrite` is set. A folder that doesn't exist is created.
    @discardableResult
    public func save(_ sql: String, as name: String, in folder: String = "", overwrite: Bool = false) throws -> Query {
        let file = Self.fileName(for: name)
        guard !file.isEmpty else { throw StoreError.invalidName }
        let dir = folderURL(folder)
        let url = dir.appending(path: file + ".sql")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw StoreError.exists(url.deletingPathExtension().lastPathComponent)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(sql.utf8).write(to: url, options: .atomic)
        changed()
        return queries.first { $0.folder == folder && $0.url.lastPathComponent == url.lastPathComponent }
            ?? Query(name: file, url: url, modified: Date(), folder: folder)
    }

    /// Renames a query within its folder.
    @discardableResult
    public func rename(_ query: Query, to name: String) throws -> Query {
        try place(query, as: name, in: query.folder)
    }

    /// Moves a query into another folder ("" for the top level), keeping its name.
    @discardableResult
    public func move(_ query: Query, to folder: String) throws -> Query {
        try place(query, as: query.name, in: folder)
    }

    private func place(_ query: Query, as name: String, in folder: String) throws -> Query {
        let file = Self.fileName(for: name)
        guard !file.isEmpty else { throw StoreError.invalidName }
        let dir = folderURL(folder)
        let url = dir.appending(path: file + ".sql")
        if url.standardizedFileURL != query.url.standardizedFileURL {
            // A case-only rename is the same file on a case-insensitive volume.
            let sameFile = folder == query.folder && url.lastPathComponent.lowercased() == query.url.lastPathComponent.lowercased()
            if !sameFile, FileManager.default.fileExists(atPath: url.path) { throw StoreError.exists(file) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: query.url, to: url)
        }
        changed()
        return queries.first { $0.folder == folder && $0.url.lastPathComponent == url.lastPathComponent } ?? query
    }

    public func delete(_ query: Query) throws {
        try FileManager.default.removeItem(at: query.url)
        changed()
    }

    /// Makes an empty folder; returns its name as stored.
    @discardableResult
    public func addFolder(_ name: String) throws -> String {
        let folder = Self.fileName(for: name)
        guard !folder.isEmpty else { throw StoreError.invalidName }
        guard !folders.contains(where: { $0.lowercased() == folder.lowercased() }) else { throw StoreError.exists(folder) }
        try FileManager.default.createDirectory(at: folderURL(folder), withIntermediateDirectories: true)
        changed()
        return folder
    }

    @discardableResult
    public func renameFolder(_ folder: String, to name: String) throws -> String {
        let new = Self.fileName(for: name)
        guard !new.isEmpty else { throw StoreError.invalidName }
        guard new != folder else { return folder }
        if new.lowercased() != folder.lowercased(), folders.contains(where: { $0.lowercased() == new.lowercased() }) {
            throw StoreError.exists(new)
        }
        try FileManager.default.moveItem(at: folderURL(folder), to: folderURL(new))
        changed()
        return new
    }

    /// The folder's directory, queries and all; `trash` moves it to the Trash instead of
    /// deleting it.
    public func deleteFolder(_ folder: String, trash: Bool = true) throws {
        guard !folder.isEmpty else { return }
        if trash { try FileManager.default.trashItem(at: folderURL(folder), resultingItemURL: nil) }
        else { try FileManager.default.removeItem(at: folderURL(folder)) }
        changed()
    }

    private func changed() {
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
