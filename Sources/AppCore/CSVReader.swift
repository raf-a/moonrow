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

/// Reads CSV as RFC 4180 describes it, with any single-character delimiter and quote: quoted
/// fields may hold delimiters, line breaks and doubled quotes; lines end in LF, CRLF or CR.
/// The whole file is read into memory.
public struct CSVReader: Sendable {
    public enum Encoding: String, Codable, Sendable, CaseIterable {
        /// UTF-8, or Windows-1252 when the bytes aren't valid UTF-8.
        case automatic, utf8, windowsCP1252, macOSRoman

        var foundation: String.Encoding? {
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

    public func read(_ data: Data) throws -> CSVDocument {
        let (text, used) = try decode(data)
        let delimiter = self.delimiter ?? Self.detectDelimiter(text, quote: quote)
        var (records, lines) = try parse(text, delimiter: delimiter)
        var header: [String]?
        if firstLineIsHeader, !records.isEmpty {
            header = records.removeFirst().map(\.text)
            lines.removeFirst()
        }
        // Ragged rows: padded with missing (NULL) fields or cut to the header's width; without a
        // header, to the widest row.
        let width = header?.count ?? records.map(\.count).max() ?? 0
        for i in records.indices where records[i].count != width {
            if records[i].count < width {
                records[i] += Array(repeating: CSVField(""), count: width - records[i].count)
            } else {
                records[i].removeLast(records[i].count - width)
            }
        }
        return CSVDocument(header: header, rows: records, lines: lines, encoding: used, delimiter: delimiter)
    }

    private func decode(_ data: Data) throws -> (String, Encoding) {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let e = encoding.foundation {
            guard let s = String(data: bytes, encoding: e) else {
                throw DatabaseError("The file isn't valid \(encoding.rawValue) text.")
            }
            return (s, encoding)
        }
        if let s = String(data: bytes, encoding: .utf8) { return (s, .utf8) }
        guard let s = String(data: bytes, encoding: .windowsCP1252) else { throw DatabaseError("The file's text encoding wasn't recognized.") }
        return (s, .windowsCP1252)
    }

    /// The most frequent of `,` `;` tab `|` on the first line, outside quotes; `,` if none.
    public static func detectDelimiter(_ text: String, quote: Character = "\"") -> Character {
        var counts: [Character: Int] = [:]
        var inQuotes = false
        let q = quote.unicodeScalars.first!
        for u in text.unicodeScalars {
            if u == q { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if u == "\n" || u == "\r" { break }
            let c = Character(u)
            if [",", ";", "\t", "|"].contains(c) { counts[c, default: 0] += 1 }
        }
        let order: [Character] = [",", ";", "\t", "|"]
        return order.max { counts[$0, default: 0] < counts[$1, default: 0] }.flatMap { counts[$0, default: 0] > 0 ? $0 : nil } ?? ","
    }

    private func parse(_ text: String, delimiter: Character) throws -> ([[CSVField]], [Int]) {
        guard let d = delimiter.unicodeScalars.first, delimiter.unicodeScalars.count == 1,
              let q = quote.unicodeScalars.first, quote.unicodeScalars.count == 1 else {
            throw DatabaseError("The delimiter and quote must be single characters.")
        }
        guard d != q else { throw DatabaseError("The delimiter and the quote can't be the same character.") }
        var records: [[CSVField]] = []
        var lines: [Int] = []
        var record: [CSVField] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var inQuotes = false
        var line = 1
        var recordLine = 1
        // Whether anything (even an empty quoted field) was read on this record.
        var started = false

        func endField() {
            record.append(CSVField(String(field), quoted: quoted))
            field = String.UnicodeScalarView()
            quoted = false
        }
        func endRecord() {
            if started {
                endField()
                records.append(record)
                lines.append(recordLine)
            }
            record = []
            started = false
        }

        var it = text.unicodeScalars.makeIterator()
        var next = it.next()
        while let u = next {
            next = it.next()
            if inQuotes {
                if u == q {
                    if next == q {
                        field.append(q)
                        next = it.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    if u == "\n" || (u == "\r" && next != "\n") { line += 1 }
                    field.append(u)
                }
                continue
            }
            switch u {
            case q:
                // A quote opens a quoted field only at its start; elsewhere it's text.
                if field.isEmpty, !quoted {
                    inQuotes = true
                    quoted = true
                    started = true
                } else {
                    field.append(u)
                }
            case d:
                started = true
                endField()
            case "\r", "\n":
                if u == "\r", next == "\n" { next = it.next() }
                endRecord()
                line += 1
                recordLine = line
            default:
                if !started { recordLine = line }
                started = true
                field.append(u)
            }
        }
        if inQuotes { throw DatabaseError("A quoted field that starts on line \(recordLine) is never closed.") }
        endRecord()
        return (records, lines)
    }
}
