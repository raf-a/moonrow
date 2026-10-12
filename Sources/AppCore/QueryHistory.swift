import Foundation

/// Statements run from the query editor, per connection, newest first.
///
/// Stored as JSON lines (`History/<connection-id>.jsonl`), appended as statements run. The
/// list shows each distinct statement once, at its latest run. When the file holds well over
/// `limit` entries it is rewritten with the newest `limit` distinct ones.
@MainActor
public final class QueryHistory {
    /// Posted (object: the history) after entries are added or removed.
    public static let didChange = Notification.Name("QueryHistory.didChange")

    public struct Entry: Codable, Sendable, Hashable {
        public var sql: String
        public var date: Date
        /// Milliseconds the statement took.
        public var ms: Int?
        /// False when the statement failed.
        public var ok: Bool

        public init(sql: String, date: Date = Date(), ms: Int? = nil, ok: Bool = true) {
            self.sql = sql
            self.date = date
            self.ms = ms
            self.ok = ok
        }
    }

    public let fileURL: URL
    public let limit: Int
    /// Newest first, one per distinct statement.
    public private(set) var entries: [Entry] = []
    private var linesInFile = 0

    public init(fileURL: URL, limit: Int = 5000) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        load()
    }

    /// `<root>/History/<id>.jsonl`.
    public static func fileURL(root: URL, connection id: UUID) -> URL {
        root.appending(path: "History", directoryHint: .isDirectory).appending(path: "\(id.uuidString).jsonl")
    }

    /// Reads the file. Lines that don't parse are skipped, so one bad write can't lose the rest.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            linesInFile = 0
            return
        }
        let decoder = Self.decoder
        var all: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) { all.append(entry) }
        }
        linesInFile = all.count
        entries = Self.distinctNewestFirst(all)
    }

    public func add(_ entry: Entry) {
        let sql = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        var entry = entry
        entry.sql = sql
        entries.removeAll { $0.sql == sql }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        do {
            if linesInFile + 1 > limit + limit / 10 {
                try rewrite()
            } else {
                try append(entry)
            }
        } catch {
            // History is best effort; a failed write must not interrupt running queries.
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Entries whose SQL contains `text`, ignoring case. Empty text matches everything.
    public func search(_ text: String) -> [Entry] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.sql.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Entries under a date heading: Today, Yesterday, Previous 7 Days, Previous 30 Days, then
    /// one group per month ("September 2026"). `entries` are newest first, and so are the groups.
    public struct Group: Sendable, Hashable {
        public var title: String
        public var entries: [Entry]
    }

    public nonisolated static func grouped(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        func title(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            switch days {
            case ..<1: return "Today"
            case 1: return "Yesterday"
            case 2..<7: return "Previous 7 Days"
            case 7..<30: return "Previous 30 Days"
            default:
                let f = DateFormatter()
                f.calendar = calendar
                f.timeZone = calendar.timeZone
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "LLLL yyyy"
                return f.string(from: date)
            }
        }
        var groups: [Group] = []
        for entry in entries {
            let t = title(entry.date)
            if groups.last?.title == t { groups[groups.count - 1].entries.append(entry) }
            else { groups.append(Group(title: t, entries: [entry])) }
        }
        return groups
    }

    public func remove(_ entry: Entry) throws {
        entries.removeAll { $0.sql == entry.sql }
        try rewrite()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func clear() throws {
        entries = []
        try rewrite()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - File

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static func distinctNewestFirst(_ chronological: [Entry]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for entry in chronological.reversed() where seen.insert(entry.sql).inserted { out.append(entry) }
        return out
    }

    private func append(_ entry: Entry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
        linesInFile += 1
    }

    private func rewrite() throws {
        var data = Data()
        for entry in entries.reversed() {
            data.append(try Self.encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        linesInFile = entries.count
    }
}
