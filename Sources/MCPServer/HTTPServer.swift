import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// HTTP/1.1 on SwiftNIO, TLS optional, handing each request to an `MCPRouter`.
public final class MCPHTTPServer: @unchecked Sendable {
    let router: MCPRouter
    private let lock = NSLock()
    private var channel: (any Channel)?

    public init(router: MCPRouter) {
        self.router = router
    }

    /// Binds `host`, trying `ports` in turn, then any free port when `anyPort`. Returns the port.
    /// A listener from an earlier start is closed first, so none is left behind.
    public func start(host: String, ports: [Int], anyPort: Bool = true, tls: NIOSSLContext?) async throws -> Int {
        await stop()
        let router = self.router
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: true)
                    try channel.pipeline.syncOperations.addHandler(HTTPHandler(router: router))
                }
            }
        var lastError: (any Error)?
        for port in ports + (anyPort ? [0] : []) {
            do {
                let channel = try await bootstrap.bind(host: host, port: port).get()
                lock.withLock { self.channel = channel }
                return channel.localAddress?.port ?? port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MCPToolError("No port to listen on.")
    }

    public func stop() async {
        let channel = lock.withLock { () -> (any Channel)? in
            defer { self.channel = nil }
            return self.channel
        }
        try? await channel?.close()
    }
}

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let router: MCPRouter
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false

    init(router: MCPRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
            tooLarge = false
        case .body(var chunk):
            guard !tooLarge else { return }
            if body.readableBytes + chunk.readableBytes > MCPRouter.maxBody {
                tooLarge = true
                body.clear()
            } else {
                body.writeBuffer(&chunk)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let channel = context.channel
            let keepAlive = head.isKeepAlive && !tooLarge
            let request = MCPHTTPRequest(
                method: head.method.rawValue, path: head.uri, headers: head.headers.map { ($0.name, $0.value) },
                body: tooLarge ? Data() : Data(body.readableBytesView),
                clientAddress: channel.remoteAddress?.ipAddress ?? "unknown")
            body.clear()
            let router = self.router
            let large = tooLarge
            let version = head.version
            Task {
                let response = large ? MCPHTTPResponse(status: 413) : await router.handle(request)
                await Self.write(response, version: version, keepAlive: keepAlive, on: channel)
            }
        }
    }

    private static func write(_ response: MCPHTTPResponse, version: HTTPVersion, keepAlive: Bool, on channel: any Channel) async {
        var headers = HTTPHeaders(response.headers)
        headers.add(name: "Server", value: "Moonrow")
        let status = HTTPResponseStatus(statusCode: response.status)
        switch response.body {
        case .data(let data):
            headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
            headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
            channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: version, status: status, headers: headers)), promise: nil)
            if !data.isEmpty { channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data))), promise: nil) }
            try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            if !keepAlive { try? await channel.close() }
        case .events(let stream):
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
            channel.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: version, status: status, headers: headers)), promise: nil)
            // A client that goes away stops the stream (not the request it was answering).
            let reader = Task {
                for await event in stream {
                    guard channel.isActive else { break }
                    let bytes = ByteBuffer(string: event.text)
                    try? await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bytes)))
                }
            }
            channel.closeFuture.whenComplete { _ in reader.cancel() }
            await reader.value
            if channel.isActive {
                try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
                if !keepAlive { try? await channel.close() }
            }
        }
    }
}
