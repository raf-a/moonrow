import Foundation
import NIOCore
import NIOPosix

/// The app's end of SSH_ASKPASS: a Unix socket `tabula-ssh-helper` connects to with
/// one JSON line `{"token", "prompt"}`; the reply is one line `{"answer"}`, or `{}` to cancel.
/// The token (passed to ssh in the environment, along with the socket path) keeps other
/// processes from asking.
final class AskpassServer: Sendable {
    static let socketVariable = "TABULA_ASKPASS_SOCKET"
    static let tokenVariable = "TABULA_ASKPASS_TOKEN"

    let path: String
    let token: String
    private let channel: any Channel

    private init(path: String, token: String, channel: any Channel) {
        self.path = path
        self.token = token
        self.channel = channel
    }

    /// `answer` gets the prompt text and returns the reply, nil to cancel.
    static func start(path: String, answer: @escaping @Sendable (String) async -> String?) async throws -> AskpassServer {
        let token = UUID().uuidString
        unlink(path)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(AskpassHandler(token: token, answer: answer))
                }
            }
            .bind(unixDomainSocketPath: path).get()
        chmod(path, 0o600)
        return AskpassServer(path: path, token: token, channel: channel)
    }

    var environment: [String: String] { [Self.socketVariable: path, Self.tokenVariable: token] }

    func close() {
        channel.close(promise: nil)
    }
}

private struct AskpassRequest: Codable {
    var token: String
    var prompt: String
}

private struct AskpassReply: Codable {
    var answer: String?
}

private final class AskpassHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let token: String
    private let answer: @Sendable (String) async -> String?
    private var received = ByteBuffer()
    private var answered = false

    init(token: String, answer: @escaping @Sendable (String) async -> String?) {
        self.token = token
        self.answer = answer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        received.writeBuffer(&chunk)
        guard !answered, let newline = received.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return }
        answered = true
        let line = received.readableBytesView[received.readerIndex..<newline]
        let channel = context.channel
        guard let request = try? JSONDecoder().decode(AskpassRequest.self, from: Data(line)), request.token == token else {
            channel.close(promise: nil)
            return
        }
        let answer = answer
        Task {
            let reply = AskpassReply(answer: await answer(request.prompt))
            var out = channel.allocator.buffer(capacity: 128)
            out.writeBytes((try? JSONEncoder().encode(reply)) ?? Data("{}".utf8))
            out.writeInteger(UInt8(ascii: "\n"))
            channel.writeAndFlush(out).whenComplete { _ in channel.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
