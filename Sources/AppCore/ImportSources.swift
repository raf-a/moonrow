import DBKit
import Foundation

// Import files read a record at a time from a memory-mapped file, so a file of any size imports
// without being loaded: CSV (RFC 4180, any one-byte delimiter and quote) and JSON (an array of
// objects, or one object per line).

/// One record of an import file: its fields as text, and where it starts.
public struct ImportRecord: Sendable {
    public var fields: [CSVField]
    /// 1-based line of the file, for error messages.
    public var line: Int
}

/// Records from an import file, in order.
public protocol ImportRecords: AnyObject {
    /// The header's names (CSV) or the keys found (JSON); `column 1`, … for CSV without a header.
    var columnNames: [String] { get }
    /// Whether the names come from the file.
    var hasNames: Bool { get }
    /// The next record, with exactly `columnNames.count` fields; nil at the end.
    func next() throws -> ImportRecord?
    /// How far through the file reading is, 0…1.
    var fractionRead: Double { get }
}

extension ImportRecords {
    /// Up to `limit` records from here (the preview).
    public func take(_ limit: Int) throws -> [ImportRecord] {
        var out: [ImportRecord] = []
        while out.count < limit, let r = try next() { out.append(r) }
        return out
    }
}

/// How many records are looked at to size a CSV without a header, find JSON keys, and guess
/// column types for a new table.
public let importScanLimit = 10_000

enum ImportFile {
    /// The file mapped into memory rather than read.
    static func map(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Bytes after a UTF-8 byte-order mark.
    static func bodyStart(_ data: Data) -> Int {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    /// Whether `bytes` are valid UTF-8 (overlongs, surrogates and values past U+10FFFF refused).
    static func isUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            let length: Int
            var minimum: UInt32
            var value: UInt32
            switch b {
            case 0xC2...0xDF: length = 2; minimum = 0x80; value = UInt32(b & 0x1F)
            case 0xE0...0xEF: length = 3; minimum = 0x800; value = UInt32(b & 0x0F)
            case 0xF0...0xF4: length = 4; minimum = 0x10000; value = UInt32(b & 0x07)
            default: return false
            }
            guard i + length <= n else { return false }
            for k in 1..<length {
                let c = bytes[i + k]
                guard c & 0xC0 == 0x80 else { return false }
                value = value << 6 | UInt32(c & 0x3F)
            }
            guard value >= minimum, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return false }
            i += length
        }
        return true
    }
}

// MARK: - CSV

/// Reads CSV records from a file (or bytes) one at a time.
public final class CSVRecordReader: ImportRecords {
    public let options: CSVReader
    public let delimiter: Character
    public let encoding: CSVReader.Encoding
    public private(set) var columnNames: [String] = []
    public var hasNames: Bool { options.firstLineIsHeader }
    /// Fields per record: the header's, else the widest record among the first ones scanned.
    public private(set) var width = 0

    private let data: Data
    private let start: Int
    private var position: Int
    private var line = 1
    private let d: UInt8
    private let q: UInt8
    private let foundation: String.Encoding

    /// `scan` is how many records size a file without a header (nil: all of them).
    public init(data: Data, options: CSVReader, scan: Int? = importScanLimit) throws {
        self.data = data
        self.options = options
        let start = ImportFile.bodyStart(data)
        self.start = start
        position = start
        guard let quote = options.quote.asciiValue else { throw DatabaseError("The quote must be a single ASCII character.") }
        q = quote
        let detected = options.delimiter ?? data.withUnsafeBytes { Self.detectDelimiter(UnsafeRawBufferPointer(rebasing: $0[start...]), quote: quote) }
        guard let delim = detected.asciiValue else { throw DatabaseError("The delimiter must be a single ASCII character.") }
        guard delim != quote else { throw DatabaseError("The delimiter and the quote can't be the same character.") }
        guard delim != 10, delim != 13 else { throw DatabaseError("A line break can't be the delimiter.") }
        d = delim
        delimiter = detected
        switch options.encoding {
        case .automatic:
            let utf8 = data.withUnsafeBytes { ImportFile.isUTF8(UnsafeRawBufferPointer(rebasing: $0[start...])) }
            encoding = utf8 ? .utf8 : .windowsCP1252
        case let e:
            encoding = e
            if e == .utf8, !data.withUnsafeBytes({ ImportFile.isUTF8(UnsafeRawBufferPointer(rebasing: $0[start...])) }) {
                throw DatabaseError("The file isn't valid UTF-8 text.")
            }
        }
        foundation = encoding.foundation ?? .utf8

        if options.firstLineIsHeader, let header = try nextRaw() {
            columnNames = header.fields.map(\.text)
            width = columnNames.count
        } else {
            // Without a header, the widest of the first records sets the width.
            let mark = (position, line)
            var widest = 0
            var seen = 0
            while scan.map({ seen < $0 }) ?? true, let r = try nextRaw() {
                widest = max(widest, r.fields.count)
                seen += 1
            }
            (position, line) = mark
            width = widest
            columnNames = (0..<widest).map { "column \($0 + 1)" }
        }
    }

