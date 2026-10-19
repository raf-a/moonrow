import DBKit
import Foundation
import NIOCore
import WireSupport

public struct MySQLConfiguration: Sendable, Hashable {
    public var endpoint: Endpoint
    public var user: String
    public var password: String
    /// The default database; nil or empty connects without one.
    public var database: String?
    public var tls: TLSSettings
    /// Puts the session in `READ ONLY` transaction mode, so writes fail on the server.
    public var readOnly: Bool
    /// Seconds to wait for the socket to connect.
    public var connectTimeout: TimeInterval
    /// Statements every new session runs right after logging in, before anything else.
    public var bootstrap: [String]

    public init(
        endpoint: Endpoint = .tcp(host: "127.0.0.1", port: 3306), user: String = "root", password: String = "",
        database: String? = nil, tls: TLSSettings = TLSSettings(), readOnly: Bool = false,
        connectTimeout: TimeInterval = 15, bootstrap: [String] = []
    ) {
        self.endpoint = endpoint
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
        self.readOnly = readOnly
        self.connectTimeout = connectTimeout
        self.bootstrap = bootstrap
    }
}

/// Reads and writes whole packets, keeping the sequence number of the current command.
final class PacketChannel: @unchecked Sendable {
    let wire: WireChannel
    var sequence: UInt8 = 0

    init(_ wire: WireChannel) {
        self.wire = wire
    }

    /// The next payload, with continuation packets (payloads of exactly 0xFFFFFF bytes) joined.
    func read() async throws -> ByteBuffer {
        var (length, payload) = try await nextPacket()
        guard length == maxPacketPayload else { return payload }
        var joined = payload
        while length == maxPacketPayload {
            (length, payload) = try await nextPacket()
            joined.writeBuffer(&payload)
        }
        return joined
    }

    private func nextPacket() async throws -> (Int, ByteBuffer) {
        var frame = try await wire.next()
        guard let b0 = frame.readInteger(as: UInt8.self), let b1 = frame.readInteger(as: UInt8.self),
              let b2 = frame.readInteger(as: UInt8.self), let seq = frame.readInteger(as: UInt8.self)
        else { throw WireError.protocolViolation("short packet header") }
        sequence = seq &+ 1
        return (Int(b0) | Int(b1) << 8 | Int(b2) << 16, frame)
    }

    /// The packets for a payload, numbered from `sequence`. A payload of 0xFFFFFF bytes or more
    /// is split, ending with a shorter (possibly empty) packet.
    static func packets(_ payload: ByteBuffer, sequence: inout UInt8, allocator: ByteBufferAllocator) -> [ByteBuffer] {
        var p = payload
        var out: [ByteBuffer] = []
        while true {
            let n = min(p.readableBytes, maxPacketPayload)
            var packet = allocator.buffer(capacity: 4 + n)
            packet.writeInteger(UInt8(n & 0xFF))
            packet.writeInteger(UInt8((n >> 8) & 0xFF))
            packet.writeInteger(UInt8(n >> 16))
            packet.writeInteger(sequence)
            sequence &+= 1
            var chunk = p.readSlice(length: n)!
            packet.writeBuffer(&chunk)
            out.append(packet)
            if n < maxPacketPayload { return out }
        }
    }

    func send(_ payload: ByteBuffer) async throws {
        let all = Self.packets(payload, sequence: &sequence, allocator: ByteBufferAllocator())
        for packet in all.dropLast() { wire.write(packet) }
        try await wire.send(all.last!)
    }

    /// Starts a new command: sequence numbers restart at 0.
    func command(_ payload: ByteBuffer) async throws {
        sequence = 0
        try await send(payload)
    }

    func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var b = wire.makeBuffer(capacity: bytes.count)
        b.writeBytes(bytes)
        return b
    }
}

/// One authenticated MySQL session. Used by one task at a time (`SessionHost`'s lock).
final class MySQLSession: WireSession, @unchecked Sendable {
    let io: PacketChannel
    let configuration: MySQLConfiguration
    let connectionID: UInt32
    let serverVersion: String
    private let capabilities: Capabilities
    /// False while a command's replies are still coming; an error then leaves the socket
    /// mid-reply, so it gets closed and the next call reconnects.
    private var inSync = true
    /// The connection's query log.
    var log: StatementLog?

    var isAlive: Bool { io.wire.isActive }

    private init(io: PacketChannel, configuration: MySQLConfiguration, connectionID: UInt32,
                 serverVersion: String, capabilities: Capabilities) {
        self.io = io
        self.configuration = configuration
        self.connectionID = connectionID
        self.serverVersion = serverVersion
        self.capabilities = capabilities
    }

