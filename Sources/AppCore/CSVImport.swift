import DBKit
import Foundation

/// Inserts an import file's records (CSV or JSON) into a table, existing or created for it.
///
/// Each target column takes one source column, or none (then the database's default applies).
/// Fields are converted by the target column's declared type the way typed cell input is. An
/// empty unquoted field is NULL and a quoted empty field (`""`) an empty string, as in Postgres's
/// CSV COPY. Rows go in as multi-row INSERTs with bound values, sent as the file is read, all in
/// one transaction, so a failure or Stop leaves the table as it was.
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
    /// Numbers in the file use a decimal comma (`1,5`, `1.234,5`): in numeric columns, `,`
    /// becomes the decimal point and `.` and spaces between digit groups are dropped.
    public var decimalComma: Bool
    /// Bound values per statement stay under this, well below every database's limit.
    public var maxBindings: Int
    public var maxRowsPerStatement: Int

    public init(
        table: TableRef, columns: [ColumnInfo], mapping: [Int?], onDuplicate: OnDuplicate = .stop,
        nullWord: Bool = false, decimalComma: Bool = false, maxBindings: Int = 5000, maxRowsPerStatement: Int = 500
    ) {
        self.table = table
        self.columns = columns
        self.mapping = mapping
        self.onDuplicate = onDuplicate
        self.nullWord = nullWord
        self.decimalComma = decimalComma
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
        // MySQL's booleans are TINYINT(1).
        if type.hasPrefix("TINYINT(1)") {
            switch field.text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
        }
        if decimalComma, Self.isNumericType(type), let number = Self.decimalCommaNumber(field.text) {
            return CellInput.parse(number, typeName: column.typeName)
        }
        return CellInput.parse(field.text, typeName: column.typeName)
    }

    static func isNumericType(_ upper: String) -> Bool {
        (upper.contains("INT") && !upper.contains("INTERVAL") && !upper.contains("POINT"))
            || ["REAL", "FLOA", "DOUB", "NUMERIC", "DECIMAL", "NUMBER"].contains { upper.contains($0) }
    }

    /// `1.234,5` → `1234.5`; nil when the text isn't a number written that way.
    static func decimalCommaNumber(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.wholeMatch(of: /[-+]?\d{1,3}([. \u{00A0}\u{202F}]?\d{3})*(,\d+)?|[-+]?\d+(,\d+)?|[-+]?,\d+/) != nil else { return nil }
        let plain = t.filter { $0 != "." && $0 != " " && $0 != "\u{00A0}" && $0 != "\u{202F}" }
            .replacingOccurrences(of: ",", with: ".")
        return plain.hasPrefix(".") || plain.hasPrefix("-.") || plain.hasPrefix("+.") ? plain.replacingOccurrences(of: ".", with: "0.") : plain
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
        let per = rowsPerStatement
        var out: [Statement] = []
        for start in stride(from: 0, to: document.rows.count, by: per) {
            let range = start..<min(document.rows.count, start + per)
            out.append(Statement(fragment: insert(document.rows[range], dialect: dialect), rows: range))
        }
        return out
    }

    /// One multi-row INSERT for `rows` (each a record's fields).
    public func insert<C: Collection>(_ rows: C, dialect: any Dialect) -> SQLFragment where C.Element == [CSVField] {
        let mapped = mapped
        let names = mapped.map { dialect.quoteIdentifier($0.column.name) }
        var sql = SQLFragment("INSERT INTO \(dialect.qualified(table)) (\(names.joined(separator: ", "))) VALUES ")
        for (r, row) in rows.enumerated() {
            if r > 0 { sql.append(", ") }
            sql.append("(")
            for (i, m) in mapped.enumerated() {
                if i > 0 { sql.append(", ") }
                sql.append(value: m.source < row.count ? value(row[m.source], for: m.column) : .null)
            }
            sql.append(")")
        }
        if onDuplicate == .update { sql.append(upsertClause(dialect)) }
        return sql
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
        try preview(rows: Array(document.rows.prefix(rowsPerStatement * limit)), dialect: dialect, statements: limit)
    }

    public func preview(rows: [[CSVField]], dialect: any Dialect, statements limit: Int = 3) throws -> [String] {
        try validate()
        let per = rowsPerStatement
        return stride(from: 0, to: min(rows.count, per * limit), by: per).map { start in
            insert(rows[start..<min(rows.count, start + per)], dialect: dialect).inlined(for: dialect) + ";"
        }
    }

    /// Runs the import of a document in memory in one transaction and returns the number of rows.
    @discardableResult
    public func run(
        _ document: CSVDocument, on connection: any DatabaseConnection,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        try await run(DocumentRecords(document), on: connection) { rows, _ in progress(rows) }
    }

    /// Reads `records` and sends them as it goes, in one transaction; `creating` (a new table's
    /// CREATE) runs first. Where DDL can't be rolled back (MySQL) the table is created before the
    /// transaction and dropped again if the import fails or is stopped. `progress` gets the rows
    /// sent and how far through the file reading is. A failure names the lines of the statement
    /// that failed; nothing is imported then.
    @discardableResult
    public func run(
        _ records: any ImportRecords, on connection: any DatabaseConnection, creating: DDLPlan? = nil,
        progress: @escaping @Sendable (_ rows: Int, _ fraction: Double) -> Void = { _, _ in }
    ) async throws -> Int {
        try validate()
        let dialect = connection.dialect
        let source = UncheckedBox(records)
        let plan = self
        let createInside = creating.map { $0.isAtomic && dialect.transactionalDDL } ?? false
        if let creating, !createInside {
            try await connection.apply(creating)
        }
        do {
            return try await connection.withTransaction { scope in
                if let creating, createInside {
                    for sql in creating.setup + creating.statements { _ = try await scope.execute(SQLStatement(sql)) }
                }
                let per = plan.rowsPerStatement
                var batch: [ImportRecord] = []
                batch.reserveCapacity(per)
                var sent = 0
                func flush() async throws {
                    guard !batch.isEmpty else { return }
                    do {
                        _ = try await scope.execute(plan.insert(batch.map(\.fields), dialect: dialect).statement(for: dialect))
                    } catch var error as DatabaseError {
                        let first = batch.first!.line, last = batch.last!.line
                        let place = first == last ? "line \(first)" : "lines \(first)–\(last)"
                        error.message = "Nothing was imported. The rows from \(place) failed: \(error.message)"
                        error.sql = nil
                        throw error
                    }
                    sent += batch.count
                    batch.removeAll(keepingCapacity: true)
                    progress(sent, source.value.fractionRead)
                }
                do {
                    while let record = try source.value.next() {
                        try Task.checkCancellation()
                        batch.append(record)
                        if batch.count >= per { try await flush() }
                    }
                } catch let error as DatabaseError where !error.message.hasPrefix("Nothing was imported") {
                    throw DatabaseError("Nothing was imported: \(error.message)")
                }
                try Task.checkCancellation()
                try await flush()
                return sent
            }
        } catch {
            if let creating, !createInside, let drop = Self.dropAfterFailure(creating, table: table, dialect: dialect) {
                await Task.detached { _ = try? await connection.execute(SQLStatement(drop)) }.value
            }
            throw error
        }
    }

    /// The DROP that undoes a CREATE made outside the transaction.
    static func dropAfterFailure(_ creating: DDLPlan, table: TableRef, dialect: any Dialect) -> String? {
        (try? dialect.drop(DatabaseObject(table, kind: .table), options: DropOptions()))?.statements.first
    }
}

/// Holds a value that is only ever used from one task at a time.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
