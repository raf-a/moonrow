import DBKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Where a server listens.
public enum Endpoint: Sendable, Hashable, CustomStringConvertible {
    case tcp(host: String, port: Int)
    case unixSocket(path: String)
    /// Carried by something else, such as an SSH tunnel.
    case stream(StreamOpener)

    public var description: String {
        switch self {
        case .tcp(let host, let port): host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .unixSocket(let path): path
        case .stream(let opener): opener.description
        }
    }

    /// The host name to check certificates against, nil for sockets and IP literals.
    public var hostName: String? {
        switch self {
        case .tcp(let host, _): Self.isIPAddress(host) ? nil : host
        case .unixSocket: nil
        case .stream(let opener): opener.hostName
        }
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

/// Splits the inbound byte stream into protocol messages.
public protocol Framer: Sendable {
    /// The next whole message at the front of `buffer`, consuming it; nil if more bytes are needed.
    func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer?
}

/// One byte per message. For the single byte Postgres sends back to an SSLRequest: anything
/// after it stays unread, so a TLS upgrade or a framer swap refuses it.
public struct ByteFramer: Framer {
    public init() {}
    public func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        buffer.readableBytes > 0 ? buffer.readSlice(length: 1) : nil
    }
}

public enum WireError: Error, Sendable, CustomStringConvertible {
    case closed
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .closed: "The server closed the connection."
        case .protocolViolation(let what): "Unexpected data from the server: \(what)"
        }
    }
}

/// One socket to a database server: ordered writes, and reads one message at a time.
///
/// Not thread-safe: a session uses it from one task at a time (the driver's lock).
public final class WireChannel: @unchecked Sendable {
    private let channel: any Channel
    private let inbox: FrameInbox
    private var diagnostics: (@Sendable () async -> String?)?
    private var pending: [ByteBuffer] = []
    private var pendingIndex = 0
    /// How long a connect, and a TLS handshake started later, may take.
    private let timeout: TimeAmount
    public let endpoint: Endpoint
    public private(set) var isTLS = false