    /// A session ready for statements: logged in, then the bootstrap commands run (and logged).
    static func open(_ c: MySQLConfiguration, log: StatementLog?) async throws -> MySQLSession {
        let session = try await open(c)
        session.log = log
        for sql in c.bootstrap {
            do {
                _ = try await session.collect(SQLStatement(sql))
            } catch {
                await session.close()
                throw DatabaseError.bootstrap(error, sql: sql)
            }
        }
        return session
    }

    static func open(_ c: MySQLConfiguration) async throws -> MySQLSession {
        let wire = try await WireChannel.connect(
            to: c.endpoint, framer: MySQLFramer(), timeout: .milliseconds(Int64(c.connectTimeout * 1000)))
        do {
            let session = try await handshake(PacketChannel(wire), c)
            if c.readOnly { _ = try await session.collect(SQLStatement("SET SESSION TRANSACTION READ ONLY")) }
            return session
        } catch {
            wire.close()
            throw error
        }
    }

    func close() async {
        guard io.wire.isActive else { return }
        try? await io.command(io.buffer([0x01])) // COM_QUIT
        io.wire.close()
    }

    // MARK: - Handshake

    private static func handshake(_ io: PacketChannel, _ c: MySQLConfiguration) async throws -> MySQLSession {
        var p = try await io.read()
        if p.firstByte == 0xFF { throw serverError(p, sql: nil) }
        guard p.readInteger(as: UInt8.self) == 10 else {
            throw DatabaseError("The server speaks an unsupported MySQL protocol version.")
        }
        guard let version = p.readCString(), let id = p.readInteger(endianness: .little, as: UInt32.self),
              let part1 = p.readBytes(length: 8) else { throw WireError.protocolViolation("handshake") }
        p.moveReaderIndex(forwardBy: 1)
        var serverBits = UInt32(p.readInteger(endianness: .little, as: UInt16.self) ?? 0)
        var authDataLength = 0
        if p.readableBytes >= 16 {
            _ = p.readInteger(as: UInt8.self) // character set
            _ = p.readInteger(endianness: .little, as: UInt16.self) // status
            serverBits |= UInt32(p.readInteger(endianness: .little, as: UInt16.self) ?? 0) << 16
            authDataLength = Int(p.readInteger(as: UInt8.self) ?? 0)
            p.moveReaderIndex(forwardBy: 10)
        }
        let server = Capabilities(rawValue: serverBits)
        guard server.contains(.protocol41), server.contains(.secureConnection) else {
            throw DatabaseError("MySQL \(version) is too old; 4.1 or later is needed.")
        }
        var nonce = part1
        let part2 = min(max(13, authDataLength - 8), p.readableBytes)
        nonce += p.readBytes(length: part2) ?? []
        while nonce.last == 0 { nonce.removeLast() }
        var plugin = "mysql_native_password"
        if server.contains(.pluginAuth), p.readableBytes > 0 {
            plugin = p.readCString() ?? p.readRemainingString()
        }

        var caps: Capabilities = [
            .longPassword, .longFlag, .protocol41, .transactions, .secureConnection, .multiResults,
            .psMultiResults, .pluginAuth, .pluginAuthLenencData, .deprecateEOF,
        ]
        caps = caps.intersection(server)
        // Matched rather than changed rows, so an UPDATE writing the same value reports 1.
        caps.insert(.foundRows)
        let database = c.database?.trimmingCharacters(in: .whitespaces) ?? ""
        if !database.isEmpty { caps.insert(.connectWithDB) }

        var isSocket = false
        if case .unixSocket = c.endpoint { isSocket = true }
        let required = [.require, .verifyCA, .verifyFull].contains(c.tls.mode)
        let wantsTLS = required || ([.prefer, .allow].contains(c.tls.mode) && !isSocket)
        if wantsTLS {
            if server.contains(.ssl) {
                caps.insert(.ssl)
                var request = io.wire.makeBuffer(capacity: 32)
                writeLoginHeader(caps, into: &request)
                try await io.send(request)
                // Refuses any packet after the greeting: it came in the clear.
                try await io.wire.startTLS(c.tls)
            } else if required {
                throw DatabaseError("The server doesn't support TLS, and the connection requires it.")
            }
        }
        let secure = io.wire.isTLS || isSocket

        if !["mysql_native_password", "caching_sha2_password", "sha256_password", "mysql_clear_password"].contains(plugin) {
            // Answer with the classic scramble; the server switches to its own plugin if it must.
            plugin = "mysql_native_password"
        }
        var response = io.wire.makeBuffer(capacity: 128)
        writeLoginHeader(caps, into: &response)
        response.writeCString(c.user)
        let auth = try authResponse(plugin, c.password, nonce: nonce, secure: secure)
        if caps.contains(.pluginAuthLenencData) {
            response.writeLengthEncodedBytes(auth)
        } else {
            response.writeInteger(UInt8(auth.count))
            response.writeBytes(auth)
        }
        if caps.contains(.connectWithDB) { response.writeCString(database) }
        if caps.contains(.pluginAuth) { response.writeCString(plugin) }
        try await io.send(response)

        try await authenticate(io, c, plugin: plugin, nonce: nonce, secure: secure)
        return MySQLSession(io: io, configuration: c, connectionID: id, serverVersion: version, capabilities: caps)
    }

