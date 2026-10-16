import DBKit
import DriverSQLite
import Foundation
import NIOCore
import SQLScript
import WireSupport

/// How to reach a SQLite file on a server: a stream that runs the server's own sqlite3 on it
/// (`command(sqlite3:path:readOnly:)`, run through an SSH master), and how to interrupt it.
public struct RemoteSQLiteConfiguration: Sendable {
    /// Each stream opened is a new run of `command`.
    public var endpoint: Endpoint
    /// The file, as the server sees it (for messages).
    public var path: String
    /// Statements every new session runs first.
    public var bootstrap: [String]
    /// Sends SIGINT to the process with this id on the server: sqlite3 stops its statement.
    public var interrupt: @Sendable (Int) async -> Void

    public init(endpoint: Endpoint, path: String, bootstrap: [String] = [], interrupt: @escaping @Sendable (Int) async -> Void) {
        self.endpoint = endpoint
        self.path = path
        self.bootstrap = bootstrap
        self.interrupt = interrupt
    }

    /// The command for the server's login shell: checks the file is there and sqlite3 can be
    /// found, says its process id, then becomes sqlite3 on the file with errors on stdout. A
    /// leading `~/` is the user's home.
    public static func command(sqlite3: String, path: String, readOnly: Bool) -> String {
        let script = """
            f=$1; case $f in "~/"*) f=$HOME/${f#??};; esac; \
            [ -f "$f" ] || { echo moonrow-missing; exit 3; }; \
            command -v "$0" >/dev/null 2>&1 || { echo moonrow-no-sqlite; exit 4; }; \
            echo "moonrow-pid:$$"; exec "$0" -batch\(readOnly ? " -readonly" : "") "$f" 2>&1
            """
        return "exec sh -c " + shellQuoted(script) + " " + shellQuoted(sqlite3) + " " + shellQuoted(path)
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Why a remote SQLite file can't be opened live.
public enum RemoteSQLiteError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The server has no sqlite3 (at the path given).
    case noSQLite(String)
    /// There is no file at the path.
    case missingFile(String)

    public var description: String {
        switch self {
        case .noSQLite(let command): "The server has no \(command)."
        case .missingFile(let path): "There is no file at \(path) on the server."
        }
    }

    public var errorDescription: String? { description }
}

/// A SQLite file on a server, used through the server's own sqlite3: every statement runs
/// there on the live file, with SQLite's own locking, so other programs' writes are never
/// overwritten. One sqlite3 process per session; a dropped one is started again before the
/// next statement, as the server drivers reopen sessions.
public final class RemoteSQLiteConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect: any Dialect = SQLiteDialect()
    public let configuration: RemoteSQLiteConfiguration
    /// The server's sqlite3 version, e.g. `3.49.2`.
    public let sqliteVersion: String
    public let statementLog: StatementLog?
    private let host: SessionHost<RemoteSQLiteSession>

    private init(configuration: RemoteSQLiteConfiguration, first: RemoteSQLiteSession, log: StatementLog) {
        self.configuration = configuration
        self.sqliteVersion = first.version
        self.statementLog = log
        self.host = SessionHost(first: first) { try await RemoteSQLiteSession.open(configuration, log: log) }
    }

    public static func connect(_ configuration: RemoteSQLiteConfiguration) async throws -> RemoteSQLiteConnection {
        let log = StatementLog()
        return RemoteSQLiteConnection(configuration: configuration, first: try await RemoteSQLiteSession.open(configuration, log: log), log: log)
    }

    public func close() async { await host.close() }

    public func setKeepAlive(_ interval: Duration?) { host.setKeepAlive(interval) }