    private init(channel: any Channel, inbox: FrameInbox, endpoint: Endpoint, timeout: TimeAmount) {
        self.channel = channel
        self.inbox = inbox
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// Bytes the server sent before a TLS upgrade, which the channel hadn't read yet. Anyone on
    /// the path could have sent them, and they would otherwise be read as if they came over TLS.
    private struct PlaintextBeforeTLS: Error {}

    private struct HandshakeTimedOut: Error {}

    /// Connects within `timeout`; a TLS handshake started later gets as long.
    public static func connect(
        to endpoint: Endpoint, framer: any Framer, timeout: TimeAmount = .seconds(15)
    ) async throws -> WireChannel {
        let inbox = FrameInbox(framer: framer)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(inbox)
                }
            }
        do {
            let channel: any Channel
            switch endpoint {
            case .tcp(let host, let port):
                channel = try await bootstrap
                    .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                    .connect(host: host, port: port).get()
            case .unixSocket(let path):
                channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
            case .stream(let opener):
                let stream = try await opener.open()
                do {
                    channel = try await bootstrap.withConnectedSocket(stream.descriptor).get()
                } catch {
                    Darwin.close(stream.descriptor)
                    throw error
                }
                let wire = WireChannel(channel: channel, inbox: inbox, endpoint: endpoint, timeout: timeout)
                wire.diagnostics = stream.diagnostics
                return wire
            }
            return WireChannel(channel: channel, inbox: inbox, endpoint: endpoint, timeout: timeout)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError("Can't connect to \(endpoint): \(describe(error))")
        }
    }

    public var isActive: Bool { channel.isActive }

    /// Queues bytes without sending them; `flush` sends everything queued.
    public func write(_ buffer: ByteBuffer) {
        channel.write(buffer, promise: nil)
    }

    public func flush() {
        channel.flush()
    }

    public func send(_ buffer: ByteBuffer) async throws {
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            throw DatabaseError("Lost the connection to the server: \(Self.describe(error))")
        }
    }

    public func makeBuffer(capacity: Int = 256) -> ByteBuffer {
        channel.allocator.buffer(capacity: capacity)
    }

    /// The next message. Waits for the server; fails once the connection is gone.
    public func next() async throws -> ByteBuffer {
        if pendingIndex < pending.count {
            defer { pendingIndex += 1 }
            return pending[pendingIndex]
        }
        do {
            pending = try await inbox.take()
        } catch {
            // A carried stream ends when its carrier gives up; its reason beats "closed".
            if let reason = await diagnostics?(), !reason.isEmpty {
                throw DatabaseError("Lost the connection to the server: \(reason)")
            }
            throw DatabaseError("Lost the connection to the server: \(Self.describe(error))")
        }
        pendingIndex = 1
        return pending[0]
    }

    /// Switches how incoming bytes are split. Every byte received in the old framing has to have
    /// been read: anything left over, whole messages or part of one, would otherwise be read with
    /// the new framing, so it fails the switch and closes the connection.
    public func setFramer(_ framer: any Framer) async throws {
        let inbox = inbox
        let batchRead = pendingIndex >= pending.count
        let drained = try await channel.eventLoop.submit {
            let drained = inbox.isDrained
            inbox.framer = framer
            return drained
        }.get()
        guard batchRead, drained else {
            abandon()
            throw DatabaseError("The server sent more than expected before the protocol's framing changed, so the connection was closed.")
        }
    }

    /// Whether the server sent anything the channel hasn't handed out yet, whole or in part.
    func hasUnread() async throws -> Bool {
        let inbox = inbox
        let drained = try await channel.eventLoop.submit { inbox.isDrained }.get()
        return pendingIndex < pending.count || !drained
    }

    /// Wraps the socket in TLS from here on (after the protocol's own "upgrade" exchange).
    ///
    /// Everything read from here on is what the TLS server sent. Messages already received in the
    /// clear and not read yet would come out of `next` first, as if they had been encrypted, so
    /// their presence fails the upgrade. Any failure closes the connection, and nothing received
    /// before it is handed out afterwards.
    public func startTLS(_ settings: TLSSettings, alpn: [String] = []) async throws {
        do {
            try await upgrade(settings, alpn: alpn)
            isTLS = true
        } catch {
            // A carried stream ends when its carrier gives up; its reason beats "closed". Asked
            // before closing our end, which the carrier would report instead.
            var reason: String?
            if error is WireError || error is IOError || error is ChannelError {
                reason = await diagnostics?()
            }
            abandon()
            switch error {
            case let e as DatabaseError: throw e
            case is PlaintextBeforeTLS:
                throw DatabaseError(
                    "Unencrypted data arrived from \(endpoint) before the TLS handshake, so the connection was closed. "
                        + "It may have been sent by someone else on the network.")
            case is HandshakeTimedOut: throw DatabaseError("TLS handshake with \(endpoint) failed: timed out")
            default:
                let why = reason.flatMap { $0.isEmpty ? nil : $0 } ?? Self.describe(error)
                throw DatabaseError("TLS handshake with \(endpoint) failed: \(why)")
            }
        }
    }

    private func upgrade(_ settings: TLSSettings, alpn: [String]) async throws {
        guard pendingIndex >= pending.count else { throw PlaintextBeforeTLS() }
        let configuration = try settings.configuration(alpn: alpn)
        let context: NIOSSLContext
        do {
            context = try NIOSSLContext(configuration: configuration)
        } catch {
            throw DatabaseError("Can't set up TLS: \(Self.describe(error))")
        }
        let hostName = settings.serverName ?? endpoint.hostName
        let inbox = inbox
        let channel = channel
        let timeout = timeout
        try await channel.eventLoop.flatSubmit {
            // Checked in the same event loop turn that adds the handler, so no read can land
            // between the check and the handler: bytes that arrive later go through TLS.
            guard inbox.isDrained else {
                return channel.eventLoop.makeFailedFuture(PlaintextBeforeTLS()) as EventLoopFuture<Void>
            }
            // Closed already: the handler would never see the handshake finish.
            guard channel.isActive else {
                return channel.eventLoop.makeFailedFuture(inbox.failure ?? WireError.closed) as EventLoopFuture<Void>
            }
            let done = channel.eventLoop.makePromise(of: Void.self)
            do {
                let handler = try NIOSSLClientHandler(context: context, serverHostname: hostName)
                inbox.tlsHandshake = done
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            } catch {
                inbox.tlsHandshake = nil
                done.fail(error)
                return done.futureResult
            }
            // A server that takes the upgrade and then goes quiet would otherwise hold the
            // connection until TCP gives up, hours later.
            let timer = channel.eventLoop.scheduleTask(in: timeout) { inbox.failHandshake(HandshakeTimedOut()) }
            done.futureResult.whenComplete { _ in timer.cancel() }
            return done.futureResult
        }.get()
    }

    /// Closes the connection and drops everything received and not handed out, so `next` can't
    /// return any of it.
    private func abandon() {
        pending = []
        pendingIndex = 0
        inbox.discard()
        close()
    }

    public func close() {
        channel.close(promise: nil)
    }

    /// Resolves when the server closes its end (used to know a cancel request was handled).
    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? DatabaseError { return e.message }
        if let e = error as? WireError { return e.description }
        if let e = error as? IOError { return String(cString: strerror(e.errnoCode)) }
        if error is ChannelError {
            switch error as! ChannelError {
            case .connectTimeout: return "timed out"
            case .ioOnClosedChannel, .alreadyClosed, .eof: return "the connection is closed"
            default: break
            }
        }
        if let e = error as? NIOConnectionError {
            if e.dnsAAAAError != nil || e.dnsAError != nil, e.connectionErrors.isEmpty {
                return "unknown host \(e.host)"
            }
            if let first = e.connectionErrors.first { return describe(first.error) }
        }
        if let e = error as? NIOSSLError { return "\(e)" }
        return "\(error)"
    }
}

