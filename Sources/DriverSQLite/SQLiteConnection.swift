import DBKit
import Foundation
import SQLScript
import SQLite3

/// A connection to a SQLite file (or `:memory:`). All work is serialized by the actor.
public actor SQLiteConnection: DatabaseConnection {
    public nonisolated let dialect: any Dialect = SQLiteDialect()
    public nonisolated let path: String

    /// SQLite calls block (a long step, a busy timeout), so the actor runs on a queue of its
    /// own rather than holding one of Swift's few concurrency threads while they do. Otherwise
    /// a handful of slow statements can take every thread, including the ones that would
    /// cancel them.
    private let queue = DispatchSerialQueue(label: "moonrow.sqlite")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let db: Handle<OpaquePointer>
    private var cursors: [Int: Cursor] = [:]
    private var nextCursorID = 0
    private var isClosed = false
    private var trace: Trace?
    public nonisolated let statementLog: StatementLog? = StatementLog()

    public init(path: String, readOnly: Bool = false) throws {
        var raw: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        guard rc == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(raw)
            throw DatabaseError(message, code: Int(rc))
        }
        sqlite3_extended_result_codes(raw, 1)
        // Another connection to the file (an import's session, another app) may hold a write
        // lock for a moment; wait for it rather than failing at once.
        sqlite3_busy_timeout(raw, 5000)
        self.db = Handle(raw)
        self.path = path
    }

    deinit {
        if !isClosed { sqlite3_close_v2(db.raw) }
    }

    public func close() {
        guard !isClosed else { return }
        sqlite3_trace_v2(db.raw, 0, nil, nil)
        for cursor in cursors.values { sqlite3_finalize(cursor.stmt) }
        cursors.removeAll()
        sqlite3_close_v2(db.raw)
        isClosed = true
    }

    /// Reports every statement as it starts running, with bound values written inline (SQLite's
    /// expanded SQL), the way a server's statement log would. Nil turns it off.
    public func setStatementLog(_ log: (@Sendable (String) -> Void)?) {
        trace = log.map(Trace.init)
        guard let box = trace else {
            sqlite3_trace_v2(db.raw, 0, nil, nil)
            return
        }
        sqlite3_trace_v2(db.raw, UInt32(SQLITE_TRACE_STMT), { _, ctx, p, x in
            guard let ctx, let p else { return 0 }
            // Statements run by triggers are reported as "-- <sql>"; only top-level ones count.
            if let x, x.assumingMemoryBound(to: CChar.self).pointee == 0x2D { return 0 }
            guard let expanded = sqlite3_expanded_sql(OpaquePointer(p)) else { return 0 }
            defer { sqlite3_free(expanded) }
            Unmanaged<Trace>.fromOpaque(ctx).takeUnretainedValue().write(String(cString: expanded))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
    }

    // MARK: - Streaming

    /// Steps the statement a batch at a time, each when the consumer asks for it, so a slow or
    /// endless result never runs ahead of what's been read. Cancelling the consumer interrupts
    /// a step in progress and ends the stream quietly; dropping it early frees the statement.
    public nonisolated func stream(
        _ statement: SQLStatement, batchSize: Int
    ) -> AsyncThrowingStream<ResultBatch, any Error> {
        let stream = StreamState(self, statement, batchSize: max(1, batchSize))
        return AsyncThrowingStream {
            do {
                return try await withTaskCancellationHandler {
                    try await self.next(stream)
                } onCancel: {
                    stream.cancel.set()
                }
            } catch is CancellationError {
                return nil
            }
        }
    }

    /// The streamed statement's next batch, preparing it on the first call; nil once it's done.
    private func next(_ stream: StreamState) throws -> ResultBatch? {
        guard !stream.ended else { return nil }
        do {
            if stream.cancel.isSet { throw CancellationError() }
            let id = try stream.id ?? open(stream.statement, cancel: stream.cancel)
            stream.id = id
            let (batch, done) = try step(id, batchSize: stream.batchSize)
            if done {
                stream.ended = true
                finish(id)
            }
            return batch
        } catch {
            stream.ended = true
            if let id = stream.id { finish(id) }
            throw error
        }
    }

    private func open(_ statement: SQLStatement, cancel: CancelFlag) throws -> Int {
        let stmt: OpaquePointer
        do {
            stmt = try prepare(statement)
        } catch {
            // Never reached a cursor; the log still hears about it.
            if let log = statementLog, log.isObserved {
                log.record(StatementLogEntry(sql: statement.sql, bindings: statement.bindings, started: Date(),
                                             duration: .zero, error: StatementLog.describe(error)))
            }
            throw error
        }
        let columns = (0..<sqlite3_column_count(stmt)).map { i in
            ResultColumn(
                name: String(cString: sqlite3_column_name(stmt, i)),
                typeName: sqlite3_column_decltype(stmt, i).map { String(cString: $0) })
        }
        nextCursorID += 1
        cursors[nextCursorID] = Cursor(stmt: stmt, columns: columns, cancel: cancel, statement: statement)
        return nextCursorID
    }

    private func step(_ id: Int, batchSize: Int) throws -> (ResultBatch, done: Bool) {
        guard let cursor = cursors[id] else { throw DatabaseError("statement was closed") }
        // Lets a cancel interrupt a single long step (e.g. a big sort), not just between batches.
        sqlite3_progress_handler(db.raw, 1000, { ctx in
            Unmanaged<CancelFlag>.fromOpaque(ctx!).takeUnretainedValue().isSet ? 1 : 0
        }, Unmanaged.passUnretained(cursor.cancel).toOpaque())
        defer { sqlite3_progress_handler(db.raw, 0, nil, nil) }

        var rows: [[DBValue]] = []
        rows.reserveCapacity(min(batchSize, 4096))
        while rows.count < batchSize {
            let rc = sqlite3_step(cursor.stmt)
            switch rc {
            case SQLITE_ROW:
                rows.append(readRow(cursor.stmt, count: Int32(cursor.columns.count)))
            case SQLITE_DONE:
                let affected = cursor.columns.isEmpty ? Int(sqlite3_changes(db.raw)) : nil
                cursors[id]?.rows += rows.count
                cursors[id]?.done = true
                if let affected { cursors[id]?.rows = affected }
                return (ResultBatch(columns: cursor.columns, rows: rows, rowsAffected: affected), true)
            default:
                if rc & 0xFF == SQLITE_INTERRUPT, cursor.cancel.isSet {
                    cursors[id]?.error = "Cancelled"
                    throw CancellationError()
                }
                let e = error(rc, sql: sqlite3_sql(cursor.stmt).map { String(cString: $0) })
                cursors[id]?.error = e.message
                throw e
            }
        }
        cursors[id]?.rows += rows.count
        return (ResultBatch(columns: cursor.columns, rows: rows), false)
    }

    fileprivate func finish(_ id: Int) {
        guard let cursor = cursors.removeValue(forKey: id) else { return }
        sqlite3_finalize(cursor.stmt)
        if let log = statementLog, log.isObserved {
            // A consumer that stopped early cancelled the statement.
            let error = cursor.error ?? (cursor.cancel.isSet && !cursor.done ? "Cancelled" : nil)
            log.record(StatementLogEntry(
                sql: cursor.statement.sql, bindings: cursor.statement.bindings, started: cursor.started,
                duration: ContinuousClock.now - cursor.start, rows: cursor.error == nil ? cursor.rows : nil, error: error))
        }
    }

    // MARK: - Transactions

    public func transaction(
        _ statements: [SQLStatement], verify: @Sendable (Int, Int) throws -> Void
    ) throws -> [Int] {
        try run(SQLStatement(dialect.beginTransaction))
        do {
            let counts = try statements.enumerated().map { i, statement in
                let n = try run(statement)
                try verify(i, n)
                return n
            }
            try run(SQLStatement(dialect.commitTransaction))
            return counts
        } catch {
            _ = try? run(SQLStatement(dialect.rollbackTransaction))
            throw error
        }
    }

    // MARK: - Introspection

    public func objects(schema: String?) throws -> [DatabaseObject] {
        let schemaName = schema ?? "main"
        let rows = try query(SQLStatement("""
            SELECT type, name FROM \(dialect.quoteIdentifier(schemaName)).sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY name
            """))
        return rows.compactMap { row in
            guard case .text(let type) = row[0], case .text(let name) = row[1] else { return nil }
            return DatabaseObject(TableRef(schema: schema, name), kind: type == "view" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        // table_xinfo also lists generated columns (hidden 2 virtual, 3 stored); 1 is a virtual
        // table's hidden column.
        let rows = try query(SQLStatement(
            #"SELECT name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?, ?) WHERE hidden <> 1"#,
            bindings: [.text(table.name), .text(table.schema ?? "main")]))
        guard !rows.isEmpty else { throw DatabaseError("no such table: \(table)") }
        let traits = try tableSQL(table).map { (dialect as! SQLiteDialect).columnTraits(definition: $0) } ?? [:]
        return rows.map { row in
            var pk: Int?
            if case .integer(let n) = row[4], n > 0 { pk = Int(n) }
            var defaultExpression: String?
            if case .text(let d) = row[3] { defaultExpression = d }
            let name = row[0].displayString
            let trait = traits[name.lowercased()]
            var generated = trait?.generated
            if generated == nil, case .integer(let hidden) = row[5], hidden >= 2 {
                generated = "GENERATED ALWAYS AS (…) \(hidden == 3 ? "STORED" : "VIRTUAL")"
            }
            return ColumnInfo(
                name: name,
                typeName: row[1].isNull ? "" : row[1].displayString,
                isNullable: row[2] != .integer(1),
                defaultExpression: defaultExpression,
                primaryKeyPosition: pk,
                isAutoIncrement: trait?.isAutoIncrement ?? false,
                generated: generated)
        }
    }

    /// The table's CREATE TABLE text.
    private func tableSQL(_ table: TableRef) throws -> String? {
        let rows = try query(SQLStatement(
            "SELECT sql FROM \(dialect.quoteIdentifier(table.schema ?? "main")).sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.text(table.name)]))
        if case .text(let sql)? = rows.first?.first { return sql }
        return nil
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        var s = TableStructure(
            table: table, columns: try columns(of: table), indexes: try indexes(of: table),
            foreignKeys: try foreignKeys(of: table), triggers: try triggers(of: table))
        s.definition = try tableSQL(table)
        s.foreignKeysEnforced = try query(SQLStatement("PRAGMA foreign_keys")).first?.first == .integer(1)
        return s
    }

    public func definition(of object: DatabaseObject) async throws -> String {
        // Tables and views as created, then their indexes and triggers.
        let rows = try query(SQLStatement("""
            SELECT sql FROM \(dialect.quoteIdentifier(object.ref.schema ?? "main")).sqlite_master
            WHERE tbl_name = ? AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 WHEN 'index' THEN 1 ELSE 2 END, name
            """, bindings: [.text(object.ref.name)]))
        guard !rows.isEmpty else { throw DatabaseError("no such table: \(object.ref)") }
        return rows.map { $0[0].displayString + ";" }.joined(separator: "\n\n")
    }

    /// One namespace as far as the sidebar is concerned; attached databases come later.
    public nonisolated func schemas() -> [String] { [] }
    public nonisolated func currentSchema() -> String? { nil }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        let schema = table.schema ?? "main"
        let list = try query(SQLStatement(
            #"SELECT name, "unique", origin, partial FROM pragma_index_list(?, ?) ORDER BY name"#,
            bindings: [.text(table.name), .text(schema)]))
        return try list.map { row in
            let name = row[0].displayString
            // pragma_index_xinfo lists key columns first (key = 1); cid -2 is an expression.
            let columns = try query(SQLStatement(
                "SELECT name, cid FROM pragma_index_xinfo(?, ?) WHERE key = 1 ORDER BY seqno",
                bindings: [.text(name), .text(schema)]))
            // Indexes made by UNIQUE or PRIMARY KEY constraints have no SQL of their own.
            var definition: String?
            if case .text(let text)? = try query(SQLStatement(
                "SELECT sql FROM \(dialect.quoteIdentifier(schema)).sqlite_master WHERE type = 'index' AND name = ?",
                bindings: [.text(name)])).first?.first {
                definition = text
            }
            var predicate: String?
            if row[3] == .integer(1), let text = definition,
               let r = text.range(of: " WHERE ", options: [.caseInsensitive, .backwards]) {
                predicate = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return IndexInfo(
                name: name,
                columns: columns.map { $0[1] == .integer(-2) ? "<expression>" : $0[0].displayString },
                isUnique: row[1] == .integer(1), isPrimary: row[2] == .text("pk"), predicate: predicate,
                isConstraint: row[2] != .text("c"), definition: definition)
        }
    }

    public func foreignKeys(of table: TableRef) throws -> [ForeignKeyInfo] {
        let rows = try query(SQLStatement(
            #"SELECT id, "table", "from", "to", on_update, on_delete FROM pragma_foreign_key_list(?, ?) ORDER BY id, seq"#,
            bindings: [.text(table.name), .text(table.schema ?? "main")]))
        var out: [(id: DBValue, key: ForeignKeyInfo)] = []
        for row in rows {
            // "to" is NULL when the key references the parent's primary key implicitly.
            let to = row[3].isNull ? "" : row[3].displayString
            if out.last?.id == row[0] {
                out[out.count - 1].key.columns.append(row[2].displayString)
                out[out.count - 1].key.referencedColumns.append(to)
            } else {
                out.append((row[0], ForeignKeyInfo(
                    name: "", columns: [row[2].displayString],
                    referencedTable: TableRef(schema: table.schema, row[1].displayString), referencedColumns: [to],
                    onUpdate: row[4].displayString, onDelete: row[5].displayString)))
            }
        }
        return out.map(\.key)
    }

    public func triggers(of table: TableRef) throws -> [TriggerInfo] {
        let rows = try query(SQLStatement("""
            SELECT name, sql FROM \(dialect.quoteIdentifier(table.schema ?? "main")).sqlite_master
            WHERE type = 'trigger' AND tbl_name = ? ORDER BY name
            """, bindings: [.text(table.name)]))
        return rows.map { row in
            let sql = row[1].isNull ? "" : row[1].displayString
            let (timing, events) = Self.triggerHead(sql)
            return TriggerInfo(name: row[0].displayString, timing: timing, events: events, definition: sql)
        }
    }

    /// Timing and events from `CREATE TRIGGER [IF NOT EXISTS] name [BEFORE|AFTER|INSTEAD OF]
    /// {DELETE|INSERT|UPDATE [OF …]} ON …`.
    static func triggerHead(_ sql: String) -> (timing: String, events: [String]) {
        let lexer = SQLLexer(sql, dialect: .sqlite)
        let words = lexer.tokens().filter { !$0.kind.isTrivia }.map {
            String(decoding: lexer.units[$0.range], as: UTF16.self).uppercased()
        }
        guard var i = words.firstIndex(of: "TRIGGER") else { return ("AFTER", []) }
        i += 1
        if i < words.count, words[i] == "IF" { i += 3 }
        i += 1                                             // the name
        if i < words.count, words[i] == "." { i += 2 }     // schema.name
        let head = words[min(i, words.count)...].prefix { $0 != "ON" }
        let timing = head.contains("INSTEAD") ? "INSTEAD OF" : head.contains("BEFORE") ? "BEFORE" : "AFTER"
        return (timing, ["INSERT", "UPDATE", "DELETE"].filter(head.contains))
    }

    // MARK: - Helpers

    private func checkOpen() throws {
        if isClosed { throw DatabaseError("connection is closed") }
    }

    /// Prepares exactly one statement and binds its values.
    private func prepare(_ statement: SQLStatement) throws -> OpaquePointer {
        try checkOpen()
        let (rc, stmt, extra) = statement.sql.withCString { sql in
            var stmt: OpaquePointer?
            var extra: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(db.raw, sql, -1, &stmt, &tail)
            // A second real statement in the text is a caller bug: split scripts first.
            if rc == SQLITE_OK, let tail, tail.pointee != 0 {
                sqlite3_prepare_v2(db.raw, tail, -1, &extra, nil)
            }
            return (rc, Handle(stmt), Handle(extra))
        }
        guard rc == SQLITE_OK else { throw error(rc, sql: statement.sql) }
        if let extra = extra.raw {
            sqlite3_finalize(extra)
            sqlite3_finalize(stmt.raw)
            throw DatabaseError("expected one statement; split the script first", sql: statement.sql)
        }
        guard let stmt = stmt.raw else { throw DatabaseError("empty statement", sql: statement.sql) }

        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == statement.bindings.count else {
            sqlite3_finalize(stmt)
            throw DatabaseError(
                "statement has \(expected) parameters but \(statement.bindings.count) values were given",
                sql: statement.sql)
        }
        for (i, value) in statement.bindings.enumerated() {
            let rc = bind(value, to: stmt, at: Int32(i + 1))
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw error(rc, sql: statement.sql)
            }
        }
        return stmt
    }

    private func bind(_ value: DBValue, to stmt: OpaquePointer, at i: Int32) -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null: return sqlite3_bind_null(stmt, i)
        case .integer(let v): return sqlite3_bind_int64(stmt, i, v)
        case .double(let v): return sqlite3_bind_double(stmt, i, v)
        case .bool(let v): return sqlite3_bind_int64(stmt, i, v ? 1 : 0)
        case .text(let v): return sqlite3_bind_text(stmt, i, v, -1, transient)
        case .blob(let d):
            if d.isEmpty { return sqlite3_bind_zeroblob(stmt, i, 0) }
            return d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), transient) }
        }
    }

    private func readRow(_ stmt: OpaquePointer, count: Int32) -> [DBValue] {
        (0..<count).map { i in
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                return .integer(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                return .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT:
                let n = Int(sqlite3_column_bytes(stmt, i))
                guard let p = sqlite3_column_text(stmt, i) else { return .text("") }
                return .text(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, i))
                guard let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
                return .blob(Data(bytes: p, count: n))
            default:
                return .null
            }
        }
    }

    /// Runs a statement to completion, discarding rows. Returns rows changed.
    @discardableResult
    private func run(_ statement: SQLStatement) throws -> Int {
        try statementLog!.timing(statement, rows: { $0 }) { try runUnlogged(statement) }
    }

    private func runUnlogged(_ statement: SQLStatement) throws -> Int {
        let stmt = try prepare(statement)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return Int(sqlite3_changes(db.raw)) }
            if rc != SQLITE_ROW { throw error(rc, sql: statement.sql) }
        }
    }

    private func query(_ statement: SQLStatement) throws -> [[DBValue]] {
        try statementLog!.timing(statement, rows: { $0.count }) { try queryUnlogged(statement) }
    }

    private func queryUnlogged(_ statement: SQLStatement) throws -> [[DBValue]] {
        let stmt = try prepare(statement)
        defer { sqlite3_finalize(stmt) }
        var rows: [[DBValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw error(rc, sql: statement.sql) }
            rows.append(readRow(stmt, count: sqlite3_column_count(stmt)))
        }
    }

    private func error(_ rc: Int32, sql: String?) -> DatabaseError {
        DatabaseError(String(cString: sqlite3_errmsg(db.raw)), code: Int(rc), sql: sql)
    }
}

