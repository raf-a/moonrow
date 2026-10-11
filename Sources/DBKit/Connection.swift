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

    func close() async
}

extension DatabaseConnection {
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
