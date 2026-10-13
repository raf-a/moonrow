import Foundation

/// A live connection to one database. Drivers implement this.
public protocol DatabaseConnection: Sendable {
    var dialect: any Dialect { get }

    /// Runs one statement, delivering rows in batches of up to `batchSize`.
    /// Stopping iteration (or cancelling the consuming task) cancels the statement.
    func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error>

    /// Runs statements atomically: all of them commit, or none do.
    /// `verify` sees each statement's index and rows affected right after it runs; throwing
    /// from it rolls everything back. Returns rows affected per statement.
    func transaction(
        _ statements: [SQLStatement], verify: @Sendable (_ index: Int, _ rowsAffected: Int) throws -> Void
    ) async throws -> [Int]

    /// Schemas (Postgres) or databases (MySQL) the sidebar can switch between, without the
    /// system ones. Empty when there is a single namespace (SQLite).
    func schemas() async throws -> [String]
    /// Where unqualified names resolve: `current_schema()`, `DATABASE()`. Nil if nowhere.
    func currentSchema() async throws -> String?
    /// Tables, views and routines of a schema; nil means the current one.
    func objects(schema: String?) async throws -> [DatabaseObject]
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func indexes(of table: TableRef) async throws -> [IndexInfo]
    func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo]
    func triggers(of table: TableRef) async throws -> [TriggerInfo]
    /// Everything the structure editor shows. The default puts the calls above together;
    /// drivers add comments and what their DDL needs.
    func structure(of table: TableRef) async throws -> TableStructure
    /// The statements that create the object, for the DDL view and "Copy as CREATE".
    func definition(of object: DatabaseObject) async throws -> String

    /// Reports every statement sent on this connection (the workspace's query log). Nil for
    /// connections that don't.
    var statementLog: StatementLog? { get }

    /// Runs `body` inside one transaction: committed when it returns, rolled back when it
    /// throws. Nothing else runs on the connection meanwhile, and a dropped session isn't
    /// reopened halfway, so statements can be sent as they're produced (a streamed import).
    func withTransaction<T: Sendable>(_ body: @Sendable (any TransactionScope) async throws -> T) async throws -> T

    /// Runs a `COPY … FROM STDIN` statement, sending what `source` hands out until it returns
    /// nil. Returns the rows copied. Only Postgres has it.
    func copyIn(_ sql: String, from source: @escaping CopySource) async throws -> Int

    func close() async
}

/// Statements sent inside `DatabaseConnection.withTransaction`.
public protocol TransactionScope: Sendable {
    /// Runs one statement and returns the rows it affected. Cancelling the task stops it.
    func execute(_ statement: SQLStatement) async throws -> Int
}

/// The data for a `COPY … FROM STDIN`, a piece at a time; nil at the end.
public typealias CopySource = @Sendable () async throws -> Data?

/// The default scope: statements on the connection itself.
struct ConnectionScope: TransactionScope {
    let connection: any DatabaseConnection

    func execute(_ statement: SQLStatement) async throws -> Int {
        try await connection.execute(statement).rowsAffected ?? 0
    }
}

extension DatabaseConnection {
    public var statementLog: StatementLog? { nil }

    /// BEGIN, the body's statements and COMMIT, each sent on its own (SQLite and test fakes).
    public func withTransaction<T: Sendable>(_ body: @Sendable (any TransactionScope) async throws -> T) async throws -> T {
        _ = try await execute(SQLStatement(dialect.beginTransaction))
        do {
            let value = try await body(ConnectionScope(connection: self))
            _ = try await execute(SQLStatement(dialect.commitTransaction))
            return value
        } catch {
            // The rollback must run even when the task was cancelled.
            let rollback = SQLStatement(dialect.rollbackTransaction)
            await Task.detached { _ = try? await self.execute(rollback) }.value
            throw error
        }
    }

    public func copyIn(_ sql: String, from source: @escaping CopySource) async throws -> Int {
        throw DatabaseError("COPY FROM STDIN isn't supported on this connection.", sql: sql)
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        TableStructure(
            table: table, columns: try await columns(of: table), indexes: try await indexes(of: table),
            foreignKeys: try await foreignKeys(of: table), triggers: try await triggers(of: table))
    }

