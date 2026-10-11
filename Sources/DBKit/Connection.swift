/// A live connection to one database. Drivers implement this.
public protocol DatabaseConnection: Sendable {
    var dialect: any Dialect { get }

    /// Runs one statement, delivering rows in batches of up to `batchSize`.
    /// Stopping iteration (or cancelling the consuming task) cancels the statement.
    func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error>

    /// Runs statements atomically: all of them commit, or none do.
    /// Returns rows affected per statement.
    func transaction(_ statements: [SQLStatement]) async throws -> [Int]

    func objects(schema: String?) async throws -> [DatabaseObject]
    func columns(of table: TableRef) async throws -> [ColumnInfo]

    func close() async
}

extension DatabaseConnection {
    public func execute(_ statement: SQLStatement) async throws -> QueryResult {
        var result = QueryResult()
        for try await batch in stream(statement, batchSize: 1000) {
            result.columns = batch.columns
            result.rows += batch.rows
            result.rowsAffected = batch.rowsAffected ?? result.rowsAffected
        }
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

    /// Applies grid edits in one transaction.
    @discardableResult
    public func commit(_ changes: ChangeSet) async throws -> [Int] {
        try await transaction(dialect.statements(for: changes).map { $0.statement(for: dialect) })
    }
}