    public convenience init(url: URL, options: CSVReader) throws {
        try self.init(data: try ImportFile.map(url), options: options)
    }

    public var fractionRead: Double {
        data.count <= start ? 1 : Double(position - start) / Double(data.count - start)
    }

    /// The next record, padded with missing (NULL) fields or cut to the width.
    public func next() throws -> ImportRecord? {
        guard var r = try nextRaw() else { return nil }
        if r.fields.count < width {
            r.fields += Array(repeating: CSVField(""), count: width - r.fields.count)
        } else if r.fields.count > width {
            r.fields.removeLast(r.fields.count - width)
        }
        return r
    }

    /// The next record as it is in the file; blank lines are skipped.
    func nextRaw() throws -> ImportRecord? {
        try data.withUnsafeBytes { raw -> ImportRecord? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var fields: [CSVField] = []
            var field: [UInt8] = []
            var quoted = false
            var inQuotes = false
            var started = false
            var recordLine = line
            var i = position

            func endField() {
                fields.append(CSVField(decode(field), quoted: quoted))
                field.removeAll(keepingCapacity: true)
                quoted = false
            }

            while i < n {
                let b = bytes[i]
                i += 1
                if inQuotes {
                    if b == q {
                        if i < n, bytes[i] == q {
                            field.append(q)
                            i += 1
                        } else {
                            inQuotes = false
                        }
                    } else {
                        if b == 10 || (b == 13 && !(i < n && bytes[i] == 10)) { line += 1 }
                        field.append(b)
                    }
                    continue
                }
                switch b {
                case q:
                    // A quote opens a quoted field only at its start; elsewhere it's text.
                    if field.isEmpty, !quoted {
                        inQuotes = true
                        quoted = true
                        if !started { recordLine = line }
                        started = true
                    } else {
                        field.append(b)
                    }
                case d:
                    if !started { recordLine = line }
                    started = true
                    endField()
                case 10, 13:
                    if b == 13, i < n, bytes[i] == 10 { i += 1 }
                    line += 1
                    if started {
                        endField()
                        position = i
                        return ImportRecord(fields: fields, line: recordLine)
                    }
                    recordLine = line
                default:
                    if !started { recordLine = line }
                    started = true
                    field.append(b)
                }
            }
            position = i
            if inQuotes { throw DatabaseError("A quoted field that starts on line \(recordLine) is never closed.") }
            guard started else { return nil }
            endField()
            return ImportRecord(fields: fields, line: recordLine)
        }
    }

