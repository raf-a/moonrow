import DBKit
import Foundation
import NIOCore
import Testing
@testable import WireSupport

/// Newline-terminated messages, so a test can say where one ends.
struct LineFramer: Framer {
    func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return buffer.readSlice(length: view.distance(from: view.startIndex, to: newline) + 1)
    }
}

extension WireChannel {
    func sendLine(_ text: String) async throws {
        var b = makeBuffer()
        b.writeString(text + "\n")
        try await send(b)
    }

    func nextLine() async throws -> String {
        var frame = try await next()
        return frame.readString(length: frame.readableBytes) ?? ""
    }

    /// Waits until bytes from the server have arrived and not been read.
    func waitForUnread() async throws {
        while !(try await hasUnread()) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

struct ScriptError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension FakePeer {
    func writeLine(_ text: String) async throws { try await write(Array((text + "\n").utf8)) }

    func readLine(_ text: String) async throws {
        let bytes = try await read(text.utf8.count + 1)
        guard bytes == Array((text + "\n").utf8) else { throw ScriptError("expected \(text), got \(bytes)") }
    }
}

/// A TLS upgrade only goes ahead on a stream with nothing left over from before it: anything the
/// channel received in the clear and hasn't read would otherwise come out of `next` as if the
/// TLS server had sent it.
@Suite(.timeLimit(.minutes(1))) struct WireChannelTLSTests {
    static let plaintext = "Unencrypted data arrived"

    private func connect(_ server: FakeServer, timeout: TimeAmount = .seconds(15)) async throws -> WireChannel {
        try await WireChannel.connect(to: .tcp(host: "127.0.0.1", port: server.port), framer: LineFramer(), timeout: timeout)
    }

    /// After a refused upgrade or framer swap: the socket closes and nothing received before is
    /// handed out.
    private func expectAbandoned(_ wire: WireChannel) async {
        await wire.waitUntilClosed()
        #expect(!wire.isActive)
        await #expect(throws: DatabaseError.self) { try await wire.next() }
    }

    /// The server's "go ahead" and its first encrypted line, with `extra` sent in between.
    private func upgradingServer(extra: (@Sendable (FakePeer) async throws -> Void)?) -> @Sendable (FakePeer) async throws -> Void {
        { peer in
            try await peer.readLine("starttls")
            try await peer.writeLine("go")
            if let extra { try await extra(peer) }
            try await peer.startTLS(try TestCertificate.get().server)
            try await peer.writeLine("secret")
            await peer.waitUntilClosed()
        }
    }

    @Test func cleanUpgradeReadsWhatTheTLSServerSent() async throws {
        try await FakeServer.run(upgradingServer(extra: nil)) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            try await wire.sendLine("starttls")
            #expect(try await wire.nextLine() == "go\n")
            try await wire.startTLS(try TestCertificate.verifyFull())
            #expect(wire.isTLS)
            #expect(try await wire.nextLine() == "secret\n")
        }
    }

    /// Sent in the same segment as the answer: decoded in the same batch, not read yet.
    @Test func messageInTheSameReadFailsTheUpgrade() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.readLine("starttls")
            try await peer.write(Array("go\nforged\n".utf8))
            try await peer.startTLS(try TestCertificate.get().server)
            try await peer.writeLine("secret")
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            try await wire.sendLine("starttls")
            #expect(try await wire.nextLine() == "go\n")
            let error = await #expect(throws: DatabaseError.self) { try await wire.startTLS(try TestCertificate.verifyFull()) }
            #expect(error?.message.hasPrefix(Self.plaintext) == true)
            #expect(!wire.isTLS)
            await expectAbandoned(wire)
        }
    }

    /// Sent after the answer was read, before the TLS handler goes in: waiting in the inbox.
    @Test func messageInALaterReadFailsTheUpgrade() async throws {
        let extra: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.readLine("ready")
            try await peer.writeLine("forged")
        }
        try await FakeServer.run(upgradingServer(extra: extra)) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            try await wire.sendLine("starttls")
            #expect(try await wire.nextLine() == "go\n")
            try await wire.sendLine("ready")
            try await wire.waitForUnread()
            let error = await #expect(throws: DatabaseError.self) { try await wire.startTLS(try TestCertificate.verifyFull()) }
            #expect(error?.message.hasPrefix(Self.plaintext) == true)
            #expect(!wire.isTLS)
            await expectAbandoned(wire)
        }
    }

    /// Part of a message, which the framer is still waiting to complete.
    @Test func partialMessageFailsTheUpgrade() async throws {
        let extra: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.readLine("ready")
            try await peer.write(Array("forg".utf8))
        }
        try await FakeServer.run(upgradingServer(extra: extra)) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            try await wire.sendLine("starttls")
            #expect(try await wire.nextLine() == "go\n")
            try await wire.sendLine("ready")
            try await wire.waitForUnread()
            let error = await #expect(throws: DatabaseError.self) { try await wire.startTLS(try TestCertificate.verifyFull()) }
            #expect(error?.message.hasPrefix(Self.plaintext) == true)
            await expectAbandoned(wire)
        }
    }

    /// A server that takes the upgrade and then never answers the client's hello.
    @Test func silentHandshakeTimesOut() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.readLine("starttls")
            try await peer.writeLine("go")
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let wire = try await connect(server, timeout: .milliseconds(300))
            defer { wire.close() }
            try await wire.sendLine("starttls")
            #expect(try await wire.nextLine() == "go\n")
            let error = await #expect(throws: DatabaseError.self) { try await wire.startTLS(try TestCertificate.verifyFull()) }
            #expect(error?.message.hasSuffix("failed: timed out") == true, "\(error?.message ?? "")")
            #expect(!wire.isTLS)
            await expectAbandoned(wire)
        }
    }

    /// The new framer never sees bytes the old one left half-read.
    @Test func swappingTheFramerRefusesAPartialMessage() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Array("one\ntw".utf8))
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            #expect(try await wire.nextLine() == "one\n")
            try await wire.waitForUnread()
            await #expect(throws: DatabaseError.self) { try await wire.setFramer(LineFramer()) }
            await expectAbandoned(wire)
        }
    }

    /// Nor whole messages the old one decoded and nobody read.
    @Test func swappingTheFramerRefusesUnreadMessages() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Array("one\ntwo\n".utf8))
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            #expect(try await wire.nextLine() == "one\n")
            try await wire.waitForUnread()
            await #expect(throws: DatabaseError.self) { try await wire.setFramer(LineFramer()) }
            await expectAbandoned(wire)
        }
    }

    @Test func swappingTheFramerAfterReadingEverything() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Array("one\n".utf8))
            try await peer.readLine("ready")
            try await peer.write(Array("two\n".utf8))
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let wire = try await connect(server)
            defer { wire.close() }
            #expect(try await wire.nextLine() == "one\n")
            try await wire.setFramer(LineFramer())
            try await wire.sendLine("ready")
            #expect(try await wire.nextLine() == "two\n")
        }
    }
}
