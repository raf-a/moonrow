import DBKit
import Foundation
import NIOCore
import WireSupport

public struct PostgresConfiguration: Sendable, Hashable {
    public var endpoint: Endpoint
    public var user: String
    public var password: String?
    /// Defaults to the user name on the server side.
    public var database: String?
    public var tls: TLSSettings
    /// Start TLS right away instead of asking first (`sslnegotiation=direct`, Postgres 17+).
    /// Only used when the mode requires TLS.
    public var directTLS: Bool
    /// Sessions start with `default_transaction_read_only`.
    public var readOnly: Bool
    public var applicationName: String
    /// Seconds.
    public var connectTimeout: Int64

    public init(
        endpoint: Endpoint, user: String, password: String? = nil, database: String? = nil,
        tls: TLSSettings = TLSSettings(), directTLS: Bool = false, readOnly: Bool = false,
        applicationName: String = "Moonrow", connectTimeout: Int64 = 15
    ) {
        self.endpoint = endpoint
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
        self.directTLS = directTLS
        self.readOnly = readOnly
        self.applicationName = applicationName
        self.connectTimeout = connectTimeout
    }
}

/// One authenticated backend: the extended query protocol over a `WireChannel`.
final class PGSession: WireSession, @unchecked Sendable {
    let wire: WireChannel
    let configuration: PostgresConfiguration
    private(set) var processID: Int32 = 0
    private(set) var secretKey: [UInt8] = []
    private(set) var parameters: [String: String] = [:]
    /// From the last ReadyForQuery: `I` idle, `T` in a transaction, `E` in a failed one.
    private(set) var transactionStatus = UInt8(ascii: "I")
    private var isBroken = false
    private let cancelLock = NSLock()
    private var acceptsCancel = false
    private var cancelTask: Task<Void, Never>?
    /// The connection's query log.
    var log: StatementLog?

    private init(wire: WireChannel, configuration: PostgresConfiguration) {
        self.wire = wire
        self.configuration = configuration
    }

    var isAlive: Bool { !isBroken && wire.isActive }

    // MARK: - Connecting

    static func open(_ c: PostgresConfiguration, log: StatementLog?) async throws -> PGSession {
        let session = try await open(c)
        session.log = log
        return session
    }

    static func open(_ c: PostgresConfiguration) async throws -> PGSession {
        switch c.tls.mode {
        case .disable:
            return try await open(c, tls: false)
        case .allow:
            do {
                return try await open(c, tls: false)
            } catch let e as DatabaseError where e.state == "28000" {
                // pg_hba rejected a plain connection; try again with TLS.
                return try await open(c, tls: true)
            }
        default:
            return try await open(c, tls: true)
        }
    }

    private static func open(_ c: PostgresConfiguration, tls: Bool) async throws -> PGSession {
        let wire = try await negotiate(c, tls: tls)
        let session = PGSession(wire: wire, configuration: c)
        do {
            try await session.startup()
        } catch {
            wire.close()
            throw error
        }
        return session
    }

    /// A socket ready for its first message: TLS set up as the mode asks.
    static func negotiate(_ c: PostgresConfiguration, tls: Bool) async throws -> WireChannel {
        let timeout = TimeAmount.seconds(c.connectTimeout)
        if tls, c.directTLS, c.tls.mode != .prefer, c.tls.mode != .allow {
            let wire = try await WireChannel.connect(to: c.endpoint, framer: PGFramer(), timeout: timeout)
            try await wire.startTLS(c.tls, alpn: ["postgresql"])
            return wire
        }
        guard tls, !isUnixSocket(c.endpoint) else {
            return try await WireChannel.connect(to: c.endpoint, framer: PGFramer(), timeout: timeout)
        }
        let wire = try await WireChannel.connect(to: c.endpoint, framer: RawFramer(), timeout: timeout)
        do {
            var request = wire.makeBuffer(capacity: 8)
            PGFrontend.sslRequest(into: &request)
            try await wire.send(request)
            var reply = try await wire.next()
            // Anything after the one-byte answer would have been sent before encryption.
            guard reply.readableBytes == 1, let answer: UInt8 = reply.readInteger() else {
                throw DatabaseError("The server sent unexpected data in reply to the TLS request.")
            }
            try await wire.setFramer(PGFramer())
            switch answer {
            case UInt8(ascii: "S"):
                try await wire.startTLS(c.tls)
            case UInt8(ascii: "N"):
                guard c.tls.mode == .prefer || c.tls.mode == .allow else {
                    throw DatabaseError("The server doesn't support TLS, and the connection requires it (\(c.tls.mode.rawValue)).")
                }
            default:
                throw DatabaseError("The server rejected the TLS request.")
            }
        } catch {
            wire.close()
            throw error
        }
        return wire
    }

