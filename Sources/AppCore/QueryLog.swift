import DBKit
import Foundation

/// The workspace's query log (the bottom panel, ⌃⌘C): every statement its connection sent,
/// newest last, as the connection reports them (`StatementLog`). Kept in memory, at most
/// `limit` entries; the oldest go first.
@MainActor
public final class QueryLog {
    /// Posted (object: the log) after entries are added or the log is cleared.
    public static let didChange = Notification.Name("QueryLog.didChange")

    public let limit: Int
    public private(set) var entries: [StatementLogEntry] = []
    /// Entries dropped from the front since the last clear, so views can tell what's new.
    public private(set) var dropped = 0

    public init(limit: Int = 2_000) {
        self.limit = max(1, limit)
    }

    public func append(_ entry: StatementLogEntry) {
        entries.append(entry)
        if entries.count > limit {
            let extra = entries.count - limit
            entries.removeFirst(extra)
            dropped += extra
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func clear() {
        entries = []
        dropped = 0
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Follows a connection's statements from now on.
    public func follow(_ connection: any DatabaseConnection) {
        // The main queue keeps the drivers' order.
        connection.statementLog?.observe { [weak self] entry in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(entry) } }
        }
    }

    /// Characters in front of each statement: the time and the duration.
    public nonisolated static let prefixWidth = 24

    /// One line per entry: time, duration, rows or error, then the statement on one line with
    /// bound values after it (`-- $1 = 'a', $2 = 3`). A statement its reader stopped (a row
    /// limit, a closed tab, the Stop button) reads "Stopped".
    public nonisolated static func line(_ e: StatementLogEntry, dialect: any Dialect, locale: Locale = .autoupdatingCurrent) -> String {
        var s = time.string(from: e.started) + "  "
            + DurationText.string(e.duration, locale: locale).padding(toLength: 8, withPad: " ", startingAt: 0) + "  "
        s += oneLine(e.sql)
        if !e.bindings.isEmpty {
            let values = e.bindings.enumerated().map { "\(dialect.placeholder($0.offset + 1)) = \(dialect.literal($0.element))" }
            s += "  -- " + values.joined(separator: ", ")
        }
        if e.error == "Cancelled", let rows = e.rows {
            // Stopped by its reader (a row limit, a closed tab) after these rows.
            s += "  -- stopped after \(rows.formatted()) row\(rows == 1 ? "" : "s")"
        } else if let error = e.error { s += "  -- " + (error == "Cancelled" ? "Stopped" : "Error: " + oneLine(error)) }
        else if let rows = e.rows { s += "  -- \(rows.formatted()) row\(rows == 1 ? "" : "s")" }
        return s
    }

    /// Every entry as text, for Copy.
    public func text(dialect: any Dialect) -> String {
        entries.map { Self.line($0, dialect: dialect) }.joined(separator: "\n")
    }

    nonisolated static func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private nonisolated static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