    /// Capabilities, max packet size, character set (utf8mb4_general_ci) and 23 reserved bytes.
    private static func writeLoginHeader(_ caps: Capabilities, into b: inout ByteBuffer) {
        b.writeInteger(caps.rawValue, endianness: .little)
        b.writeInteger(UInt32(16 * 1024 * 1024), endianness: .little)
        b.writeInteger(UInt8(45))
        b.writeRepeatingByte(0, count: 23)
    }

    private static func authResponse(_ plugin: String, _ password: String, nonce: [UInt8], secure: Bool) throws -> [UInt8] {
        switch plugin {
        case "mysql_native_password":
            return MySQLAuth.nativePassword(password, nonce: nonce)
        case "caching_sha2_password":
            return MySQLAuth.cachingSHA2(password, nonce: nonce)
        case "sha256_password":
            if password.isEmpty { return [0] }
            return secure ? Array(password.utf8) + [0] : [0x01] // 0x01 asks for the public key
        case "mysql_clear_password":
            guard secure else {
                throw DatabaseError("The server wants the password in clear text, which is refused without TLS.")
            }
            return Array(password.utf8) + [0]
        default:
            throw DatabaseError("The server asks for the \(plugin) authentication plugin, which isn't supported.")
        }
    }

    private static func authenticate(
        _ io: PacketChannel, _ c: MySQLConfiguration, plugin: String, nonce: [UInt8], secure: Bool
    ) async throws {
        var plugin = plugin
        var nonce = nonce
        while true {
            var p = try await io.read()
            switch p.firstByte {
            case 0x00:
                return
            case 0xFF:
                throw serverError(p, sql: nil)
            case 0xFE: // AuthSwitchRequest
                p.moveReaderIndex(forwardBy: 1)
                guard let name = p.readCString() else {
                    throw DatabaseError("The server asks for pre-4.1 password authentication, which isn't supported.")
                }
                var data = p.readBytes(length: p.readableBytes) ?? []
                if data.last == 0 { data.removeLast() }
                plugin = name
                nonce = data
                try await io.send(io.buffer(try authResponse(plugin, c.password, nonce: nonce, secure: secure)))
            case 0x01: // AuthMoreData
                p.moveReaderIndex(forwardBy: 1)
                let data = p.readBytes(length: p.readableBytes) ?? []
                if plugin == "caching_sha2_password", data == [0x03] {
                    continue // fast authentication worked; OK follows
                }
                if plugin == "caching_sha2_password", data == [0x04] {
                    // Full authentication: the password itself, protected by TLS or RSA.
                    try await io.send(io.buffer(secure ? Array(c.password.utf8) + [0] : [0x02]))
                    continue
                }
                guard data.starts(with: Array("-----".utf8)) else {
                    throw WireError.protocolViolation("authentication data")
                }
                let pem = String(decoding: data, as: UTF8.self)
                try await io.send(io.buffer(try MySQLAuth.rsaEncryptedPassword(c.password, nonce: nonce, publicKeyPEM: pem)))
            default:
                throw WireError.protocolViolation("authentication reply")
            }
        }
    }

    // MARK: - Statements

    func ping() async throws {
        try await send(SQLStatement("SELECT 1"), batchSize: 1, cancel: CancelSignal()) { _ in }
    }

