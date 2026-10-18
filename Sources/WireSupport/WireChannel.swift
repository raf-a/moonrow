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

/// Every chunk as it arrives. For the single byte Postgres sends back to an SSLRequest.
public struct RawFramer: Framer {
    public init() {}
    public func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        buffer.readableBytes > 0 ? buffer.readSlice(length: buffer.readableBytes) : nil
    }
}

public enum WireError: Error, Sendable, Equatable, CustomStringConvertible {
    case closed
    case protocolViolation(String)

    /// Bytes the server sent before a TLS upgrade and the channel hadn't read yet. Anyone on the
    /// path could have sent them, and they would otherwise be read as if they came over TLS.
    public static let plaintextBeforeTLS = WireError.protocolViolation("unencrypted data arrived before the TLS handshake")

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
    public let endpoint: Endpoint
    public private(set) var isTLS = false

    private init(channel: any Channel, inbox: FrameInbox, endpoint: Endpoint) {
        self.channel = channel
        self.inbox = inbox
        self.endpoint = endpoint
    }

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
                let wire = WireChannel(channel: channel, inbox: inbox, endpoint: endpoint)
                wire.diagnostics = stream.diagnostics
                return wire
            }
            return WireChannel(channel: channel, inbox: inbox, endpoint: endpoint)
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

    /// Switches how incoming bytes are split, once the bytes for the old framing are consumed.
    /// Fails if part of a message in the old framing is still waiting for the rest of it; those
    /// bytes are dropped rather than read with the new framing.
    public func setFramer(_ framer: any Framer) async throws {
        let inbox = inbox
        let leftover = try await channel.eventLoop.submit { inbox.replaceFramer(framer) }.get()
        if leftover {
            throw DatabaseError(WireError.protocolViolation("part of a message was left when the framing changed").description)
        }
    }

    /// Fails if the server sent anything the channel hasn't read yet. A TLS upgrade has to start
    /// on a stream with nothing left over from the unencrypted part.
    public func expectNothingUnread() async throws {
        let inbox = inbox
        let drained = try await channel.eventLoop.submit { inbox.isDrained }.get()
        guard pendingIndex >= pending.count, drained else { throw plaintextError }
    }

    private var plaintextError: DatabaseError {
        DatabaseError(
            "Unencrypted data arrived from \(endpoint) before the TLS handshake, so the connection was closed. "
                + "It may have been sent by someone else on the network.")
    }

    /// Wraps the socket in TLS from here on (after the protocol's own "upgrade" exchange).
    ///
    /// Everything read from here on is what the TLS server sent. Messages already received in the
    /// clear and not read yet would come out of `next` first, as if they had been encrypted, so
    /// their presence fails the upgrade and closes the connection.
    public func startTLS(_ settings: TLSSettings, alpn: [String] = []) async throws {
        guard pendingIndex >= pending.count else {
            close()
            throw plaintextError
        }
        let configuration: TLSConfiguration
        let context: NIOSSLContext
        do {
            configuration = try settings.configuration(alpn: alpn)
        } catch {
            close()
            throw error
        }
        let hostName = settings.serverName ?? endpoint.hostName
        do {
            context = try NIOSSLContext(configuration: configuration)
        } catch {
            close()
            throw DatabaseError("Can't set up TLS: \(Self.describe(error))")
        }
        let inbox = inbox
        let channel = channel
        do {
            try await channel.eventLoop.flatSubmit {
                // Checked in the same event loop turn that adds the handler, so no read can land
                // between the check and the handler: bytes that arrive later go through TLS.
                guard inbox.isDrained else {
                    return channel.eventLoop.makeFailedFuture(WireError.plaintextBeforeTLS) as EventLoopFuture<Void>
                }
                // Closed already: the handler would never see the handshake finish.
                guard channel.isActive else {
                    return channel.eventLoop.makeFailedFuture(WireError.closed) as EventLoopFuture<Void>
                }
                let done = channel.eventLoop.makePromise(of: Void.self)
                do {
                    let handler = try NIOSSLClientHandler(context: context, serverHostname: hostName)
                    inbox.tlsHandshake = done
                    try channel.pipeline.syncOperations.addHandler(handler, position: .first)
                } catch {
                    done.fail(error)
                }
                return done.futureResult
            }.get()
            isTLS = true
        } catch let error as WireError where error == .plaintextBeforeTLS {
            close()
            throw plaintextError
        } catch {
            close()
            throw DatabaseError("TLS handshake with \(endpoint) failed: \(Self.describe(error))")
        }
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
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<[ByteBuffer], any Error>?

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

    /// Swaps the framer and drops any partial message left by the old one, so its bytes are never
    /// joined to what comes next. True when there was one. Event loop only.
    func replaceFramer(_ framer: any Framer) -> Bool {
        let leftover = cumulation != nil
        cumulation = nil
        self.framer = framer
        return leftover
    }

    func take() async throws -> [ByteBuffer] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[ByteBuffer], any Error>) in
            lock.lock()
            if !frames.isEmpty {
                let out = frames
                frames = []
                lock.unlock()
                c.resume(returning: out)
            } else if let failure {
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
        if let w = waiter {
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
        tlsHandshake?.fail(error)
        tlsHandshake = nil
        lock.lock()
        if failure == nil { failure = error }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }
}
