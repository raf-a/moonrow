/// A FIFO lock for async code: one wire session runs one exchange at a time, in order.
public actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` alone. Cancellation doesn't skip the wait: a protocol exchange can't be
    /// abandoned halfway, so cancelled work still queues and then fails fast inside `body`.
    public nonisolated func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await lock()
        do {
            let result = try await body()
            await unlock()
            return result
        } catch {
            await unlock()
            throw error
        }
    }
}
