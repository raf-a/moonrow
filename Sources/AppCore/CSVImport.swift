import DBKit
import Foundation

/// Inserts a CSV document's rows into an existing table.
///
/// Each target column takes one source column, or none (then the database's default applies).
/// Fields are converted by the target column's declared type the way typed cell input is. An
/// empty unquoted field is NULL and a quoted empty field (`""`) an empty string, as in Postgres's
/// CSV COPY. Rows go in as multi-row INSERTs with bound values, all in one transaction, so a
/// failure leaves the table as it was.
public struct CSVImportPlan: Sendable {
    public enum Match: String, Codable, Sendable, CaseIterable {
        /// Header names, ignoring case; columns without a match aren't imported.
        case byName
        /// The first source column to the first target column, and so on.
        case byOrder
    }

    public enum OnDuplicate: String, Codable, Sendable, CaseIterable {
        /// A row whose key exists fails the import.
        case stop
        /// A row whose primary key exists updates that row's imported columns.
        case update
    }

    public var table: TableRef
    public var columns: [ColumnInfo]
    /// Per target column: the source column index, or nil to skip it.
    public var mapping: [Int?]
    public var onDuplicate: OnDuplicate
    /// An unquoted `NULL` is NULL too (it's what our export writes when NULL isn't left empty).
    public var nullWord: Bool
    /// Bound values per statement stay under this, well below every database's limit.
    public var maxBindings: Int
    public var maxRowsPerStatement: Int

    public init(
        table: TableRef, columns: [ColumnInfo], mapping: [Int?], onDuplicate: OnDuplicate = .stop,
        nullWord: Bool = false, maxBindings: Int = 5000, maxRowsPerStatement: Int = 500
    ) {
        self.table = table
        self.columns = columns
        self.mapping = mapping
        self.onDuplicate = onDuplicate
        self.nullWord = nullWord
        self.maxBindings = maxBindings
        self.maxRowsPerStatement = maxRowsPerStatement
    }

    /// The mapping a match strategy gives. Generated columns are never written.
    public static func mapping(for columns: [ColumnInfo], source: [String]?, sourceCount: Int, match: Match) -> [Int?] {
        columns.enumerated().map { i, column in
            if column.generated?.hasPrefix("GENERATED ALWAYS") == true { return nil }
            if match == .byName, let source {
                return source.firstIndex { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(column.name) == .orderedSame }
            }
            return i < sourceCount ? i : nil
        }
    }

    var mapped: [(column: ColumnInfo, source: Int)] {
        zip(columns, mapping).compactMap { c, s in s.map { (c, $0) } }
    }

    public var rowsPerStatement: Int {
        max(1, min(maxRowsPerStatement, maxBindings / max(1, mapped.count)))
    }

    public func validate() throws {
        guard !mapped.isEmpty else { throw DatabaseError("No column is mapped to the file.") }
        if onDuplicate == .update {
            let key = columns.primaryKey
            guard !key.isEmpty else { throw DatabaseError("Updating existing rows needs a primary key, and \(table.name) has none.") }
            let names = Set(mapped.map(\.column.name))
            guard key.allSatisfy(names.contains) else {
                throw DatabaseError("Updating existing rows needs every primary-key column (\(key.joined(separator: ", "))) mapped.")
            }
        }
    }

    /// The value a field becomes in `column`.
    public func value(_ field: CSVField, for column: ColumnInfo) -> DBValue {
        if !field.quoted {
            if field.text.isEmpty { return .null }
            if nullWord, field.text == "NULL" { return .null }
        }
        let type = column.typeName.uppercased()
        if type.contains("BLOB") || type.contains("BYTEA") || type.contains("BINARY"),
           field.text.hasPrefix("\\x"), let data = Self.hexData(field.text.dropFirst(2)) {
            return .blob(data)
        }
        return CellInput.parse(field.text, typeName: column.typeName)
    }

    static func hexData(_ s: Substring) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }

    /// One statement and the source rows (indexes into the document) it inserts.
    public struct Statement: Sendable {
        public var fragment: SQLFragment
        public var rows: Range<Int>
    }

    public func statements(for document: CSVDocument, dialect: any Dialect) throws -> [Statement] {
        try validate()
        let mapped = mapped
        let per = rowsPerStatement
        let names = mapped.map { dialect.quoteIdentifier($0.column.name) }
        let head = "INSERT INTO \(dialect.qualified(table)) (\(names.joined(separator: ", "))) VALUES "
        let tail = onDuplicate == .update ? upsertClause(dialect) : ""
        var out: [Statement] = []
        for start in stride(from: 0, to: document.rows.count, by: per) {
            let range = start..<min(document.rows.count, start + per)
            var sql = SQLFragment(head)
            for r in range {
                if r > start { sql.append(", ") }
                let row = document.rows[r]
                sql.append("(")
                for (i, m) in mapped.enumerated() {
                    if i > 0 { sql.append(", ") }
                    sql.append(value: m.source < row.count ? value(row[m.source], for: m.column) : .null)
                }
                sql.append(")")
            }
            sql.append(tail)
            out.append(Statement(fragment: sql, rows: range))
        }
        return out
    }

    private func upsertClause(_ dialect: any Dialect) -> String {
        let key = columns.primaryKey
        let others = mapped.map(\.column.name).filter { !key.contains($0) }.map(dialect.quoteIdentifier)
        if dialect is MySQLDialect {
            let set = others.isEmpty
                ? [dialect.quoteIdentifier(key[0]) + " = " + dialect.quoteIdentifier(key[0])]
                : others.map { "\($0) = VALUES(\($0))" }
            return " ON DUPLICATE KEY UPDATE " + set.joined(separator: ", ")
        }
        let target = " ON CONFLICT (" + key.map(dialect.quoteIdentifier).joined(separator: ", ") + ")"
        if others.isEmpty { return target + " DO NOTHING" }
        return target + " DO UPDATE SET " + others.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    }

    /// The first statements with their values written inline, for the import sheet and safe mode.
    public func preview(for document: CSVDocument, dialect: any Dialect, statements limit: Int = 3) throws -> [String] {
        var doc = document
        doc.rows = Array(document.rows.prefix(rowsPerStatement * limit))
        return try statements(for: doc, dialect: dialect).map { $0.fragment.inlined(for: dialect) + ";" }
    }

    /// Runs the import in one transaction and returns the number of rows sent. `progress` gets the
    /// rows sent so far after each statement. A failure names the lines of the statement that failed.
    @discardableResult
    public func run(
        _ document: CSVDocument, on connection: any DatabaseConnection,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        let dialect = connection.dialect
        let statements = try statements(for: document, dialect: dialect)
        guard !statements.isEmpty else { return 0 }
        let done = Counter()
        let ends = statements.map(\.rows.upperBound)
        do {
            _ = try await connection.transaction(statements.map { $0.fragment.statement(for: dialect) }) { i, _ in
                done.set(i + 1)
                progress(ends[i])
            }
        } catch var error as DatabaseError {
            let failed = done.value
            if failed < statements.count {
                let rows = statements[failed].rows
                let first = document.lines[safe: rows.lowerBound] ?? 0
                let last = document.lines[safe: rows.upperBound - 1] ?? first
                let place = first == last ? "line \(first)" : "lines \(first)–\(last)"
                error.message = "Nothing was imported. The rows from \(place) failed: \(error.message)"
            } else {
                error.message = "Nothing was imported: \(error.message)"
            }
            error.sql = nil
            throw error
        }
        return document.rows.count
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func set(_ v: Int) { lock.withLock { n = v } }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