    func run(
        _ statement: SQLStatement, batchSize: Int, cancel: CancelSignal,
        onBatch: @Sendable (ResultBatch) -> Void
    ) async throws {
        guard let log, log.isObserved else {
            return try await send(statement, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
        }
        let counter = RowCounter()
        try await log.timing(statement, rows: { counter.value }) {
            try await send(statement, batchSize: batchSize, cancel: cancel) { batch in
                counter.add(batch)
                onBatch(batch)
            }
        }
    }

    private func send(
        _ statement: SQLStatement, batchSize: Int, cancel: CancelSignal,
        onBatch: @Sendable (ResultBatch) -> Void
    ) async throws {
        if cancel.isCancelled { throw CancellationError() }
        let killer = QueryKiller(configuration: configuration, connectionID: connectionID)
        cancel.whenCancelled { killer.start() }
        do {
            if statement.bindings.isEmpty {
                try await runText(statement.sql, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
            } else {
                try await runPrepared(statement, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
            }
        } catch {
            cancel.clearHandler()
            if !inSync { io.wire.close() }
            await killer.finish()
            if cancel.isCancelled { throw CancellationError() }
            throw error
        }
        cancel.clearHandler()
        await killer.finish()
        if cancel.isCancelled { throw CancellationError() }
    }

    private func runText(
        _ sql: String, batchSize: Int, cancel: CancelSignal, onBatch: @Sendable (ResultBatch) -> Void
    ) async throws {
        inSync = false
        var b = io.wire.makeBuffer(capacity: sql.utf8.count + 1)
        b.writeInteger(UInt8(0x03)) // COM_QUERY
        b.writeString(sql)
        try await io.command(b)
        try await readResults(sql: sql, binary: false, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
        inSync = true
    }

    private func runPrepared(
        _ statement: SQLStatement, batchSize: Int, cancel: CancelSignal, onBatch: @Sendable (ResultBatch) -> Void
    ) async throws {
        let sql = statement.sql
        inSync = false
        var b = io.wire.makeBuffer(capacity: sql.utf8.count + 1)
        b.writeInteger(UInt8(0x16)) // COM_STMT_PREPARE
        b.writeString(sql)
        try await io.command(b)
        var p = try await io.read()
        if p.firstByte == 0xFF {
            inSync = true
            throw serverError(p, sql: sql)
        }
        guard p.readInteger(as: UInt8.self) == 0, let id = p.readInteger(endianness: .little, as: UInt32.self),
              let columnCount = p.readInteger(endianness: .little, as: UInt16.self),
              let paramCount = p.readInteger(endianness: .little, as: UInt16.self)
        else { throw WireError.protocolViolation("prepare reply") }
        for _ in 0..<paramCount { _ = try await io.read() }
        if paramCount > 0, !capabilities.contains(.deprecateEOF) { _ = try await io.read() }
        for _ in 0..<columnCount { _ = try await io.read() }
        if columnCount > 0, !capabilities.contains(.deprecateEOF) { _ = try await io.read() }
        inSync = true

        guard Int(paramCount) == statement.bindings.count else {
            await closeStatement(id)
            throw DatabaseError(
                "statement has \(paramCount) parameters but \(statement.bindings.count) values were given", sql: sql)
        }
        inSync = false
        var e = io.wire.makeBuffer(capacity: 64)
        e.writeInteger(UInt8(0x17)) // COM_STMT_EXECUTE
        e.writeInteger(id, endianness: .little)
        e.writeInteger(UInt8(0)) // no cursor
        e.writeInteger(UInt32(1), endianness: .little)
        if paramCount > 0 { ParameterEncoding.write(statement.bindings, into: &e) }
        do {
            try await io.command(e)
            try await readResults(sql: sql, binary: true, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
        } catch {
            if inSync { await closeStatement(id) }
            throw error
        }
        inSync = true
        await closeStatement(id)
    }

    private func closeStatement(_ id: UInt32) async {
        var b = io.wire.makeBuffer(capacity: 5)
        b.writeInteger(UInt8(0x19)) // COM_STMT_CLOSE, no reply
        b.writeInteger(id, endianness: .little)
        try? await io.command(b)
    }

    /// Reads every result of the command; only the first is handed over.
    private func readResults(
        sql: String, binary: Bool, batchSize: Int, cancel: CancelSignal, onBatch: @Sendable (ResultBatch) -> Void
    ) async throws {
        var emit = true
        while true {
            let status = try await readResult(
                sql: sql, binary: binary, emit: emit, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
            emit = false
            if status & ServerStatus.moreResultsExist == 0 { return }
        }
    }

    /// Reads one result (OK, or a result set) and returns the server status flags after it.
    private func readResult(
        sql: String, binary: Bool, emit: Bool, batchSize: Int, cancel: CancelSignal,
        onBatch: @Sendable (ResultBatch) -> Void
    ) async throws -> UInt16 {
        let first = try await io.read()
        switch first.firstByte {
        case 0x00:
            guard let ok = OKPacket(first) else { throw WireError.protocolViolation("OK packet") }
            if emit, !cancel.isCancelled {
                onBatch(ResultBatch(columns: [], rows: [], rowsAffected: Int(ok.affectedRows)))
            }
            return ok.status
        case 0xFF:
            inSync = true
            throw serverError(first, sql: sql)
        case 0xFB:
            // LOCAL INFILE request: refused by sending no data; the server answers with OK or ERR.
            try await io.send(io.buffer([]))
            return try await readResult(
                sql: sql, binary: binary, emit: emit, batchSize: batchSize, cancel: cancel, onBatch: onBatch)
        default:
            break
        }
        var header = first
        guard let count = header.readLengthEncodedInteger() else { throw WireError.protocolViolation("column count") }
        var columns: [ColumnDefinition] = []
        columns.reserveCapacity(Int(count))
        for _ in 0..<count { columns.append(try ColumnDefinition(try await io.read())) }
        let deprecateEOF = capabilities.contains(.deprecateEOF)
        if !deprecateEOF { _ = try await io.read() }
        let resultColumns = columns.map(\.resultColumn)

        var rows: [[DBValue]] = []
        rows.reserveCapacity(min(batchSize, 4096))
        while true {
            let packet = try await io.read()
            let lead = packet.firstByte
            if lead == 0xFE, deprecateEOF ? packet.readableBytes < maxPacketPayload : packet.readableBytes < 9 {
                let status = deprecateEOF ? (OKPacket(packet)?.status ?? 0) : eofStatus(packet)
                if emit, !cancel.isCancelled { onBatch(ResultBatch(columns: resultColumns, rows: rows)) }
                return status
            }
            if lead == 0xFF {
                inSync = true
                throw serverError(packet, sql: sql)
            }
            guard emit, !cancel.isCancelled else { continue }
            rows.append(binary ? try ValueDecoding.binaryRow(packet, columns: columns)
                               : try ValueDecoding.textRow(packet, columns: columns))
            if rows.count >= batchSize {
                onBatch(ResultBatch(columns: resultColumns, rows: rows))
                rows = []
                rows.reserveCapacity(min(batchSize, 4096))
            }
        }
    }

    /// Runs a statement to the end and returns everything.
    func collect(_ statement: SQLStatement) async throws -> QueryResult {
        let box = ResultBox()
        try await run(statement, batchSize: 10_000, cancel: CancelSignal()) { box.add($0) }
        return box.result
    }

    func transaction(
        _ statements: [SQLStatement], dialect: any Dialect, verify: @Sendable (Int, Int) throws -> Void
    ) async throws -> [Int] {
        _ = try await collect(SQLStatement(dialect.beginTransaction))
        do {
            var counts: [Int] = []
            for (i, statement) in statements.enumerated() {
                let n = try await collect(statement).rowsAffected ?? 0
                try verify(i, n)
                counts.append(n)
            }
            _ = try await collect(SQLStatement(dialect.commitTransaction))
            return counts
        } catch {
            if isAlive { _ = try? await collect(SQLStatement(dialect.rollbackTransaction)) }
            throw error
        }
    }

    /// Stops whatever `id` is running, from a separate session (what `KILL QUERY` needs).
    static func killQuery(_ configuration: MySQLConfiguration, id: UInt32) async {
        var c = configuration
        c.readOnly = false
        guard let session = try? await open(c) else { return }
        _ = try? await session.collect(SQLStatement("KILL QUERY \(id)"))
        await session.close()
    }
}

/// Sends `KILL QUERY` at most once, and lets the session wait for it before running anything
/// else, so a late kill can't stop the next statement.
private final class QueryKiller: @unchecked Sendable {
    private let configuration: MySQLConfiguration
    private let connectionID: UInt32
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var finished = false

    init(configuration: MySQLConfiguration, connectionID: UInt32) {
        self.configuration = configuration
        self.connectionID = connectionID
    }

    func start() {
        lock.withLock {
            guard !finished, task == nil else { return }
            let c = configuration
            let id = connectionID
            task = Task { await MySQLSession.killQuery(c, id: id) }
        }
    }

    func finish() async {
        let t = lock.withLock {
            finished = true
            return task
        }
        await t?.value
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = QueryResult()

    func add(_ batch: ResultBatch) {
        lock.withLock {
            value.columns = batch.columns
            value.rows += batch.rows
            value.rowsAffected = batch.rowsAffected ?? value.rowsAffected
        }
    }

    var result: QueryResult { lock.withLock { value } }
}
