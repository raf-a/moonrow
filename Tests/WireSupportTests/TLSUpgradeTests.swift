import DBKit
import Foundation
import NIOCore
import Testing
import WireSupport
@testable import DriverMySQL
@testable import DriverPostgres

/// The drivers' TLS upgrades against a server that slips unencrypted replies in before the
/// handshake, the way an attacker on the path would: they must never be read as the server's
/// login replies.
@Suite(.timeLimit(.minutes(1))) struct TLSUpgradeTests {

    // MARK: - MySQL

    /// Protocol 10 greeting offering TLS and mysql_native_password, as packet 0.
    static func mysqlGreeting() -> [UInt8] {
        let caps: UInt32 = 0x1 | 0x200 | 0x800 | 0x2000 | 0x8000 | 0x8_0000 | 0x20_0000 | 0x100_0000
        var p: [UInt8] = [10] + Array("8.0.40-fake".utf8) + [0]
        p += [7, 0, 0, 0]  // connection id
        p += Array("abcdefgh".utf8) + [0]
        p += [UInt8(caps & 0xFF), UInt8(caps >> 8 & 0xFF)]
        p += [45, 2, 0]  // character set, status
        p += [UInt8(caps >> 16 & 0xFF), UInt8(caps >> 24)]
        p += [21] + [UInt8](repeating: 0, count: 10)
        p += Array("ijklmnopqrst".utf8) + [0]
        p += Array("mysql_native_password".utf8) + [0]
        return mysqlPacket(p, sequence: 0)
    }

    static func mysqlOK(sequence: UInt8) -> [UInt8] { mysqlPacket([0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00], sequence: sequence) }

    static func mysqlPacket(_ payload: [UInt8], sequence: UInt8) -> [UInt8] {
        [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count >> 16), sequence] + payload
    }

    /// Reads one packet's payload.
    static func readMySQLPacket(_ peer: FakePeer) async throws -> [UInt8] {
        let header = try await peer.read(4)
        return try await peer.read(Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16)
    }

    func mysql(_ server: FakeServer) throws -> MySQLConfiguration {
        MySQLConfiguration(endpoint: .tcp(host: "127.0.0.1", port: server.port), user: "root", password: "",
                           tls: try TestCertificate.verifyFull(), connectTimeout: 5)
    }

    @Test func mysqlCleanUpgradeLogsIn() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Self.mysqlGreeting())
            let sslRequest = try await Self.readMySQLPacket(peer)
            guard sslRequest.count == 32 else { throw ScriptError("SSLRequest of \(sslRequest.count) bytes") }
            try await peer.startTLS(try TestCertificate.get().server)
            _ = try await Self.readMySQLPacket(peer)  // the login, encrypted
            try await peer.write(Self.mysqlOK(sequence: 3))
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let session = try await MySQLSession.open(try mysql(server))
            #expect(session.io.wire.isTLS)
            await session.close()
        }
    }

    /// An OK packet right behind the greeting, in the same segment, would otherwise answer the
    /// login sent over TLS.
    @Test func mysqlRefusesAPacketQueuedBehindTheGreeting() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Self.mysqlGreeting() + Self.mysqlOK(sequence: 2))
            _ = try await Self.readMySQLPacket(peer)
            try await peer.startTLS(try TestCertificate.get().server)
            _ = try await Self.readMySQLPacket(peer)
            peer.close()  // never answers the login itself
        }
        try await FakeServer.run(script) { server in
            let error = await #expect(throws: DatabaseError.self) {
                let session = try await MySQLSession.open(try mysql(server))
                await session.close()
            }
            #expect(error?.message.hasPrefix("Unencrypted data arrived") == true)
        }
    }

    // MARK: - Postgres

    static let pgLoginReplies: [UInt8] =
        [UInt8(ascii: "R"), 0, 0, 0, 8, 0, 0, 0, 0]  // AuthenticationOk
        + [UInt8(ascii: "K"), 0, 0, 0, 12, 0, 0, 0, 42, 1, 2, 3, 4]  // BackendKeyData
        + [UInt8(ascii: "Z"), 0, 0, 0, 5, UInt8(ascii: "I")]  // ReadyForQuery

    /// Reads the SSLRequest.
    static func readSSLRequest(_ peer: FakePeer) async throws {
        let request = try await peer.read(8)
        guard request == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F] else { throw ScriptError("not an SSLRequest: \(request)") }
    }

    /// Reads the startup message.
    static func readStartup(_ peer: FakePeer) async throws {
        let length = try await peer.read(4)
        _ = try await peer.read((Int(length[0]) << 24 | Int(length[1]) << 16 | Int(length[2]) << 8 | Int(length[3])) - 4)
    }

    func postgres(_ server: FakeServer, directTLS: Bool = false) throws -> PostgresConfiguration {
        PostgresConfiguration(endpoint: .tcp(host: "127.0.0.1", port: server.port), user: "postgres",
                              tls: try TestCertificate.verifyFull(), directTLS: directTLS, connectTimeout: 5)
    }

    @Test func postgresCleanUpgradeLogsIn() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await Self.readSSLRequest(peer)
            try await peer.write([UInt8(ascii: "S")])
            try await peer.startTLS(try TestCertificate.get().server)
            try await Self.readStartup(peer)
            try await peer.write(Self.pgLoginReplies)
            await peer.waitUntilClosed()
        }
        try await FakeServer.run(script) { server in
            let session = try await PGSession.open(try postgres(server))
            #expect(session.wire.isTLS)
            #expect(session.processID == 42)
            await session.close()
        }
    }

    /// Login replies written right after the `S`, as a second segment, before the handshake.
    /// Depending on when they land they are refused with the `S` (same read), or by the upgrade
    /// itself (a later read): never read as the login's replies.
    @Test func postgresRefusesRepliesSentAfterTheAnswer() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await Self.readSSLRequest(peer)
            try await peer.write([UInt8(ascii: "S")])
            try await peer.write(Self.pgLoginReplies)
            try await peer.startTLS(try TestCertificate.get().server)
            try await Self.readStartup(peer)
            peer.close()  // never answers the login itself
        }
        try await FakeServer.run(script) { server in
            let error = await #expect(throws: DatabaseError.self) {
                let session = try await PGSession.open(try postgres(server))
                await session.close()
            }
            let message = error?.message ?? ""
            #expect(message.hasPrefix("Unencrypted data arrived") || message.contains("in reply to the TLS request"), "\(message)")
        }
    }

    /// Direct TLS: login replies the server sends before the handshake are refused. The socket
    /// is handed over once they are readable, so they are received before TLS starts.
    @Test func postgresDirectTLSRefusesRepliesBeforeTheHandshake() async throws {
        let script: @Sendable (FakePeer) async throws -> Void = { peer in
            try await peer.write(Self.pgLoginReplies)
            try await peer.startTLS(try TestCertificate.get().server)
            try await Self.readStartup(peer)
            peer.close()  // never answers the login itself
        }
        try await FakeServer.run(script) { server in
            var c = try postgres(server, directTLS: true)
            c.endpoint = .stream(Self.openedOnceReadable(port: server.port))
            let error = await #expect(throws: DatabaseError.self) {
                let session = try await PGSession.open(c)
                await session.close()
            }
            #expect(error?.message.hasPrefix("Unencrypted data arrived") == true)
        }
    }

    /// A socket to 127.0.0.1 that's returned once the server has sent something.
    static func openedOnceReadable(port: Int) -> StreamOpener {
        StreamOpener(description: "127.0.0.1:\(port)", hostName: "localhost") {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard connected == 0, poll(&ready, 1, 5000) == 1 else {
                Darwin.close(fd)
                throw ScriptError("couldn't connect to the fake server")
            }
            return OpenedStream(descriptor: fd)
        }
    }
}