    private static func isUnixSocket(_ endpoint: Endpoint) -> Bool {
        if case .unixSocket = endpoint { return true }
        return false
    }

    private func startup() async throws {
        let c = configuration
        var params: [(String, String)] = [("user", c.user)]
        if let db = c.database, !db.isEmpty { params.append(("database", db)) }
        params += [
            ("application_name", c.applicationName),
            ("client_encoding", "UTF8"),
            ("DateStyle", "ISO, MDY"),
            ("bytea_output", "hex"),
        ]
        if c.readOnly { params.append(("default_transaction_read_only", "on")) }
        var buffer = wire.makeBuffer()
        PGFrontend.startup(params, into: &buffer)
        try await wire.send(buffer)

        var scram: SCRAMClient?
        while true {
            let message = PGMessage(frame: try await wire.next())
            var body = message.body
            switch message.kind {
            case "R":
                let code: Int32 = body.readInteger() ?? -1
                switch code {
                case 0:
                    break
                case 3:
                    try await sendPassword(Array(try requirePassword().utf8) + [0])
                case 5:
                    let salt = body.readBytes(length: 4) ?? []
                    try await sendPassword(PGAuth.md5Response(user: c.user, password: try requirePassword(), salt: salt))
                case 10:
                    var mechanisms: [String] = []
                    while let m = body.readCString(), !m.isEmpty { mechanisms.append(m) }
                    guard mechanisms.contains(SCRAMClient.mechanism) else {
                        throw DatabaseError("The server asks for \(mechanisms.joined(separator: ", ")), which isn't supported.")
                    }
                    var client = SCRAMClient(password: try requirePassword())
                    var out = wire.makeBuffer()
                    PGFrontend.saslInitial(mechanism: SCRAMClient.mechanism, Array(client.clientFirst().utf8), into: &out)
                    try await wire.send(out)
                    scram = client
                case 11:
                    guard var client = scram else { throw WireError.protocolViolation("SASL continue") }
                    let final = try client.clientFinal(serverFirst: body.readRemainingString())
                    scram = client
                    try await sendPassword(Array(final.utf8))
                case 12:
                    try scram?.verify(serverFinal: body.readRemainingString())
                default:
                    throw DatabaseError("The server asks for an authentication method that isn't supported (code \(code)).")
                }
            case "K":
                processID = body.readInteger() ?? 0
                secretKey = body.readBytes(length: body.readableBytes) ?? []
            case "S":
                if let k = body.readCString(), let v = body.readCString() { parameters[k] = v }
            case "E":
                throw PGNotice(body).error(sql: nil)
            case "Z":
                transactionStatus = body.readInteger() ?? transactionStatus
                return
            default:
                continue   // notices, NegotiateProtocolVersion
            }
        }
    }

    private func requirePassword() throws -> String {
        guard let p = configuration.password else {
            throw DatabaseError("The server asks for a password, and none was given.", state: "28P01")
        }
        return p
    }

    private func sendPassword(_ bytes: [UInt8]) async throws {
        var out = wire.makeBuffer(capacity: bytes.count + 8)
        PGFrontend.password(bytes, into: &out)
        try await wire.send(out)
    }

    func close() async {
        if wire.isActive {
            var out = wire.makeBuffer(capacity: 8)
            PGFrontend.terminate(into: &out)
            try? await wire.send(out)
        }
        wire.close()
    }