    /// Tables: CREATE TABLE written from the structure, then the triggers.
    public func definition(of object: DatabaseObject) async throws -> String {
        guard object.kind == .table else { throw DatabaseError("No definition is available for \(object.ref.name).") }
        let s = try await structure(of: object.ref)
        var design = TableDesign(s)
        // Constraint indexes come with their constraints; list the others.
        design.indexes = design.indexes.filter { !$0.value.isConstraint }
        let plan = dialect.createTable(design, schema: object.ref.schema)
        let statements = plan.statements.map { $0 + ";" } + s.triggers.map { $0.definition + ";" }
        return statements.joined(separator: "\n\n")
    }

    /// Runs DDL: setup, then the statements (in one transaction where the database can roll
    /// DDL back), then teardown, which runs even after a failure.
    public func apply(_ plan: DDLPlan) async throws {
        for sql in plan.setup { _ = try await execute(SQLStatement(sql)) }
        do {
            if plan.isAtomic {
                _ = try await transaction(plan.statements.map { SQLStatement($0) })
            } else {
                for (i, sql) in plan.statements.enumerated() {
                    do {
                        _ = try await execute(SQLStatement(sql))
                    } catch var error as DatabaseError {
                        if i > 0 {
                            error.message += " (The \(i == 1 ? "first statement was" : "first \(i) statements were") applied.)"
                        }
                        error.sql = sql
                        throw error
                    }
                }
            }
        } catch {
            for sql in plan.teardown { _ = try? await execute(SQLStatement(sql)) }
            throw error
        }
        for sql in plan.teardown { _ = try await execute(SQLStatement(sql)) }
    }

    public func transaction(_ statements: [SQLStatement]) async throws -> [Int] {
        try await transaction(statements, verify: { _, _ in })
    }

    public func execute(_ statement: SQLStatement) async throws -> QueryResult {
        var result = QueryResult()
        for try await batch in stream(statement, batchSize: 1000) {
            result.columns = batch.columns
            result.rows += batch.rows
            result.rowsAffected = batch.rowsAffected ?? result.rowsAffected
        }
        // A cancelled consumer sees the stream end early; the result is incomplete, not empty.
        try Task.checkCancellation()
        return result
    }

    public func execute(_ sql: String, _ bindings: DBValue...) async throws -> QueryResult {
        try await execute(SQLStatement(sql, bindings: bindings))
    }

    public func execute(_ fragment: SQLFragment) async throws -> QueryResult {
        try await execute(fragment.statement(for: dialect))
    }

    /// One page of a table for the grid.
    public func browse(_ request: BrowseRequest) async throws -> QueryResult {
        let all = try await columns(of: request.table).map(\.name)
        return try await execute(dialect.select(request, allColumns: all))
    }

    public func count(_ table: TableRef, filter: Filter? = nil) async throws -> Int {
        let all = try await columns(of: table).map(\.name)
        let result = try await execute(dialect.count(table, filter: filter, allColumns: all))
        guard case .integer(let n)? = result.rows.first?.first else {
            throw DatabaseError("COUNT(*) returned no integer")
        }
        return Int(n)
    }

    /// Applies grid edits in one transaction. Every statement targets one row, so one that
    /// changes no row (it was deleted meanwhile) or several (a table without a key holding
    /// duplicates) rolls the whole set back.
    @discardableResult
    public func commit(_ changes: ChangeSet) async throws -> [Int] {
        let fragments = dialect.statements(for: changes)
        let dialect = dialect
        return try await transaction(fragments.map { $0.statement(for: dialect) }) { i, affected in
            guard affected != 1 else { return }
            let what = affected == 0 ? "matched no row; it may have been changed or deleted meanwhile"
                : "would change \(affected) rows instead of one"
            throw DatabaseError("Nothing was saved: statement \(i + 1) \(what).",
                                sql: fragments[i].inlined(for: dialect))
        }
    }
}
