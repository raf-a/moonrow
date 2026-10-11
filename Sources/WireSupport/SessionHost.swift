import DBKit
import Foundation

/// One authenticated protocol session with a server.
public protocol WireSession: AnyObject, Sendable {
    /// False once the socket is gone; the host then opens a new session for the next call.
    var isAlive: Bool { get }

    /// Runs one statement, handing over rows in batches of up to `batchSize`. The last batch
    /// carries `rowsAffected` for statements that don't return rows. When `cancel` fires,
    /// the session stops the statement server-side, drains its replies, and throws
    /// `CancellationError`, leaving the session ready for the next statement.
    func run(
        _ statement: SQLStatement, batchSize: Int, cancel: CancelSignal,
        onBatch: @Sendable (ResultBatch) -> Void
    ) async throws

    func close() async
}

/// Set when a statement's consumer goes away. The session registers how to stop the statement
/// (an out-of-band cancel request) while it waits for results.
public final class CancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var handler: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { fired } }

    public func fire() {
        let h: (@Sendable () -> Void)? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            return handler
        }
        h?()
    }

    /// Runs `handler` on `fire()`, or right away if it already fired.
    public func whenCancelled(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if fired { return true }
            self.handler = handler
            return false
        }
        if runNow { handler() }
    }

    public func clearHandler() {
        lock.withLock { handler = nil }
    }
}

/// Owns a connection's session: runs one exchange at a time, opens the session again after the
/// server dropped it (between statements only, so nothing runs twice), and adapts `run` to
/// `DatabaseConnection.stream`.
public final class SessionHost<Session: WireSession>: @unchecked Sendable {
    private let lock = AsyncLock()
    private let open: @Sendable () async throws -> Session
    // Guarded by `lock`.
    private var session: Session?
    private var isClosed = false

    /// `first` is the session opened while connecting; `open` makes replacements.
    public init(first: Session, open: @escaping @Sendable () async throws -> Session) {
        self.session = first
        self.open = open
    }

    public func withSession<T: Sendable>(_ body: @Sendable (Session) async throws -> T) async throws -> T {
        try await lock.withLock {
            try await body(self.liveSession())
        }
    }

    private func liveSession() async throws -> Session {
        if isClosed { throw DatabaseError("The connection is closed.") }
        if let s = session, s.isAlive { return s }
        await session?.close()
        session = nil
        let s = try await open()
        session = s
        return s
    }

    public func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        AsyncThrowingStream { continuation in
            let cancel = CancelSignal()
            let task = Task {
                do {
                    try await self.withSession { session in
                        // Consumer already gone: don't start the statement at all.
                        if cancel.isCancelled { throw CancellationError() }
                        try await session.run(statement, batchSize: max(1, batchSize), cancel: cancel) {
                            continuation.yield($0)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .finished = reason { return }
                cancel.fire()
                _ = task
            }
        }
    }

    public func close() async {
        await lock.lock()
        isClosed = true
        let s = session
        session = nil
        await lock.unlock()
        await s?.close()
    }
}
