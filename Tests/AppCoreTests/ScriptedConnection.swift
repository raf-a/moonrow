import DBKit
import Foundation

/// A connection without a database: it records the SQL it is sent (values inlined) and answers
/// from a script, first matching prefix wins. For checking which statements the app sends.
final class ScriptedConnection: DatabaseConnection, @unchecked Sendable {
    let dialect: any Dialect
    private let answers: [(prefix: String, result: Result<QueryResult, DatabaseError>)]
    private let table: TableRef
    private let tableColumns: [ColumnInfo]
    private let lock = NSLock()
    private var log: [String] = []

    init(_ dialect: any Dialect, table: TableRef = TableRef("t"), columns: [ColumnInfo] = [],
         answers: [(String, Result<QueryResult, DatabaseError>)] = []) {
        self.dialect = dialect
        self.table = table
        self.tableColumns = columns
        self.answers = answers.map { ($0.0, $0.1) }
    }

    var sent: [String] { lock.withLock { log } }

    static func rows(_ rows: [[DBValue]]) -> Result<QueryResult, DatabaseError> {
        var r = QueryResult()
        r.rows = rows
        return .success(r)
    }

    private func answer(_ statement: SQLStatement) -> Result<QueryResult, DatabaseError> {
        let sql = inline(statement)
        lock.withLock { log.append(sql) }
        return answers.first { sql.hasPrefix($0.prefix) }?.result ?? .success(QueryResult())
    }

    /// The statement with its bound values written in (good enough for test SQL).
    private func inline(_ statement: SQLStatement) -> String {
        var sql = statement.sql
        if dialect is PostgresDialect {
            for (i, v) in statement.bindings.enumerated().reversed() {
                sql = sql.replacingOccurrences(of: "$\(i + 1)", with: dialect.literal(v))
            }
            return sql
        }
        for v in statement.bindings {
            guard let r = sql.range(of: "?") else { break }
            sql.replaceSubrange(r, with: dialect.literal(v))
        }
        return sql
    }

    func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        let result = answer(statement)
        return AsyncThrowingStream { continuation in
            switch result {
            case .success(let r):
                continuation.yield(ResultBatch(columns: r.columns, rows: r.rows, rowsAffected: r.rowsAffected))
                continuation.finish()
            case .failure(let e):
                continuation.finish(throwing: e)
            }
        }
    }

    func transaction(
        _ statements: [SQLStatement], verify: @Sendable (Int, Int) throws -> Void
    ) async throws -> [Int] {
        var affected: [Int] = []
        for (i, s) in statements.enumerated() {
            let n = try answer(s).get().rowsAffected ?? 1
            try verify(i, n)
            affected.append(n)
        }
        return affected
    }

    func schemas() async throws -> [String] { [] }
    func currentSchema() async throws -> String? { nil }
    func objects(schema: String?) async throws -> [DatabaseObject] { [DatabaseObject(table, kind: .table)] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { tableColumns }
    func indexes(of table: TableRef) async throws -> [IndexInfo] { [] }
    func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] { [] }
    func triggers(of table: TableRef) async throws -> [TriggerInfo] { [] }
    func close() async {}
}