    // MARK: - Statements

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
        var out = wire.makeBuffer(capacity: statement.sql.utf8.count + 64)
        PGFrontend.extendedQuery(statement.sql, parameters: statement.bindings.map(PGType.encode), into: &out)
        do {
            try await wire.send(out)
        } catch {
            isBroken = true
            throw error
        }
        cancelLock.withLock { acceptsCancel = true }
        cancel.whenCancelled { [weak self] in self?.requestCancel() }
        defer { cancel.clearHandler() }

        var columns: [ResultColumn] = []
        var types: [UInt32] = []
        var rows: [[DBValue]] = []
        var returnsRows = false
        var affected: Int?
        var failure: DatabaseError?
        do {
            loop: while true {
                let message = PGMessage(frame: try await wire.next())
                var body = message.body
                switch message.kind {
                case "D":
                    guard failure == nil, !cancel.isCancelled else { continue }
                    rows.append(Self.decodeRow(&body, types: types))
                    if rows.count >= batchSize {
                        onBatch(ResultBatch(columns: columns, rows: rows))
                        rows.removeAll(keepingCapacity: true)
                    }
                case "T":
                    (columns, types) = Self.decodeRowDescription(&body)
                    returnsRows = true
                case "C":
                    let tag = body.readCString() ?? ""
                    affected = returnsRows ? nil : Self.rowCount(tag)
                case "I":
                    affected = 0
                case "E":
                    if failure == nil { failure = PGNotice(body).error(sql: statement.sql) }
                case "G":
                    var fail = wire.makeBuffer()
                    PGFrontend.copyFail("COPY FROM STDIN isn't supported here.", into: &fail)
                    // The Sync sent with the statement was ignored in copy-in mode.
                    PGFrontend.message("S", into: &fail) { _ in }
                    try await wire.send(fail)
                case "H":
                    columns = [ResultColumn(name: "COPY", typeName: "text")]
                    types = [25]
                    returnsRows = true
                case "d":
                    guard failure == nil, !cancel.isCancelled else { continue }
                    var line = body.readRemainingString()
                    if line.hasSuffix("\n") { line.removeLast() }
                    rows.append([.text(line)])
                case "S":
                    if let k = body.readCString(), let v = body.readCString() { parameters[k] = v }
                case "Z":
                    transactionStatus = body.readInteger() ?? transactionStatus
                    break loop
                default:
                    continue   // ParseComplete, BindComplete, NoData, CopyDone, notices, notifications
                }
            }
        } catch {
            isBroken = true
            await waitForCancelRequest()
            throw error
        }
        await waitForCancelRequest()
        if let failure {
            if cancel.isCancelled, failure.isQueryCanceled { throw CancellationError() }
            throw failure
        }
        if cancel.isCancelled { throw CancellationError() }
        onBatch(ResultBatch(columns: columns, rows: rows, rowsAffected: affected))
    }

    /// `COPY … FROM STDIN` with the simple query protocol: the server asks for data
    /// (CopyInResponse), gets `source`'s pieces as CopyData and then CopyDone, or CopyFail when
    /// the source fails or the task is cancelled.
    func copyIn(_ sql: String, from source: CopySource) async throws -> Int {
        let statement = SQLStatement(sql)
        guard let log, log.isObserved else { return try await sendCopy(sql, from: source) }
        return try await log.timing(statement, rows: { $0 }) { try await sendCopy(sql, from: source) }
    }

    private func sendCopy(_ sql: String, from source: CopySource) async throws -> Int {
        var out = wire.makeBuffer(capacity: sql.utf8.count + 8)
        PGFrontend.simpleQuery(sql, into: &out)
        var affected = 0
        var failure: DatabaseError?
        var stopped: (any Error)?
        do {
            try await wire.send(out)
            loop: while true {
                let message = PGMessage(frame: try await wire.next())
                var body = message.body
                switch message.kind {
                case "G":
                    do {
                        while let piece = try await source() {
                            try Task.checkCancellation()
                            if piece.isEmpty { continue }
                            var data = wire.makeBuffer(capacity: piece.count + 8)
                            PGFrontend.message("d", into: &data) { $0.writeBytes(piece) }
                            try await wire.send(data)
                        }
                        var done = wire.makeBuffer(capacity: 8)
                        PGFrontend.message("c", into: &done) { _ in }
                        try await wire.send(done)
                    } catch {
                        stopped = error
                        var fail = wire.makeBuffer()
                        PGFrontend.copyFail(error is CancellationError ? "Stopped." : "The data couldn't be read.", into: &fail)
                        try await wire.send(fail)
                    }
                case "H":
                    // COPY TO STDOUT isn't what this is for: let it run out.
                    continue
                case "C":
                    affected = Self.rowCount(body.readCString() ?? "")
                case "E":
                    if failure == nil { failure = PGNotice(body).error(sql: sql) }
                case "S":
                    if let k = body.readCString(), let v = body.readCString() { parameters[k] = v }
                case "Z":
                    transactionStatus = body.readInteger() ?? transactionStatus
                    break loop
                default:
                    continue
                }
            }
        } catch {
            isBroken = true
            throw error
        }
        if let stopped { throw stopped }
        if let failure { throw failure }
        return affected
    }

    /// Runs a statement and collects its rows (introspection, transactions).
    @discardableResult
    func query(_ sql: String, _ bindings: [DBValue] = []) async throws -> QueryResult {
        let collector = Collector()
        try await run(SQLStatement(sql, bindings: bindings), batchSize: 10_000, cancel: CancelSignal()) {
            collector.add($0)
        }
        return collector.result
    }

    static func decodeRowDescription(_ body: inout ByteBuffer) -> ([ResultColumn], [UInt32]) {
        let count = Int(body.readInteger(as: Int16.self) ?? 0)
        var columns: [ResultColumn] = []
        var types: [UInt32] = []
        for _ in 0..<count {
            let name = body.readCString() ?? "?"
            body.moveReaderIndex(forwardBy: 6)   // table oid, column number
            let type: UInt32 = body.readInteger() ?? 0
            body.moveReaderIndex(forwardBy: 8)   // size, modifier, format
            columns.append(ResultColumn(name: name, typeName: PGType.names[type]))
            types.append(type)
        }
        return (columns, types)
    }

    static func decodeRow(_ body: inout ByteBuffer, types: [UInt32]) -> [DBValue] {
        let count = Int(body.readInteger(as: Int16.self) ?? 0)
        var row: [DBValue] = []
        row.reserveCapacity(count)
        for i in 0..<count {
            let length = Int(body.readInteger(as: Int32.self) ?? -1)
            if length < 0 {
                row.append(.null)
            } else {
                row.append(PGType.decode(&body, length: length, type: i < types.count ? types[i] : 25))
            }
        }
        return row
    }

    /// `INSERT 0 5` → 5, `UPDATE 2` → 2; tags without a count (`CREATE TABLE`) → 0.
    static func rowCount(_ tag: String) -> Int {
        tag.split(separator: " ").last.flatMap { Int($0) } ?? 0
    }

    // MARK: - Cancelling

    /// Asks the server, over a second socket, to stop whatever this backend is running.
    /// Only while a statement runs, and once per statement.
    private func requestCancel() {
        let c = configuration
        let pid = processID
        let key = secretKey
        let tls = c.tls.mode != .disable && c.tls.mode != .prefer && c.tls.mode != .allow
        cancelLock.withLock {
            guard acceptsCancel, cancelTask == nil else { return }
            cancelTask = Task {
                guard let wire = try? await Self.negotiate(c, tls: tls) else { return }
                var out = wire.makeBuffer(capacity: 16 + key.count)
                PGFrontend.cancelRequest(processID: pid, secretKey: key, into: &out)
                try? await wire.send(out)
                // The server closes the socket once it has handled the request.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await wire.waitUntilClosed() }
                    group.addTask { try? await Task.sleep(for: .seconds(5)) }
                    await group.next()
                    group.cancelAll()
                }
                wire.close()
            }
        }
    }

    /// A cancel that arrives after the statement ended could hit the next one, so the
    /// statement isn't over until its cancel request is.
    private func waitForCancelRequest() async {
        let task = cancelLock.withLock { () -> Task<Void, Never>? in
            acceptsCancel = false
            defer { cancelTask = nil }
            return cancelTask
        }
        await task?.value
    }
}

final class Collector: @unchecked Sendable {
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
