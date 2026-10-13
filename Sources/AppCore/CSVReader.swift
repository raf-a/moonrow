import DBKit
import Foundation

/// One CSV field. `quoted` tells an empty string (`""`) from a missing value.
public struct CSVField: Sendable, Hashable {
    public var text: String
    public var quoted: Bool

    public init(_ text: String, quoted: Bool = false) {
        self.text = text
        self.quoted = quoted
    }
}

/// A parsed CSV file: an optional header and records of equal width.
public struct CSVDocument: Sendable {
    public var header: [String]?
    public var rows: [[CSVField]]
    /// The 1-based line each row starts on, for error messages.
    public var lines: [Int]
    /// The encoding the bytes were read with.
    public var encoding: CSVReader.Encoding
    public var delimiter: Character

    public var columnCount: Int { header?.count ?? rows.first?.count ?? 0 }

    /// Header names, or `column 1`, `column 2`, … without one.
    public var columnNames: [String] {
        header ?? (0..<columnCount).map { "column \($0 + 1)" }
    }
}

/// How to read CSV, as RFC 4180 describes it, with a one-byte (ASCII) delimiter and quote: quoted
/// fields may hold delimiters, line breaks and doubled quotes; lines end in LF, CRLF or CR.
public struct CSVReader: Sendable {
    public enum Encoding: String, Codable, Sendable, CaseIterable {
        /// UTF-8, or Windows-1252 when the bytes aren't valid UTF-8.
        case automatic, utf8, windowsCP1252, macOSRoman

        public var foundation: String.Encoding? {
            switch self {
            case .automatic: nil
            case .utf8: .utf8
            case .windowsCP1252: .windowsCP1252
            case .macOSRoman: .macOSRoman
            }
        }
    }

    /// Nil detects it from the first line.
    public var delimiter: Character?
    public var quote: Character
    public var firstLineIsHeader: Bool
    public var encoding: Encoding

    public init(delimiter: Character? = nil, quote: Character = "\"", firstLineIsHeader: Bool = true, encoding: Encoding = .automatic) {
        self.delimiter = delimiter
        self.quote = quote
        self.firstLineIsHeader = firstLineIsHeader
        self.encoding = encoding
    }

    /// The whole document in memory (tests, small files). Without a header the widest record
    /// sets the width. Imports read files a record at a time with `CSVRecordReader`.
    public func read(_ data: Data) throws -> CSVDocument {
        let reader = try CSVRecordReader(data: data, options: self, scan: nil)
        var rows: [[CSVField]] = []
        var lines: [Int] = []
        while let r = try reader.next() {
            rows.append(r.fields)
            lines.append(r.line)
        }
        return CSVDocument(header: firstLineIsHeader ? reader.columnNames : nil, rows: rows, lines: lines,
                           encoding: reader.encoding, delimiter: reader.delimiter)
    }

    /// The most frequent of `,` `;` tab `|` on the first line, outside quotes; `,` if none.
    public static func detectDelimiter(_ text: String, quote: Character = "\"") -> Character {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { CSVRecordReader.detectDelimiter($0, quote: quote.asciiValue ?? 34) }
    }
}