    public func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        host.stream(statement, batchSize: batchSize)
    }

    public func transaction(_ statements: [SQLStatement], verify: @Sendable (Int, Int) throws -> Void) async throws -> [Int] {
        let dialect = dialect
        return try await host.withSession { session in
            try await session.collect(SQLStatement(dialect.beginTransaction))
            do {
                var counts: [Int] = []
                for (i, statement) in statements.enumerated() {
                    let n = try await session.collect(statement).rowsAffected ?? 0
                    try verify(i, n)
                    counts.append(n)
                }
                try await session.collect(SQLStatement(dialect.commitTransaction))
                return counts
            } catch {
                if session.isAlive { _ = try? await session.collect(SQLStatement(dialect.rollbackTransaction)) }
                throw error
            }
        }
    }

    // MARK: - Introspection

    private var catalog: SQLiteCatalog { SQLiteCatalog { [self] in try await self.execute($0).rows } }

    public func schemas() async throws -> [String] { [] }
    public func currentSchema() async throws -> String? { nil }
    public func objects(schema: String?) async throws -> [DatabaseObject] { try await catalog.objects(schema: schema) }
    public func columns(of table: TableRef) async throws -> [ColumnInfo] { try await catalog.columns(of: table) }
    public func indexes(of table: TableRef) async throws -> [IndexInfo] { try await catalog.indexes(of: table) }
    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] { try await catalog.foreignKeys(of: table) }
    public func triggers(of table: TableRef) async throws -> [TriggerInfo] { try await catalog.triggers(of: table) }
    public func structure(of table: TableRef) async throws -> TableStructure { try await catalog.structure(of: table) }
    public func definition(of object: DatabaseObject) async throws -> String { try await catalog.definition(of: object) }
}

/// Lines of text, without their line feed.
struct LineFramer: Framer {
    func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard let end = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = buffer.readSlice(length: end - buffer.readerIndex)
        buffer.moveReaderIndex(forwardBy: 1)
        return line
    }
}

/// One sqlite3 process on the server, talked to as the CLI expects: SQL and dot commands in,
/// text out. Each exchange ends with a `.print` of a marker, so its output is known to be
/// complete. Queries run through a temporary view, so their columns are known even without
/// rows, and each row comes back as a JSON array of `quote()`d values, which keeps the types
/// (integer, real, text, blob, NULL) and survives line breaks in the data.
final class RemoteSQLiteSession: WireSession, @unchecked Sendable {
    let wire: WireChannel
    let processID: Int
    let version: String
    var log: StatementLog?
    private let interrupt: @Sendable (Int) async -> Void
    private let marker = "moonrow-end-" + UUID().uuidString.prefix(8).lowercased()
    /// Set once an interrupt was sent: sqlite3 leaves after it, so the session is replaced.
    private var interrupted = false
    private static let dialect = SQLiteDialect()

    private init(wire: WireChannel, processID: Int, version: String, interrupt: @escaping @Sendable (Int) async -> Void) {
        self.wire = wire
        self.processID = processID
        self.version = version
        self.interrupt = interrupt
    }

    var isAlive: Bool { wire.isActive && !interrupted }

    static func open(_ c: RemoteSQLiteConfiguration, log: StatementLog?) async throws -> RemoteSQLiteSession {
        let wire = try await WireChannel.connect(to: c.endpoint, framer: LineFramer())
        do {
            let first = try await line(wire, startingSQLite: c)
            guard first.hasPrefix("moonrow-pid:"), let pid = Int(first.dropFirst("moonrow-pid:".count)) else {
                throw DatabaseError("The server answered “\(first)” instead of starting sqlite3.")
            }
            let session = RemoteSQLiteSession(wire: wire, processID: pid, version: "", interrupt: c.interrupt)
            let lines = try await session.exchange("""
                .timeout 5000
                .headers off
                .mode list
                SELECT 'moonrow-version:' || sqlite_version() || ':' || json_valid('[1]');
                """)
            if let error = Self.error(in: lines) {
                throw DatabaseError("The server's sqlite3 can't be used (\(error.message)). Moonrow needs sqlite3 3.38 or later, or one built with JSON support.")
            }
            guard let v = lines.first(where: { $0.hasPrefix("moonrow-version:") })?.split(separator: ":"), v.count >= 2 else {
                throw DatabaseError("The server's sqlite3 didn't say its version.")
            }
            let ready = RemoteSQLiteSession(wire: wire, processID: pid, version: String(v[1]), interrupt: c.interrupt)
            ready.log = log
            for sql in c.bootstrap {
                do {
                    try await ready.collect(SQLStatement(sql))
                } catch {
                    await ready.close()
                    throw DatabaseError.bootstrap(error, sql: sql)
                }
            }
            return ready
        } catch {
            wire.close()
            throw error
        }
    }

