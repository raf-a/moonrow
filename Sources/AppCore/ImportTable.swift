import DBKit
import Foundation

/// A new table made from an import file: one column per file column, named after it, with a type
/// guessed from the first records. Every column is nullable and there's no primary key.
public struct ImportTableDesign: Sendable, Hashable {
    public struct Column: Sendable, Hashable {
        public var name: String
        public var typeName: String
        /// False leaves the file column out of the table.
        public var include: Bool

        public init(name: String, typeName: String, include: Bool = true) {
            self.name = name
            self.typeName = typeName
            self.include = include
        }
    }

    public var table: TableRef
    public var columns: [Column]

    public init(table: TableRef, columns: [Column]) {
        self.table = table
        self.columns = columns
    }

    /// Names from the file's header (or `column_1`, …), types guessed from `records`.
    public static func guess(
        table: TableRef, names: [String], hasNames: Bool, records: [ImportRecord], dialect: any Dialect, decimalComma: Bool = false
    ) -> ImportTableDesign {
        let cleaned = columnNames(hasNames ? names : names.indices.map { "column_\($0 + 1)" })
        let types = cleaned.indices.map { i in
            var guess = TypeGuess()
            for r in records where i < r.fields.count { guess.add(r.fields[i], decimalComma: decimalComma) }
            return guess.typeName(dialect)
        }
        return ImportTableDesign(table: table, columns: zip(cleaned, types).map { Column(name: $0, typeName: $1) })
    }

    /// Names trimmed, empty ones `column_N`, repeats `_2`, `_3`, … (compared ignoring case).
    static func columnNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { i, raw in
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "column_\(i + 1)" }
            var name = base
            var n = 1
            while used.contains(name.lowercased()) {
                n += 1
                name = "\(base)_\(n)"
            }
            used.insert(name.lowercased())
            return name
        }
    }

    public func validate() throws {
        guard !table.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw DatabaseError("Enter a name for the new table.") }
        let included = columns.filter(\.include)
        guard !included.isEmpty else { throw DatabaseError("The new table needs at least one column.") }
        var seen = Set<String>()
        for c in included {
            guard !c.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw DatabaseError("Every column needs a name.") }
            guard !c.typeName.trimmingCharacters(in: .whitespaces).isEmpty else { throw DatabaseError("Column \(c.name) needs a type.") }
            guard seen.insert(c.name.lowercased()).inserted else { throw DatabaseError("Two columns are named \(c.name).") }
        }
    }

    /// The table's columns, in file order, for the import plan.
    public var tableColumns: [ColumnInfo] {
        columns.filter(\.include).map { ColumnInfo(name: $0.name, typeName: $0.typeName) }
    }

    /// Per table column, the file column it's read from.
    public var mapping: [Int?] {
        columns.enumerated().filter { $0.element.include }.map { $0.offset }
    }

    /// The CREATE TABLE.
    public func plan(_ dialect: any Dialect) throws -> DDLPlan {
        try validate()
        let design = TableDesign(name: table.name, columns: tableColumns.map { Designed(origin: nil, $0) })
        return dialect.createTable(design, schema: table.schema)
    }
}

/// What a column's values have in common, from the narrowest type to text.
struct TypeGuess {
    private var seen = false
    private var integer = true
    private var decimal = true
    private var double = true
    private var boolean = true
    private var date = true
    private var timestamp = true
    private var zoned = false
    private var fraction = false
    private var integerDigits = 0
    private var fractionDigits = 0
    private var longest = 0

    mutating func add(_ field: CSVField, decimalComma: Bool) {
        // NULL says nothing about the type; an empty string means text.
        if field.text.isEmpty, !field.quoted { return }
        seen = true
        let text = field.text.trimmingCharacters(in: .whitespaces)
        longest = max(longest, field.text.count)
        let number = decimalComma ? (CSVImportPlan.decimalCommaNumber(text) ?? text) : text
        // Leading zeros (codes, phone numbers) would be lost in a number.
        if number.wholeMatch(of: /[-+]?0\d.*/) != nil { integer = false; decimal = false; double = false }
        if integer, Int64(number) == nil || text.isEmpty { integer = false }
        if decimal {
            if let m = number.wholeMatch(of: /[-+]?(\d*)(?:\.(\d+))?/), !(m.1.isEmpty && (m.2 ?? "").isEmpty), !text.isEmpty {
                integerDigits = max(integerDigits, m.1.drop { $0 == "0" }.count)
                fractionDigits = max(fractionDigits, m.2?.count ?? 0)
            } else {
                decimal = false
            }
        }
        if double, Double(number) == nil || text.isEmpty || number.lowercased().contains("n") { double = false }
        if boolean, !["true", "false"].contains(text.lowercased()) { boolean = false }
        if date, text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) == nil || !Self.validDate(text) { date = false }
        if timestamp {
            if let m = text.wholeMatch(of: /(\d{4}-\d{2}-\d{2})[ T]\d{2}:\d{2}(?::\d{2}(\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?/), Self.validDate(String(m.1)) {
                if m.2 != nil { fraction = true }
                if m.3 != nil { zoned = true }
            } else {
                timestamp = false
            }
        }
    }

    private static func validDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), parts[2] >= 1 else { return false }
        var c = DateComponents()
        (c.year, c.month) = (parts[0], parts[1])
        let days = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: Calendar(identifier: .gregorian).date(from: c) ?? Date())?.count ?? 31
        return parts[2] <= days
    }

    func typeName(_ dialect: any Dialect) -> String {
        let mysql = dialect is MySQLDialect
        let postgres = dialect is PostgresDialect
        guard seen else { return mysql ? "VARCHAR(255)" : postgres ? "text" : "TEXT" }
        if boolean { return mysql ? "TINYINT(1)" : postgres ? "boolean" : "BOOLEAN" }
        if integer { return mysql ? "BIGINT" : postgres ? "bigint" : "INTEGER" }
        if decimal, integerDigits + fractionDigits <= 38 {
            if mysql { return "DECIMAL(\(min(65, max(1, integerDigits + fractionDigits))),\(min(30, fractionDigits)))" }
            return postgres ? "numeric" : "REAL"
        }
        if double { return mysql ? "DOUBLE" : postgres ? "double precision" : "REAL" }
        if date { return mysql ? "DATE" : postgres ? "date" : "DATE" }
        if timestamp, !(zoned && !postgres) {
            if mysql { return fraction ? "DATETIME(6)" : "DATETIME" }
            return postgres ? (zoned ? "timestamptz" : "timestamp") : "DATETIME"
        }
        if mysql {
            return longest <= 255 ? "VARCHAR(255)" : longest <= 16_383 ? "TEXT" : "LONGTEXT"
        }
        return postgres ? "text" : "TEXT"
    }
}