/// A sqlite3 pointer. Only used from inside the actor (the db is opened FULLMUTEX regardless).
private struct Handle<P>: @unchecked Sendable {
    let raw: P
    init(_ raw: P) { self.raw = raw }
}

private struct Cursor {
    let stmt: OpaquePointer
    let columns: [ResultColumn]
    let cancel: CancelFlag
    /// For the query log.
    let statement: SQLStatement
    let started = Date()
    let start = ContinuousClock.now
    var rows = 0
    var done = false
    var error: String?
}

private final class Trace: Sendable {
    let write: @Sendable (String) -> Void
    init(_ write: @escaping @Sendable (String) -> Void) { self.write = write }
}

/// A streamed statement's cursor. Its fields change only on the connection's actor.
private final class StreamState: @unchecked Sendable {
    let connection: SQLiteConnection
    let statement: SQLStatement
    let batchSize: Int
    let cancel = CancelFlag()
    var id: Int?
    var ended = false

    init(_ connection: SQLiteConnection, _ statement: SQLStatement, batchSize: Int) {
        self.connection = connection
        self.statement = statement
        self.batchSize = batchSize
    }

    /// A consumer that stopped reading early stopped the statement.
    deinit {
        guard !ended, let id else { return }
        cancel.set()
        let connection = connection
        Task { await connection.finish(id) }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
