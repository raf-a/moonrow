import DBKit
import Foundation

// Row writers for export and "Copy Rows As". Each writer turns a stream of rows into text in
// three steps (header, rows, footer), so the export job can write a table of any size without
// holding it in memory, and tests can check the text directly.

/// Turns rows into one file format, a batch at a time.
public protocol RowWriter {
    mutating func header(columns: [String]) -> String
    mutating func rows(_ rows: [[DBValue]]) -> String
    mutating func footer() -> String
}

extension RowWriter {
    /// The whole document for rows already in memory.
    public mutating func document(columns: [String], rows: [[DBValue]]) -> String {
        header(columns: columns) + self.rows(rows) + footer()
    }
}

// MARK: - CSV

public struct CSVOptions: Codable, Hashable, Sendable {
    public enum Quoting: String, Codable, Sendable, CaseIterable {
        /// Only fields that need it: the delimiter, a quote, a line break, leading or trailing spaces,
        /// or an empty string (so it isn't read back as NULL).
        case ifNeeded
        /// Every field except NULL, which stays an unquoted empty field.
        case always
    }

    public enum LineBreak: String, Codable, Sendable, CaseIterable {
        case lf, crlf, cr
        public var text: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    /// A single character.
    public var delimiter: String
    public var quoting: Quoting
    public var lineBreak: LineBreak
    public var includeHeader: Bool
    /// NULL as an empty unquoted field; otherwise the word `NULL`.
    public var nullAsEmpty: Bool
    /// Line breaks inside values become a space.
    public var flattenLineBreaks: Bool
    /// `.` or `,`, used for floating-point values.
    public var decimalSeparator: String

    public init(
        delimiter: String = ",", quoting: Quoting = .ifNeeded, lineBreak: LineBreak = .lf,
        includeHeader: Bool = true, nullAsEmpty: Bool = true, flattenLineBreaks: Bool = false,
        decimalSeparator: String = "."
    ) {
        self.delimiter = delimiter
        self.quoting = quoting
        self.lineBreak = lineBreak
        self.includeHeader = includeHeader
        self.nullAsEmpty = nullAsEmpty
        self.flattenLineBreaks = flattenLineBreaks
        self.decimalSeparator = decimalSeparator
    }

    public func validate() throws {
        guard delimiter.unicodeScalars.count == 1 else { throw DatabaseError("The delimiter must be a single character.") }
        guard delimiter != "\"", delimiter != "\n", delimiter != "\r" else {
            throw DatabaseError("A quote or a line break can't be the delimiter.")
        }
        guard decimalSeparator == "." || decimalSeparator == "," else { throw DatabaseError("The decimal separator must be . or ,") }
        guard decimalSeparator != delimiter else {
            throw DatabaseError("The decimal separator can't be the same as the delimiter.")
        }
    }
}

public struct CSVWriter: RowWriter {
    public var options: CSVOptions

    public init(_ options: CSVOptions = CSVOptions()) { self.options = options }

    public mutating func header(columns: [String]) -> String {
        guard options.includeHeader else { return "" }
        return line(columns.map { field($0) })
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        var out = ""
        for row in rows { out += line(row.map(field)) }
        return out
    }

    public mutating func footer() -> String { "" }

    private func line(_ fields: [String]) -> String {
        fields.joined(separator: options.delimiter) + options.lineBreak.text
    }

    func field(_ value: DBValue) -> String {
        switch value {
        case .null: return options.nullAsEmpty ? "" : "NULL"
        case .double(let d) where options.decimalSeparator != ".":
            return field(String(d).replacingOccurrences(of: ".", with: options.decimalSeparator))
        case .blob(let data): return field(Self.hex(data))
        default: return field(value.displayString)
        }
    }

