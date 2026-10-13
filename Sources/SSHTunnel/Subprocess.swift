import Darwin
import Foundation

/// A child process started with `posix_spawn`: stdin and stdout are /dev/null or one end of a
/// socket pair, stderr is collected. It runs in a session of its own, so it has no controlling
/// terminal and every prompt goes through SSH_ASKPASS.
final class Subprocess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    // Under `lock`.
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var errorOutput = Data()
    private var errorOutputDone = false
    private var errorWaiters: [CheckedContinuation<Void, Never>] = []

    private static let errorOutputLimit = 64 * 1024
    /// Our end of the child's stdin pipe when it has a lifeline; closing it tells the child we're gone.
    private let lifeline: Int32?

    /// `stdio` becomes the child's stdin and stdout; nil gives it /dev/null. With `lifeline`, its
    /// stdin is instead a pipe that reaches EOF when our process ends, however it ends
    /// (`moonrow-ssh-helper --guard` stops ssh then).
    init(
        _ path: String, _ arguments: [String], environment: [String: String], stdio: Int32? = nil,
        lifeline: Bool = false
    ) throws {
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&errPipe) == 0 else { throw SSHTunnelError("Can't start \(path): \(String(cString: strerror(errno)))") }
        // Our ends must not leak into other children, or EOF would never come.
        _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)
        var inPipe: [Int32] = [-1, -1]
        if lifeline {
            guard pipe(&inPipe) == 0 else {
                close(errPipe[0])
                close(errPipe[1])
                throw SSHTunnelError("Can't start \(path): \(String(cString: strerror(errno)))")
            }
            _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdio {
            posix_spawn_file_actions_adddup2(&actions, stdio, 0)
            posix_spawn_file_actions_adddup2(&actions, stdio, 1)
        } else if lifeline {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every other descriptor in the child; detach it from our terminal; undo any
        // signal mask or ignored SIGPIPE inherited from the app.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(errPipe[1])
        if lifeline { close(inPipe[0]) }
        guard status == 0 else {
            close(errPipe[0])
            if lifeline { close(inPipe[1]) }
            throw SSHTunnelError("Can't start \(path): \(String(cString: strerror(status)))")
        }
        self.pid = pid
        self.lifeline = lifeline ? inPipe[1] : nil
        startReadingErrors(errPipe[0])
        startWaiting()
    }

    deinit {
        if let lifeline { close(lifeline) }
    }

    private func startReadingErrors(_ fd: Int32) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                lock.withLock {
                    if errorOutput.count < Self.errorOutputLimit { errorOutput.append(contentsOf: buffer[0..<n]) }
                }
            }
            close(fd)
            let waiters = lock.withLock {
                errorOutputDone = true
                defer { errorWaiters = [] }
                return errorWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    private func startWaiting() {
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            let waiters = lock.withLock {
                exitStatus = code
                defer { exitWaiters = [] }
                return exitWaiters
            }
            waiters.forEach { $0.resume(returning: code) }
        }
    }

    var isRunning: Bool { lock.withLock { exitStatus == nil } }

    /// What it wrote to stderr so far.
    var errors: String { lock.withLock { String(decoding: errorOutput, as: UTF8.self) } }

    /// Waits for the exit status.
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let s = exitStatus {
                lock.unlock()
                c.resume(returning: s)
            } else {
                exitWaiters.append(c)
                lock.unlock()
            }
        }
    }

    /// Waits until the process exited and its stderr is fully read, up to `timeout`; false if
    /// it's still going.
    func waitForExit(timeout: Duration) async -> Bool {
        await withCheckedContinuation { c in
            let once = ResumeOnce(c)
            Task {
                _ = await self.waitForExit()
                await self.waitForErrorOutput()
                once.resume(true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(false)
            }
        }
    }

    private func waitForErrorOutput() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if errorOutputDone {
                lock.unlock()
                c.resume()
            } else {
                errorWaiters.append(c)
                lock.unlock()
            }
        }
    }

    func signal(_ signal: Int32) {
        // Only while it hasn't been reaped, so the pid can't belong to someone else yet.
        lock.withLock {
            if exitStatus == nil { _ = kill(pid, signal) }
        }
    }
}

/// Resumes a continuation with the first value it's given and ignores the rest.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let c = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