/// Collects decoded messages on the event loop and hands them to the reading task in batches.
final class FrameInbox: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    // Event loop only.
    var framer: any Framer
    var tlsHandshake: EventLoopPromise<Void>?
    private var cumulation: ByteBuffer?

    // Shared with readers, under `lock`.
    private let lock = NSLock()
    private var frames: [ByteBuffer] = []
    private var _failure: (any Error)?
    private var waiter: CheckedContinuation<[ByteBuffer], any Error>?
    /// Set by `discard`: whatever arrives later is dropped.
    private var isDiscarding = false

    init(framer: any Framer) {
        self.framer = framer
    }

    /// Nothing received and not yet taken: no decoded messages, no partial one. Event loop only.
    var isDrained: Bool {
        guard cumulation == nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty
    }

    /// Why the connection ended, once it has.
    var failure: (any Error)? {
        lock.withLock { _failure }
    }

    /// Drops the decoded messages not taken yet, and everything that arrives from now on; a
    /// reader waiting, or coming later, gets "closed". Any thread.
    func discard() {
        lock.lock()
        frames = []
        isDiscarding = true
        if _failure == nil { _failure = WireError.closed }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: WireError.closed)
    }

    /// Ends a TLS handshake in progress with `error`. Event loop only.
    func failHandshake(_ error: any Error) {
        tlsHandshake?.fail(error)
        tlsHandshake = nil
    }

    func take() async throws -> [ByteBuffer] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[ByteBuffer], any Error>) in
            lock.lock()
            if !frames.isEmpty {
                let out = frames
                frames = []
                lock.unlock()
                c.resume(returning: out)
            } else if let failure = _failure {
                lock.unlock()
                c.resume(throwing: failure)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if cumulation == nil {
            cumulation = incoming
        } else {
            cumulation!.writeBuffer(&incoming)
        }
        var produced: [ByteBuffer] = []
        do {
            while let frame = try framer.nextFrame(&cumulation!) { produced.append(frame) }
        } catch {
            fail(error)
            context.close(promise: nil)
            return
        }
        if cumulation!.readableBytes == 0 {
            cumulation = nil
        } else if !produced.isEmpty {
            // The frames are slices of this storage; copy the partial tail so appending to it
            // later doesn't copy the whole buffer.
            var tail = context.channel.allocator.buffer(capacity: cumulation!.readableBytes)
            tail.writeBuffer(&cumulation!)
            cumulation = tail
        }
        guard !produced.isEmpty else { return }
        lock.lock()
        if isDiscarding {
            lock.unlock()
        } else if let w = waiter {
            waiter = nil
            let out = frames + produced
            frames = []
            lock.unlock()
            w.resume(returning: out)
        } else {
            frames += produced
            lock.unlock()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted? = event as? TLSUserEvent {
            tlsHandshake?.succeed()
            tlsHandshake = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(WireError.closed)
    }

    private func fail(_ error: any Error) {
        failHandshake(error)
        lock.lock()
        if _failure == nil { _failure = error }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }
}