    /// The launcher's first line; a stream that ends first is the shell's or ssh's error.
    private static func line(_ wire: WireChannel, startingSQLite c: RemoteSQLiteConfiguration) async throws -> String {
        let buffer: ByteBuffer
        do {
            buffer = try await wire.next()
        } catch {
            throw DatabaseError("Couldn't start sqlite3 on the server: \((error as? DatabaseError)?.message ?? "\(error)")")
        }
        let text = String(buffer: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "moonrow-missing": throw RemoteSQLiteError.missingFile(c.path)
        case "moonrow-no-sqlite": throw RemoteSQLiteError.noSQLite("sqlite3")
        default: return text
        }
    }

    func close() async {
        if wire.isActive {
            var b = wire.makeBuffer()
            b.writeString(".quit\n")
            try? await wire.send(b)
        }
        wire.close()
    }

    func ping() async throws {
        _ = try await exchange("SELECT 1;")
    }

    // MARK: - Statements

    func run(_ statement: SQLStatement, batchSize: Int, cancel: CancelSignal, onBatch: @Sendable (ResultBatch) -> Void) async throws {
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

    /// Runs a statement to the end and returns everything.
    @discardableResult
    func collect(_ statement: SQLStatement) async throws -> QueryResult {
        let box = Collected()
        try await send(statement, batchSize: 10_000, cancel: CancelSignal()) { box.add($0) }
        return box.result
    }

    private func send(_ statement: SQLStatement, batchSize: Int, cancel: CancelSignal, onBatch: (ResultBatch) -> Void) async throws {
        let sql = try Self.inlined(statement)
        cancel.whenCancelled { [weak self] in
            guard let self else { return }
            self.interrupted = true
            let pid = self.processID, interrupt = self.interrupt
            Task { await interrupt(pid) }
        }
        defer { cancel.clearHandler() }
        do {
            if Self.isQuery(sql) {
                try await query(sql, batchSize: batchSize, onBatch: onBatch)
            } else {
                try await other(sql, batchSize: batchSize, onBatch: onBatch)
            }
        } catch {
            if cancel.isCancelled { throw CancellationError() }
            throw error
        }
        if cancel.isCancelled { throw CancellationError() }
    }

    /// A SELECT, WITH or VALUES that only reads: through a temporary view.
    private func query(_ sql: String, batchSize: Int, onBatch: (ResultBatch) -> Void) async throws {
        let head = try await exchange("""
            DROP VIEW IF EXISTS temp.moonrow_q;
            CREATE TEMP VIEW moonrow_q AS \(sql)
            ;
            SELECT json_group_array(name) FROM pragma_table_info('moonrow_q', 'temp');
            """)
        if let error = Self.error(in: head) { throw error.with(sql: sql) }
        guard let json = head.last, let names = try? JSONDecoder().decode([String].self, from: Data(json.utf8)), !names.isEmpty else {
            throw DatabaseError("sqlite3 didn't list the result's columns.", sql: sql)
        }
        let columns = names.map { ResultColumn(name: $0) }
        // json_array takes a limited number of arguments: wide rows come as several arrays.
        let groups = stride(from: 0, to: names.count, by: 100).map { start in
            "json_array(" + names[start..<min(start + 100, names.count)]
                .map { "quote(\(Self.dialect.quoteIdentifier($0)))" }.joined(separator: ", ") + ")"
        }
        var rows: [[DBValue]] = []
        var sentColumns = false
        var failure: DatabaseError?
        try await exchange("SELECT \(groups.joined(separator: " || char(9) || ")) FROM temp.moonrow_q;\nDROP VIEW temp.moonrow_q;") { line in
            if failure != nil { return }
            if line.hasPrefix("[") {
                rows.append(Self.row(line))
                if rows.count >= batchSize {
                    onBatch(ResultBatch(columns: columns, rows: rows))
                    sentColumns = true
                    rows = []
                }
            } else if let e = Self.error(in: [line]) {
                failure = e
            }
        }
        if let failure { throw failure.with(sql: sql) }
        if !rows.isEmpty || !sentColumns { onBatch(ResultBatch(columns: columns, rows: rows)) }
    }

    /// Anything else: run as typed. Rows it returns (PRAGMA, EXPLAIN, RETURNING) come in the
    /// CLI's quote mode with a header; then `changes()` for the rows it changed.
    private func other(_ sql: String, batchSize: Int, onBatch: (ResultBatch) -> Void) async throws {
        var lines: [String] = []
        var pending: String?
        var failure: DatabaseError?
        var changes: Int?
        try await exchange("""
            .mode quote
            .headers on
            \(sql)
            ;
            .mode list
            .headers off
            SELECT 'moonrow-changes:' || changes();
            """) { line in
            if let p = pending {
                // A quoted value with line breaks goes on until its quotes balance.
                let joined = p + "\n" + line
                if Self.quotesBalance(joined) { lines.append(joined); pending = nil } else { pending = joined }
                return
            }
            if line.hasPrefix("moonrow-changes:") {
                changes = Int(line.dropFirst("moonrow-changes:".count))
            } else if failure == nil, let e = Self.error(in: [line]) {
                failure = e
            } else if failure == nil {
                if Self.quotesBalance(line) { lines.append(line) } else { pending = line }
            }
        }
        if let failure { throw failure.with(sql: sql) }
        let writes = Self.changesRows(sql)
        guard let header = lines.first else {
            onBatch(ResultBatch(columns: [], rows: [], rowsAffected: writes ? changes ?? 0 : 0))
            return
        }
        let columns = Self.literals(header).map { ResultColumn(name: $0.displayString) }
        var rows: [[DBValue]] = []
        for line in lines.dropFirst() {
            rows.append(Self.literals(line))
            if rows.count >= batchSize {
                onBatch(ResultBatch(columns: columns, rows: rows))
                rows = []
            }
        }
        onBatch(ResultBatch(columns: columns, rows: rows, rowsAffected: writes ? changes : nil))
    }

    /// Sends `script` and returns its output, up to the marker.
    @discardableResult
    private func exchange(_ script: String) async throws -> [String] {
        var lines: [String] = []
        try await exchange(script) { lines.append($0) }
        return lines
    }

    /// Sends `script` and a marker, and hands each line of output to `onLine` until the marker.
    private func exchange(_ script: String, onLine: (String) -> Void) async throws {
        var b = wire.makeBuffer(capacity: script.utf8.count + 64)
        b.writeString(script + "\n.print " + marker + "\n")
        try await wire.send(b)
        while true {
            let line = String(buffer: try await wire.next())
            if line == marker { return }
            onLine(line)
        }
    }

    // MARK: - Text

    /// The CLI's error lines: "Parse error near line 3: no such table: x", "Runtime error near
    /// line 3: … (19)", "Error near line 3: …", "Error: …". Lines after one, indented, show where.
    static func error(in lines: [String]) -> DatabaseError? {
        for line in lines {
            for prefix in ["Parse error", "Runtime error", "Error"] where line.hasPrefix(prefix) {
                guard let colon = line.range(of: ": ") else { continue }
                var message = String(line[colon.upperBound...])
                var code: Int?
                // "(19)" at the end is the extended result code.
                if message.hasSuffix(")"), let open = message.lastIndex(of: "("),
                   let n = Int(message[message.index(after: open)..<message.index(before: message.endIndex)]) {
                    code = n
                    message = String(message[..<open]).trimmingCharacters(in: .whitespaces)
                }
                return DatabaseError(message, code: code)
            }
        }
        return nil
    }

    /// One row: JSON arrays of quoted values, tab-separated when the row was split.
    static func row(_ line: String) -> [DBValue] {
        line.split(separator: "\t").flatMap { part -> [DBValue] in
            let values = (try? JSONDecoder().decode([String].self, from: Data(part.utf8))) ?? []
            return values.map(value(quoted:))
        }
    }

    /// A value as `quote()` writes it: NULL, a number, 'text' with '' for ', or X'hex'.
    static func value(quoted s: String) -> DBValue {
        if s == "NULL" { return .null }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return .text(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        if s.hasPrefix("X'") || s.hasPrefix("x'"), s.hasSuffix("'") {
            let hex = Array(s.dropFirst(2).dropLast().utf8)
            var data = Data(capacity: hex.count / 2)
            var i = 0
            while i + 1 < hex.count, let byte = UInt8(String(decoding: hex[i...i + 1], as: UTF8.self), radix: 16) {
                data.append(byte)
                i += 2
            }
            return .blob(data)
        }
        if let n = Int64(s) { return .integer(n) }
        if let d = Double(s) { return .double(d) }
        return .text(s)
    }

    /// A line of quote mode's output: values separated by commas.
    static func literals(_ line: String) -> [DBValue] {
        var values: [DBValue] = []
        var current = ""
        var inQuote = false
        for ch in line {
            if ch == "'" { inQuote.toggle() }
            if ch == ",", !inQuote {
                values.append(value(quoted: current))
                current = ""
            } else {
                current.append(ch)
            }
        }
        values.append(value(quoted: current))
        return values
    }

    static func quotesBalance(_ text: String) -> Bool {
        text.reduce(0) { $1 == "'" ? $0 + 1 : $0 } % 2 == 0
    }

    /// Bound values written into the statement, as the CLI has no way to bind them.
    static func inlined(_ statement: SQLStatement) throws -> String {
        var sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while sql.hasSuffix(";") { sql = String(sql.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !statement.bindings.isEmpty else { return sql }
        let lexer = SQLLexer(sql, dialect: .sqlite)
        let placeholders = lexer.tokens().filter { $0.kind == .parameter }
        guard placeholders.count == statement.bindings.count else {
            throw DatabaseError("The statement has \(placeholders.count) placeholders for \(statement.bindings.count) values.", sql: sql)
        }
        var units = lexer.units
        for (token, value) in zip(placeholders, statement.bindings).reversed() {
            units.replaceSubrange(token.range, with: Array(dialect.literal(value).utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Whether the statement is a query that a view can hold.
    static func isQuery(_ sql: String) -> Bool {
        guard let first = firstWord(sql), ["SELECT", "WITH", "VALUES"].contains(first) else { return false }
        return SQLClassifier.kind(of: sql, dialect: .sqlite) == .read
    }

    /// Whether `changes()` counts the statement's rows.
    static func changesRows(_ sql: String) -> Bool {
        guard let first = firstWord(sql) else { return false }
        return ["INSERT", "UPDATE", "DELETE", "REPLACE", "WITH"].contains(first)
    }

    private static func firstWord(_ sql: String) -> String? {
        let lexer = SQLLexer(sql, dialect: .sqlite)
        return lexer.tokens().first { !$0.kind.isTrivia }.map { lexer.text($0.range).uppercased() }
    }
}

private extension DatabaseError {
    func with(sql: String) -> DatabaseError {
        var e = self
        e.sql = sql
        return e
    }
}

/// Batches gathered into one result.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var columns: [ResultColumn] = []
    private var rows: [[DBValue]] = []
    private var affected: Int?

    func add(_ batch: ResultBatch) {
        lock.withLock {
            if columns.isEmpty { columns = batch.columns }
            rows += batch.rows
            affected = batch.rowsAffected ?? affected
        }
    }

    var result: QueryResult { lock.withLock { QueryResult(columns: columns, rows: rows, rowsAffected: affected) } }
}
