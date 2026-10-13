import Darwin
import Foundation

/// A TCP port on 127.0.0.1 whose connections go through an SSH tunnel to `host:port`, for
/// programs that only take a host and port (pg_dump, mysqldump). Each accepted connection is
/// handed to its own `ssh -W` mux client; nothing is copied through the app. The port listens
/// until `close()`, so other local programs could connect meanwhile: keep it open only for the
/// one run that needs it.
public final class LocalForward: @unchecked Sendable {
    public let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var closed = false

    init(tunnel: SSHTunnel, host: String, port remotePort: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError("Can't open a local port: \(String(cString: strerror(errno)))") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw SSHTunnelError("Can't open a local port: \(reason)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            acceptLoop(tunnel: tunnel, host: host, port: remotePort)
        }
    }

    deinit { close() }

    private var isClosed: Bool { lock.withLock { closed } }

    private func acceptLoop(tunnel: SSHTunnel, host: String, port: Int) {
        var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !isClosed {
            // Wakes up now and then to notice close().
            let ready = poll(&poller, 1, 200)
            if ready <= 0 { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            Task { await tunnel.carry(client, host: host, port: port) }
        }
        Darwin.close(listener)
    }

    /// Stops listening; connections already made go on until they end (or the tunnel closes).
    public func close() {
        lock.withLock { closed = true }
    }
}

extension SSHTunnel {
    /// Logs in if needed and opens a local port carried to `host:port`.
    public func forward(host: String, port: Int) async throws -> LocalForward {
        try await connect()
        return try LocalForward(tunnel: self, host: host, port: port)
    }
}