    /// A text field, quoted as the options say.
    func field(_ text: String) -> String {
        var s = text
        if options.flattenLineBreaks { s = s.replacing(/\r\n|\r|\n/, with: " ") }
        let needsQuotes = options.quoting == .always || s.isEmpty
            || s.contains(options.delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r")
            || s.first == " " || s.last == " "
        guard needsQuotes else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Blobs as `\x` and lowercase hex, which Postgres reads back as bytea and our importer as a blob.
    public static func hex(_ data: Data) -> String {
        "\\x" + data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JSON

public struct JSONOptions: Codable, Hashable, Sendable {
    /// One key per line; otherwise one object per line.
    public var pretty: Bool

    public init(pretty: Bool = true) { self.pretty = pretty }
}

/// An array of objects keyed by column name. Repeated names get `_2`, `_3`, … so no value is lost.
public struct JSONWriter: RowWriter {
    public var options: JSONOptions
    private var keys: [String] = []
    private var wroteRow = false

    public init(_ options: JSONOptions = JSONOptions()) { self.options = options }

    public mutating func header(columns: [String]) -> String {
        keys = Self.uniqueKeys(columns).map(Self.string)
        wroteRow = false
        return "["
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        var out = ""
        for row in rows {
            out += wroteRow ? ",\n" : "\n"
            wroteRow = true
            let pairs = zip(keys, row).map { key, value in key + ": " + Self.value(value) }
            if options.pretty {
                out += "  {\n" + pairs.map { "    " + $0 }.joined(separator: ",\n") + "\n  }"
            } else {
                out += "  {" + pairs.joined(separator: ", ") + "}"
            }
        }
        return out
    }

    public mutating func footer() -> String { wroteRow ? "\n]\n" : "]\n" }

    static func uniqueKeys(_ columns: [String]) -> [String] {
        var seen: [String: Int] = [:]
        var used = Set<String>()
        return columns.map { name in
            var key = name
            var n = seen[name, default: 1]
            while used.contains(key) {
                n += 1
                key = "\(name)_\(n)"
            }
            seen[name] = n
            used.insert(key)
            return key
        }
    }

    static func value(_ v: DBValue) -> String {
        switch v {
        case .null: "null"
        case .integer(let n): String(n)
        case .double(let d): d.isFinite ? String(d) : "null"
        case .bool(let b): b ? "true" : "false"
        case .text(let s): string(s)
        case .blob(let data): string(data.base64EncodedString())
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case _ where u.value < 0x20 || u == "\u{2028}" || u == "\u{2029}":
                out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

// MARK: - SQL

public struct SQLExportOptions: Codable, Hashable, Sendable {
    public var dropTable: Bool
    /// CREATE TABLE before the rows (tables only).
    public var includeStructure: Bool
    public var includeData: Bool
    public var rowsPerInsert: Int

    public init(dropTable: Bool = false, includeStructure: Bool = true, includeData: Bool = true, rowsPerInsert: Int = 100) {
        self.dropTable = dropTable
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.rowsPerInsert = max(1, rowsPerInsert)
    }
}

/// A script that recreates the rows: a header comment, optionally DROP and CREATE, then INSERTs of
/// up to `rowsPerInsert` rows each, with values written as the dialect's literals.
public struct SQLWriter: RowWriter {
    public var options: SQLExportOptions
    public let dialect: any Dialect
    public let table: TableRef
    /// The CREATE statements (ending in `;`), when the structure is included.
    public var createStatement: String?
    /// Where the rows came from, for the header comment.
    public var source: String
    public var date: Date

    private var columnList = ""
    private var pending: [String] = []

    public init(
        _ options: SQLExportOptions = SQLExportOptions(), dialect: any Dialect, table: TableRef,
        createStatement: String? = nil, source: String? = nil, date: Date = Date()
    ) {
        self.options = options
        self.dialect = dialect
        self.table = table
        self.createStatement = createStatement
        self.source = source ?? table.description
        self.date = date
    }

    public mutating func header(columns: [String]) -> String {
        columnList = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
        pending = []
        var out = """
            -- Exported by Tabula
            -- Source: \(source.replacingOccurrences(of: "\n", with: " "))
            -- Dialect: \(dialect.name)
            -- Date: \(date.ISO8601Format())


            """
        let name = dialect.qualified(table)
        if options.dropTable { out += "DROP TABLE IF EXISTS \(name);\n\n" }
        if options.includeStructure, let createStatement { out += createStatement + "\n\n" }
        return out
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        guard options.includeData else { return "" }
        var out = ""
        for row in rows {
            pending.append("(" + row.map(dialect.literal).joined(separator: ", ") + ")")
            if pending.count >= options.rowsPerInsert { out += flush() }
        }
        return out
    }

    public mutating func footer() -> String { flush() }

    private mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        defer { pending = [] }
        return "INSERT INTO \(dialect.qualified(table)) (\(columnList)) VALUES\n  " + pending.joined(separator: ",\n  ") + ";\n"
    }
}

// MARK: - Markdown

/// A Markdown table for pasting into notes. NULL shows as `NULL`; `|` is escaped and line breaks
/// become spaces so each row stays on one line.
public struct MarkdownWriter: RowWriter {
    public init() {}

    public mutating func header(columns: [String]) -> String {
        line(columns.map(cell)) + line(columns.map { _ in "---" })
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        rows.map { row in line(row.map { $0.isNull ? "NULL" : cell(markdownText($0)) }) }.joined()
    }

    public mutating func footer() -> String { "" }

    private func markdownText(_ v: DBValue) -> String {
        if case .blob(let d) = v { return CSVWriter.hex(d) }
        return v.displayString
    }

    private func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }

    private func cell(_ s: String) -> String {
        s.replacing(/\r\n|\r|\n/, with: " ").replacingOccurrences(of: "|", with: "\\|")
    }
}

/// An HTML table: a header row of `<th>`, then one `<tr>` per row. Text is escaped, line breaks
/// become `<br>`, NULL is an empty cell and blobs are hex.
public struct HTMLWriter: RowWriter {
    public init() {}

    public mutating func header(columns: [String]) -> String {
        "<table>\n<thead>\n<tr>" + columns.map { "<th>\(Self.escape($0))</th>" }.joined() + "</tr>\n</thead>\n<tbody>\n"
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        rows.map { row in
            "<tr>" + row.map { "<td>\(Self.text($0))</td>" }.joined() + "</tr>\n"
        }.joined()
    }

    public mutating func footer() -> String { "</tbody>\n</table>\n" }

    private static func text(_ v: DBValue) -> String {
        switch v {
        case .null: return ""
        case .blob(let d): return CSVWriter.hex(d)
        default: return escape(v.displayString).replacing(/\r\n|\r|\n/, with: "<br>")
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}

// MARK: - Copy Rows As

/// Formats for the grids' "Copy Rows As" menu.
public enum CopyFormat: String, CaseIterable, Sendable {
    case csv, json, sqlInsert, markdown, html

    public var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sqlInsert: "SQL INSERT"
        case .markdown: "Markdown Table"
        case .html: "HTML"
        }
    }

    /// `table` names the INSERT target; query results use `result` when there's no table.
    public func text(columns: [String], rows: [[DBValue]], dialect: any Dialect, table: TableRef?) -> String {
        switch self {
        case .csv:
            var w = CSVWriter()
            return w.document(columns: columns, rows: rows)
        case .json:
            var w = JSONWriter()
            return w.document(columns: columns, rows: rows)
        case .markdown:
            var w = MarkdownWriter()
            return w.document(columns: columns, rows: rows)
        case .html:
            var w = HTMLWriter()
            return w.document(columns: columns, rows: rows)
        case .sqlInsert:
            var w = SQLWriter(SQLExportOptions(includeStructure: false), dialect: dialect, table: table ?? TableRef("result"))
            _ = w.header(columns: columns)
            return w.rows(rows) + w.footer()
        }
    }
}