    private func decode(_ bytes: [UInt8]) -> String {
        if foundation == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        return String(bytes: bytes, encoding: foundation) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// The most frequent of `,` `;` tab `|` on the first line, outside quotes; `,` if none.
    static func detectDelimiter(_ bytes: UnsafeRawBufferPointer, quote: UInt8) -> Character {
        var counts: [UInt8: Int] = [:]
        var inQuotes = false
        for b in bytes {
            if b == quote { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if b == 10 || b == 13 { break }
            if [44, 59, 9, 124].contains(b) { counts[b, default: 0] += 1 }
        }
        let order: [UInt8] = [44, 59, 9, 124]
        let best = order.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? 44
        return counts[best, default: 0] > 0 ? Character(UnicodeScalar(best)) : ","
    }
}

// MARK: - JSON

/// Reads objects from a JSON array (`[{…}, {…}]`) or JSON Lines (one object per line), in
/// UTF-8. Columns are the keys of the first objects scanned, in the order first seen; keys that
/// only appear later aren't imported. Values become fields: strings as text (quoted), numbers as
/// written, true / false, null as NULL, and nested objects and arrays as their JSON text.
public final class JSONRecordReader: ImportRecords {
    public private(set) var columnNames: [String] = []
    public var hasNames: Bool { true }
    /// Keys found after the scan that aren't columns, for the import's summary.
    public private(set) var skippedKeys: Set<String> = []

    private let data: Data
    private let start: Int
    private var position: Int
    private var line = 1
    private var isArray = false
    private var finished = false
    private var count = 0
    private var index: [String: Int] = [:]

    public init(data: Data, scan: Int? = importScanLimit) throws {
        self.data = data
        let start = ImportFile.bodyStart(data)
        self.start = start
        position = start
        guard data.withUnsafeBytes({ ImportFile.isUTF8(UnsafeRawBufferPointer(rebasing: $0[start...])) }) else {
            throw DatabaseError("The file isn't valid UTF-8 text; JSON files must be.")
        }
        skipSpace()
        switch peek() {
        case UInt8(ascii: "["):
            isArray = true
            position += 1
        case UInt8(ascii: "{"):
            break
        case nil:
            finished = true
        default:
            throw DatabaseError("The file isn't a JSON array of objects (or one object per line).")
        }
        // The keys of the first objects, in the order first seen.
        let mark = (position, line, finished, count)
        var seen = 0
        while scan.map({ seen < $0 }) ?? true, let object = try nextObject() {
            for (key, _) in object.pairs where index[key] == nil {
                index[key] = columnNames.count
                columnNames.append(key)
            }
            seen += 1
        }
        (position, line, finished, count) = mark
    }

    public convenience init(url: URL) throws {
        try self.init(data: try ImportFile.map(url))
    }

    public var fractionRead: Double {
        data.count <= start ? 1 : Double(position - start) / Double(data.count - start)
    }

    public func next() throws -> ImportRecord? {
        guard let object = try nextObject() else { return nil }
        var fields = Array(repeating: CSVField(""), count: columnNames.count)
        for (key, value) in object.pairs {
            if let i = index[key] { fields[i] = value } else { skippedKeys.insert(key) }
        }
        return ImportRecord(fields: fields, line: object.line)
    }

    // MARK: Parsing

    private func peek() -> UInt8? {
        position < data.count ? data[data.startIndex + position] : nil
    }

    private func skipSpace() {
        data.withUnsafeBytes { raw in
            while position < raw.count {
                let b = raw[position]
                if b == 10 { line += 1 } else if b != 32, b != 9, b != 13 { break }
                position += 1
            }
        }
    }

    private func fail(_ what: String) -> DatabaseError {
        DatabaseError("The JSON is malformed on line \(line): \(what).")
    }

    private func nextObject() throws -> (pairs: [(String, CSVField)], line: Int)? {
        guard !finished else { return nil }
        skipSpace()
        if isArray {
            if count > 0 {
                guard let b = peek() else { throw fail("the array isn't closed") }
                if b == UInt8(ascii: "]") { return close() }
                guard b == UInt8(ascii: ",") else { throw fail("expected , or ] after item \(count)") }
                position += 1
                skipSpace()
            } else if peek() == UInt8(ascii: "]") {
                return close()
            }
        } else if peek() == nil {
            finished = true
            return nil
        }
        guard peek() == UInt8(ascii: "{") else { throw fail("item \(count + 1) isn't an object") }
        let objectLine = line
        position += 1
        var pairs: [(String, CSVField)] = []
        skipSpace()
        if peek() == UInt8(ascii: "}") {
            position += 1
        } else {
            while true {
                skipSpace()
                guard peek() == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try string()
                skipSpace()
                guard peek() == UInt8(ascii: ":") else { throw fail("expected : after \"\(key)\"") }
                position += 1
                skipSpace()
                pairs.append((key, try value()))
                skipSpace()
                guard let b = peek() else { throw fail("an object isn't closed") }
                position += 1
                if b == UInt8(ascii: "}") { break }
                guard b == UInt8(ascii: ",") else { throw fail("expected , or } in an object") }
            }
        }
        count += 1
        return (pairs, objectLine)
    }

    private func close() -> (pairs: [(String, CSVField)], line: Int)? {
        position += 1
        finished = true
        return nil
    }

    private func value() throws -> CSVField {
        guard let b = peek() else { throw fail("a value is missing") }
        switch b {
        case UInt8(ascii: "\""):
            return CSVField(try string(), quoted: true)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let from = position
            try skipNested()
            return CSVField(compact(from..<position), quoted: true)
        case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
            for word in ["true", "false", "null"] where matches(word) {
                position += word.utf8.count
                return word == "null" ? CSVField("") : CSVField(word)
            }
            throw fail("unknown value")
        default:
            let from = position
            data.withUnsafeBytes { raw in
                while position < raw.count, "+-0123456789.eE".utf8.contains(raw[position]) { position += 1 }
            }
            let text = String(decoding: data[(data.startIndex + from)..<(data.startIndex + position)], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else { throw fail("unexpected character") }
            return CSVField(text)
        }
    }

    private func matches(_ word: String) -> Bool {
        let bytes = Array(word.utf8)
        guard position + bytes.count <= data.count else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            bytes.indices.allSatisfy { raw[position + $0] == bytes[$0] }
        }
    }

    /// A string's text; `position` is on its opening quote.
    private func string() throws -> String {
        try data.withUnsafeBytes { raw -> String in
            position += 1
            var out: [UInt8] = []
            while position < raw.count {
                let b = raw[position]
                position += 1
                switch b {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard position < raw.count else { break }
                    let e = raw[position]
                    position += 1
                    switch e {
                    case UInt8(ascii: "n"): out.append(10)
                    case UInt8(ascii: "t"): out.append(9)
                    case UInt8(ascii: "r"): out.append(13)
                    case UInt8(ascii: "b"): out.append(8)
                    case UInt8(ascii: "f"): out.append(12)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4(raw)
                        if (0xD800...0xDBFF).contains(scalar), position + 1 < raw.count,
                           raw[position] == UInt8(ascii: "\\"), raw[position + 1] == UInt8(ascii: "u") {
                            position += 2
                            let low = try hex4(raw)
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
                            }
                        }
                        out.append(contentsOf: String(UnicodeScalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8)
                    default: out.append(e)
                    }
                case 10:
                    line += 1
                    out.append(b)
                default:
                    out.append(b)
                }
            }
            throw fail("a string isn't closed")
        }
    }

    private func hex4(_ raw: UnsafeRawBufferPointer) throws -> UInt32 {
        guard position + 4 <= raw.count,
              let v = UInt32(String(decoding: UnsafeRawBufferPointer(rebasing: raw[position..<(position + 4)]), as: UTF8.self), radix: 16) else {
            throw fail("a \\u escape is malformed")
        }
        position += 4
        return v
    }

    /// Skips an object or array, strings included.
    private func skipNested() throws {
        try data.withUnsafeBytes { raw in
            var depth = 0
            var inString = false
            while position < raw.count {
                let b = raw[position]
                position += 1
                if inString {
                    if b == UInt8(ascii: "\\") { position += 1 } else if b == UInt8(ascii: "\"") { inString = false } else if b == 10 { line += 1 }
                    continue
                }
                switch b {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return }
                case 10: line += 1
                default: break
                }
            }
            throw fail("a nested value isn't closed")
        }
    }

    /// Nested JSON text without the whitespace between tokens.
    private func compact(_ range: Range<Int>) -> String {
        data.withUnsafeBytes { raw in
            var out: [UInt8] = []
            var inString = false
            var escaped = false
            for i in range {
                let b = raw[i]
                if inString {
                    out.append(b)
                    if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                } else if b == UInt8(ascii: "\"") {
                    inString = true
                    out.append(b)
                } else if ![32, 9, 10, 13].contains(b) {
                    out.append(b)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

/// A CSV document already in memory, as records.
final class DocumentRecords: ImportRecords {
    let document: CSVDocument
    private var index = 0

    init(_ document: CSVDocument) {
        self.document = document
    }

    var columnNames: [String] { document.columnNames }
    var hasNames: Bool { document.header != nil }
    var fractionRead: Double { document.rows.isEmpty ? 1 : Double(index) / Double(document.rows.count) }

    func next() throws -> ImportRecord? {
        guard index < document.rows.count else { return nil }
        defer { index += 1 }
        return ImportRecord(fields: document.rows[index], line: document.lines[index])
    }
}
