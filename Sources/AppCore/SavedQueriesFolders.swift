import Foundation

// Where a connection's saved queries live, moving or copying them when that changes, and the
// move from the per-connection folders of earlier versions.

extension SavedQueries {
    /// `<root>/Queries/`, where a queries folder given by name lives.
    public static func queriesRoot(_ root: URL) -> URL {
        root.appending(path: "Queries", directoryHint: .isDirectory)
    }

    /// The folder a connection gets when it has none: its name.
    public static func defaultFolder(for config: ConnectionConfig) -> String {
        let name = fileName(for: config.displayName)
        return name.isEmpty ? "Untitled" : name
    }

    /// The connection's queries folder: the path when `queriesFolder` starts with `/` or `~`,
    /// else the folder of that name in `<root>/Queries/` (the connection's name when empty).
    public static func directory(root: URL, for config: ConnectionConfig) -> URL {
        let folder = config.queriesFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if folder.hasPrefix("/") || folder.hasPrefix("~") {
            return URL(filePath: (folder as NSString).expandingTildeInPath, directoryHint: .isDirectory).standardizedFileURL
        }
        let name = fileName(for: folder)
        return queriesRoot(root).appending(path: name.isEmpty ? defaultFolder(for: config) : name, directoryHint: .isDirectory)
    }

    /// Whether two URLs name the same directory: the same file when both exist (so case and
    /// symlinks don't matter), else the same path.
    public static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
           let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier {
            return x.isEqual(y)
        }
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// A connection's queries folder changing.
    public struct FolderChange: Sendable, Equatable {
        public var source: URL
        public var destination: URL
        /// The queries in `source`, its folders' included.
        public var count: Int
        /// The other saved connections that still use `source`.
        public var sharedWith: [String]
    }

    /// Nil when `old` and `new` use the same folder. `connections` are the saved ones.
    public static func folderChange(from old: ConnectionConfig, to new: ConnectionConfig,
                                    among connections: [ConnectionConfig], root: URL) -> FolderChange? {
        let source = directory(root: root, for: old)
        let destination = directory(root: root, for: new)
        guard !sameDirectory(source, destination) else { return nil }
        let others = connections.filter { $0.id != old.id && sameDirectory(directory(root: root, for: $0), source) }
        return FolderChange(source: source, destination: destination, count: contents(of: source).queries.count,
                            sharedWith: others.map(\.displayName))
    }

    public enum Transfer: Sendable { case move, copy }

    /// Moves or copies the queries in `source` and its folders into `destination`, merging
    /// folders by name. A name already taken there gets a number ("report 2"); nothing is
    /// overwritten. A move removes the folders it empties, and `source` too when `removeSource`
    /// is set and nothing else is in it. Returns each query's new `Query.path` by its old one.
    @discardableResult
    public static func transfer(_ mode: Transfer, from source: URL, to destination: URL,
                                removeSource: Bool = false) throws -> [String: String] {
        let fm = FileManager.default
        let (folders, queries) = contents(of: source)
        func target(_ folder: String) -> URL {
            folder.isEmpty ? destination : destination.appending(path: folder, directoryHint: .isDirectory)
        }
        // A destination inside the source isn't one of its folders.
        let moving = folders.filter { !sameDirectory(source.appending(path: $0, directoryHint: .isDirectory), destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for folder in moving { try fm.createDirectory(at: target(folder), withIntermediateDirectories: true) }
        var moved: [String: String] = [:]
        func path(_ folder: String, _ url: URL) -> String {
            let name = url.deletingPathExtension().lastPathComponent
            return folder.isEmpty ? name : folder + "/" + name
        }
        for (folder, url) in queries where folder.isEmpty || moving.contains(folder) {
            let to = available(url.deletingPathExtension().lastPathComponent, in: target(folder))
            if mode == .move { try fm.moveItem(at: url, to: to) } else { try fm.copyItem(at: url, to: to) }
            moved[path(folder, url)] = path(folder, to)
        }
        guard mode == .move else { return moved }
        for folder in moving { removeIfEmpty(source.appending(path: folder, directoryHint: .isDirectory)) }
        if removeSource { removeIfEmpty(source) }
        return moved
    }

    /// `<name>.sql` in `dir`, or `<name> 2.sql`, `<name> 3.sql`… when that's taken.
    static func available(_ name: String, in dir: URL) -> URL {
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: candidate + ".sql").path) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return dir.appending(path: candidate + ".sql")
    }

    /// Removes `dir` when nothing but Finder's `.DS_Store` is left in it.
    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let left = try? fm.contentsOfDirectory(atPath: dir.path), left.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? fm.removeItem(at: dir)
    }

    /// Earlier versions kept each connection's queries in `<root>/Queries/<connection id>/`.
    /// A saved connection without a queries folder keeps that one when it exists, and gets its
    /// name otherwise. Nothing moves.
    public static func adoptLegacyFolders(store: ConnectionStore, root: URL) throws {
        for var config in store.connections where config.queriesFolder.isEmpty {
            let legacy = queriesRoot(root).appending(path: config.id.uuidString, directoryHint: .isDirectory)
            config.queriesFolder = FileManager.default.fileExists(atPath: legacy.path) ? config.id.uuidString : defaultFolder(for: config)
            try store.save(config)
        }
    }
}
