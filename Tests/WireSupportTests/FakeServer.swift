import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import WireSupport

/// A self-signed certificate for localhost and 127.0.0.1, made once per run with the system's
/// openssl, and the server side's TLS context for it.
enum TestCertificate {
    struct Material: Sendable {
        let certificatePath: String
        let server: NIOSSLContext
    }

    private static let made = Result<Material, any Error> { try make() }

    static func get() throws -> Material { try made.get() }

    /// Client settings that verify the server fully against this certificate.
    static func verifyFull() throws -> TLSSettings {
        TLSSettings(mode: .verifyFull, caCertificatePath: try get().certificatePath, serverName: "localhost")
    }

    private static func make() throws -> Material {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "moonrow-wire-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appending(path: "key.pem"), cert = dir.appending(path: "cert.pem")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-keyout", key.path, "-out", cert.path,
            "-days", "2", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-addext", "extendedKeyUsage=serverAuth",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "openssl couldn't make a test certificate"])
        }
        let chain = try NIOSSLCertificate.fromPEMFile(cert.path).map { NIOSSLCertificateSource.certificate($0) }
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: chain, privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem)))
        return Material(certificatePath: cert.path, server: try NIOSSLContext(configuration: configuration))
    }
}

/// The server's end of one connection, driven by a test's script: raw writes, reads of exact
/// byte counts, and a switch to TLS at any point.
final class FakePeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let channel: any Channel
    private let lock = NSLock()
    private var received: [UInt8] = []
    private var closed = false
    private var waiter: (count: Int, continuation: CheckedContinuation<[UInt8], any Error>)?
    // Event loop only.
    private var handshake: EventLoopPromise<Void>?
    private let active: EventLoopPromise<Void>
    private var isActive = false
    private var isInactive = false

    init(channel: any Channel) {
        self.channel = channel
        active = channel.eventLoop.makePromise()
    }

    /// Resolves once the connection is up, so writes can go out.
    func waitUntilActive() async throws {
        try await active.futureResult.get()
    }

    func write(_ bytes: [UInt8]) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes))
    }

    /// Exactly `count` bytes, waiting for them; fails once the client has closed.
    func read(_ count: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], any Error>) in
            lock.lock()
            if received.count >= count {
                let out = Array(received.prefix(count))
                received.removeFirst(count)
                lock.unlock()
                c.resume(returning: out)
            } else if closed {
                lock.unlock()
                c.resume(throwing: ChannelError.eof)
            } else {
                waiter = (count, c)
                lock.unlock()
            }
        }
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Waits until the client closes its end.
    func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    /// Puts a TLS server handler in front and waits for the handshake to finish. Bytes the
    /// client already sent (its hello, usually) are fed through the new handler.
    func startTLS(_ context: NIOSSLContext) async throws {
        let channel = channel
        try await channel.eventLoop.flatSubmit { [self] in
            let done = channel.eventLoop.makePromise(of: Void.self)
            // The pipeline takes handlers for a moment after the connection closes; this one
            // would never see a handshake.
            guard !isInactive else {
                done.fail(ChannelError.eof)
                return done.futureResult
            }
            do {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context), position: .first)
            } catch {
                done.fail(error)
                return done.futureResult
            }
            handshake = done
            lock.lock()
            let early = received
            received = []
            lock.unlock()
            if !early.isEmpty {
                channel.pipeline.syncOperations.fireChannelRead(NIOAny(ByteBuffer(bytes: early)))
            }
            return done.futureResult
        }.get()
    }

    func channelActive(context: ChannelHandlerContext) {
        isActive = true
        active.succeed()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        lock.lock()
        received += buffer.readableBytesView
        var ready: (CheckedContinuation<[UInt8], any Error>, [UInt8])?
        if let w = waiter, received.count >= w.count {
            waiter = nil
            ready = (w.continuation, Array(received.prefix(w.count)))
            received.removeFirst(w.count)
        }
        lock.unlock()
        if let (c, bytes) = ready { c.resume(returning: bytes) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted? = event as? TLSUserEvent {
            handshake?.succeed()
            handshake = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        handshake?.fail(error)
        handshake = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        isInactive = true
        if !isActive { active.fail(ChannelError.eof) }
        handshake?.fail(ChannelError.eof)
        handshake = nil
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.continuation.resume(throwing: ChannelError.eof)
        context.fireChannelInactive()
    }
}

/// A server on 127.0.0.1 that runs `script` for each connection.
final class FakeServer: @unchecked Sendable {
    let port: Int
    private let listener: any Channel
    private let lock = NSLock()
    private var connections: [(channel: any Channel, script: Task<Void, any Error>)] = []

    private init(listener: any Channel) {
        self.listener = listener
        port = listener.localAddress?.port ?? 0
    }

    /// Starts a server, runs `body` against it, then closes every connection and waits for
    /// their scripts to end. The scripts' own errors are ignored: the client's view is the test.
    static func run<T: Sendable>(
        _ script: @escaping @Sendable (FakePeer) async throws -> Void,
        body: (FakeServer) async throws -> T
    ) async throws -> T {
        let box = Box()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let peer = FakePeer(channel: child)
                    try child.pipeline.syncOperations.addHandler(peer)
                    box.server?.add(child, Task {
                        try await peer.waitUntilActive()
                        try await script(peer)
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = FakeServer(listener: listener)
        box.server = server
        do {
            let result = try await body(server)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    private func add(_ channel: any Channel, _ script: Task<Void, any Error>) {
        lock.withLock { connections.append((channel, script)) }
    }

    private func stop() async {
        let all = lock.withLock { connections }
        for c in all {
            c.channel.close(promise: nil)
            try? await c.channel.closeFuture.get()
        }
        for c in all { _ = await c.script.result }
        listener.close(promise: nil)
        try? await listener.closeFuture.get()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _server: FakeServer?
        var server: FakeServer? {
            get { lock.withLock { _server } }
            set { lock.withLock { _server = newValue } }
        }
    }
}
