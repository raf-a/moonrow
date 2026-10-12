import Foundation

/// One statement a connection sent to the database, for the workspace's query log.
public struct StatementLogEntry: Sendable, Hashable {
    public var sql: String
    /// Values bound to the statement's placeholders, in order.
    public var bindings: [DBValue]
    /// When the statement was sent.
    public var started: Date
    public var duration: Duration
    /// Rows returned, or rows changed by a statement that returns none. Nil when unknown.
    public var rows: Int?
    /// The database's error, or "Cancelled".
    public var error: String?

    public init(sql: String, bindings: [DBValue] = [], started: Date, duration: Duration, rows: Int? = nil, error: String? = nil) {
        self.sql = sql
        self.bindings = bindings
        self.started = started
        self.duration = duration
        self.rows = rows
        self.error = error
    }
}

/// Where a connection reports every statement it sends: browsing, introspection, commits and
/// query tabs alike. Drivers call `record` once per statement, when it ends; nothing is kept
/// while no observer is set.
public final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable (StatementLogEntry) -> Void)?

    public init() {}

    /// Replaces the observer; nil stops reporting. Called on whatever thread the driver runs.
    public func observe(_ observer: (@Sendable (StatementLogEntry) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    public var isObserved: Bool { lock.withLock { observer != nil } }

    public func record(_ entry: StatementLogEntry) {
        lock.withLock { observer }?(entry)
    }

    /// Times `body` and records it as `statement`, with the rows `rows` reads from its result.
    public func timing<T>(
        _ statement: SQLStatement, rows: (T) -> Int? = { _ in nil }, _ body: () throws -> T
    ) rethrows -> T {
        guard isObserved else { return try body() }
        let started = Date(), clock = ContinuousClock(), start = clock.now
        do {
            let value = try body()
            record(StatementLogEntry(sql: statement.sql, bindings: statement.bindings, started: started,
                                     duration: clock.now - start, rows: rows(value)))
            return value
        } catch {
            record(StatementLogEntry(sql: statement.sql, bindings: statement.bindings, started: started,
                                     duration: clock.now - start, error: Self.describe(error)))
            throw error
        }
    }

    /// The async form of `timing`.
    public func timing<T>(
        _ statement: SQLStatement, rows: (T) -> Int? = { _ in nil }, _ body: () async throws -> T
    ) async rethrows -> T {
        guard isObserved else { return try await body() }
        let started = Date(), clock = ContinuousClock(), start = clock.now
        do {
            let value = try await body()
            record(StatementLogEntry(sql: statement.sql, bindings: statement.bindings, started: started,
                                     duration: clock.now - start, rows: rows(value)))
            return value
        } catch {
            record(StatementLogEntry(sql: statement.sql, bindings: statement.bindings, started: started,
                                     duration: clock.now - start, error: Self.describe(error)))
            throw error
        }
    }

    public static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "Cancelled" }
        return (error as? DatabaseError)?.message ?? "\(error)"
    }
}

/// Counts what a statement's batches return, for its log entry: rows, or rows changed.
public final class RowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = 0
    private var affected: Int?

    public init() {}

    public func add(_ batch: ResultBatch) {
        lock.withLock {
            rows += batch.rows.count
            if let n = batch.rowsAffected { affected = n }
        }
    }

    /// Rows changed when the statement returned none, else rows returned.
    public var value: Int { lock.withLock { rows == 0 ? affected ?? 0 : rows } }
}
