import DBKit
import Foundation
import SQLScript

/// Bytes of a file, plain or gzip-compressed (told apart by its first bytes), a piece at a time.
public final class FileBytes {
    private let mapped: Data?
    private var offset = 0
    private let gzip: GzipReader?
    let size: Int64
    private static let chunk = 1 << 20

    public init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 2) ?? Data()
        try handle.close()
        if GzipReader.isGzip(head) {
            gzip = try GzipReader(url: url)
            mapped = nil
        } else {
            gzip = nil
            mapped = try ImportFile.map(url)
        }
    }

    public var isCompressed: Bool { gzip != nil }

    public func read() throws -> Data? {
        if let gzip { return try gzip.next() }
        guard let mapped, offset < mapped.count else { return nil }
        let end = min(mapped.count, offset + Self.chunk)
        defer { offset = end }
        return mapped.subdata(in: (mapped.startIndex + offset)..<(mapped.startIndex + end))
    }

    /// How far through the file (compressed bytes for gzip), 0…1.
    var fraction: Double {
        guard size > 0 else { return 1 }
        return Double(gzip?.bytesRead ?? Int64(offset)) / Double(size)
    }
}

/// Reads a SQL script or dump a statement at a time, so a file of any size runs without being
/// loaded: plain or gzip-compressed, split with the query editor's rules (`$$` bodies,
/// `DELIMITER`, MySQL's `/*!…*/` code). Postgres dumps get psql's two extras: `\` commands
/// (`\connect`, `\restrict`) are reported and skipped, and a `COPY … FROM stdin;` is followed by
/// its data, up to the `\.` line, which `copyData()` hands out.
public final class SQLDumpReader {
    public enum Item: Sendable, Equatable {
        case statement(String, line: Int)
        /// A `COPY … FROM stdin`; read its data with `copyData()` before the next item.
        case copy(String, line: Int)
        /// A psql command (`\connect db`) that isn't SQL.
        case skipped(String, line: Int)
    }

    private let bytes: FileBytes
    private let dialect: LexerDialect
    private let psql: Bool
    private let encoding: String.Encoding
    private var buffer = ""
    private var pendingBytes = Data()
    private var atEnd = false
    /// The line `buffer` starts on.
    private var line = 1
    private var delimiter = ";"
    private var queue: [Item] = []
    private var queued = 0
    private var inCopy = false

    /// `psql`: the file is for Postgres (backslash commands, COPY data).
    public init(url: URL, dialect: LexerDialect, psql: Bool, encoding: String.Encoding = .utf8) throws {
        bytes = try FileBytes(url: url)
        self.dialect = dialect
        self.psql = psql
        self.encoding = encoding
    }

    public var fractionRead: Double { bytes.fraction }
    public var isCompressed: Bool { bytes.isCompressed }

    /// Appends the next piece of the file to the buffer; false at the end.
    private func load() throws -> Bool {
        guard !atEnd else { return false }
        guard let data = try bytes.read() else {
            atEnd = true
            if !pendingBytes.isEmpty {
                buffer += String(decoding: pendingBytes, as: UTF8.self)
                pendingBytes = Data()
            }
            return false
        }
        var piece = pendingBytes + data
        pendingBytes = Data()
        if encoding == .utf8 {
            // Keep a character cut at the end for the next piece.
            var cut = piece.count
            var back = 0
            while back < 3, cut > 0, piece[piece.startIndex + cut - 1] & 0xC0 == 0x80 { cut -= 1; back += 1 }
            if cut > 0, piece[piece.startIndex + cut - 1] >= 0xC0 {
                let lead = piece[piece.startIndex + cut - 1]
                let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
                if back + 1 < length {
                    pendingBytes = piece.subdata(in: (piece.startIndex + cut - 1)..<piece.endIndex)
                    piece = piece.subdata(in: piece.startIndex..<(piece.startIndex + cut - 1))
                }
            }
            if buffer.isEmpty, line == 1, piece.starts(with: [0xEF, 0xBB, 0xBF]) { piece = piece.dropFirst(3) }
            buffer += String(decoding: piece, as: UTF8.self)
        } else {
            buffer += String(data: piece, encoding: encoding) ?? String(decoding: piece, as: UTF8.self)
        }
        return true
    }

    /// The next item; nil at the end of the file.
    public func next() throws -> Item? {
        if inCopy {
            // The data wasn't read: skip it.
            while try copyData() != nil {}
        }
        while queued == queue.count {
            queue.removeAll(keepingCapacity: true)
            queued = 0
            if try !fill() { return nil }
        }
        let item = queue[queued]
        queued += 1
        if case .copy = item { inCopy = true }
        return item
    }

    /// Splits what's buffered into items, reading more when no statement is complete yet.
    /// False when the file is done.
    private func fill() throws -> Bool {
        while true {
            if buffer.isEmpty, atEnd { return false }
            if buffer.utf16.count < 1 << 16, !atEnd { if try load() { continue } }
            let statements = SQLSplitter.split(buffer, dialect: dialect, delimiter: delimiter)
            // The last statement may go on in the next piece, unless the file is done.
            let complete = atEnd ? statements : Array(statements.dropLast())
            if complete.isEmpty {
                if atEnd {
                    // Only comments and blanks left.
                    buffer = ""
                    return false
                }
                // A statement longer than what's read: read as much again, so a huge statement
                // isn't split over and over.
                let target = buffer.utf16.count * 2
                while buffer.utf16.count < target, try load() {}
                continue
            }
            var consumed = 0   // UTF-16 offset in buffer
            let units = Array(buffer.utf16)
            // Lines counted as far as `counted`, moving forward only.
            var counted = 0
            var lines = 0
            func lineAt(_ offset: Int) -> Int {
                lines += lineCount(units, from: counted, to: offset)
                counted = max(counted, offset)
                return line + lines
            }
            for statement in complete {
                let text = statement.text
                let start = statement.range.lowerBound
                let code = Self.codeStart(text)
                let codeOffset = start + code.utf16Offset
                let lineNumber = lineAt(codeOffset)
                if psql, code.text.hasPrefix("\\") {
                    // A psql command runs to the end of its line; what follows is read again.
                    var end = codeOffset
                    while end < units.count, units[end] != 10 { end += 1 }
                    let command = String(decoding: units[codeOffset..<end], as: UTF16.self).trimmingCharacters(in: .whitespaces)
                    queue.append(.skipped(command, line: lineNumber))
                    consumed = min(units.count, end + 1)
                    delimiter = statement.delimiter
                    break
                }
                if psql, Self.isCopyFromStdin(code.text) {
                    queue.append(.copy(String(code.text), line: lineNumber))
                    // The data starts on the line after the statement's delimiter.
                    var end = statement.fullRange.upperBound
                    while end < units.count, units[end] != 10 { end += 1 }
                    consumed = min(units.count, end + 1)
                    delimiter = statement.delimiter
                    break
                }
                queue.append(.statement(text, line: lineNumber))
                consumed = statement.fullRange.upperBound
                delimiter = statement.delimiter
            }
            if consumed == 0 { consumed = complete.last!.fullRange.upperBound }
            line = lineAt(consumed)
            buffer = String(decoding: units[consumed...], as: UTF16.self)
            return true
        }
    }

    private func lineCount(_ units: [UInt16], from: Int, to: Int) -> Int {
        var n = 0
        for i in from..<min(to, units.count) where units[i] == 10 { n += 1 }
        return n
    }

    /// The text after leading comments and blanks, and where it starts (UTF-16).
    static func codeStart(_ text: String) -> (text: Substring, utf16Offset: Int) {
        var rest = text[...]
        while true {
            let trimmed = rest.drop { $0.isWhitespace }
            if trimmed.hasPrefix("--") {
                rest = trimmed.drop { $0 != "\n" }
            } else if trimmed.hasPrefix("/*"), !trimmed.hasPrefix("/*!"), let close = trimmed.range(of: "*/") {
                rest = trimmed[close.upperBound...]
            } else {
                rest = trimmed
                break
            }
        }
        return (rest, text.utf16.distance(from: text.startIndex, to: rest.startIndex))
    }

    static func isCopyFromStdin(_ code: Substring) -> Bool {
        code.prefixMatch(of: /(?i)COPY\s/) != nil && code.firstMatch(of: /(?i)\bFROM\s+STDIN\b/) != nil
    }

    /// The next piece of the current COPY's data (whole lines, UTF-8), nil once its `\.` line
    /// is reached.
    public func copyData() throws -> Data? {
        guard inCopy else { return nil }
        while true {
            let u = Array(buffer.utf8)
            if let (dataEnd, resume) = Self.terminator(in: u, atEnd: atEnd) {
                let data = u[..<dataEnd]
                line += Self.newlines(u[..<resume])
                buffer = String(decoding: u[resume...], as: UTF8.self)
                inCopy = false
                return data.isEmpty ? nil : Data(data)
            }
            // Hand out the complete lines; a partial last line might still become `\.`.
            if u.count >= 1 << 20 || atEnd, let lastNewline = u.lastIndex(of: 10) {
                let piece = u[...lastNewline]
                line += Self.newlines(piece)
                buffer = String(decoding: u[(lastNewline + 1)...], as: UTF8.self)
                return Data(piece)
            }
            if try !load() {
                // No `\.`: the data runs to the end of the file, as psql would read it.
                inCopy = false
                buffer = ""
                return u.isEmpty ? nil : Data(u)
            }
        }
    }

    private static func newlines(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    /// Where the data before a `\.` line ends, and where reading resumes after that line. The
    /// buffer starts at the beginning of a line.
    static func terminator(in u: [UInt8], atEnd: Bool) -> (Int, Int)? {
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "\\"), i + 1 < u.count, u[i + 1] == UInt8(ascii: ".") {
                let after = i + 2
                if after == u.count, atEnd { return (i, after) }
                if after < u.count, u[after] == 10 { return (i, after + 1) }
                if after + 1 < u.count, u[after] == 13, u[after + 1] == 10 { return (i, after + 2) }
            }
            // The next line.
            guard let nl = u[i...].firstIndex(of: 10) else { return nil }
            i = nl + 1
        }
        return nil
    }
}

/// Runs a SQL file statement by statement on a connection (a session of its own), with
/// progress and Stop. Statements aren't wrapped in a transaction: a dump brings its own, and
/// MySQL can't roll DDL back anyway. The first error stops the run, unless `continueOnError`.
public struct SQLFileImport: Sendable {
    public struct Progress: Sendable {
        public var statements: Int
        public var failed: Int
        public var fraction: Double
        /// The statement running, on one line and cut short.
        public var current: String
    }

    public struct Summary: Sendable {
        public var statements: Int
        public var failed: [String]
        public var skipped: [String]
    }

    public var url: URL
    public var encoding: String.Encoding
    public var continueOnError: Bool

    public init(url: URL, encoding: String.Encoding = .utf8, continueOnError: Bool = false) {
        self.url = url
        self.encoding = encoding
        self.continueOnError = continueOnError
    }

    static func lexer(for dialect: any Dialect) -> (LexerDialect, Bool) {
        if dialect is PostgresDialect { return (.postgres, true) }
        if dialect is MySQLDialect { return (.mysql, false) }
        return (.sqlite, false)
    }

    /// The first statements, for safe mode and the sheet's preview.
    public func firstStatements(_ count: Int, dialect: any Dialect) throws -> [String] {
        let (lexer, psql) = Self.lexer(for: dialect)
        let reader = try SQLDumpReader(url: url, dialect: lexer, psql: psql, encoding: encoding)
        var out: [String] = []
        while out.count < count, let item = try reader.next() {
            switch item {
            case .statement(let s, _), .copy(let s, _): out.append(s + ";")
            case .skipped: continue
            }
        }
        return out
    }

    @discardableResult
    public func run(on connection: any DatabaseConnection, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Summary {
        let dialect = connection.dialect
        let (lexer, psql) = Self.lexer(for: dialect)
        let reader = UncheckedBox(try SQLDumpReader(url: url, dialect: lexer, psql: psql, encoding: encoding))
        var packetLimit: Int?
        if dialect is MySQLDialect, case .integer(let n)? = try? await connection.execute("SELECT @@max_allowed_packet").rows.first?.first {
            packetLimit = Int(n)
        }
        var summary = Summary(statements: 0, failed: [], skipped: [])
        func report(_ text: String) {
            progress(Progress(statements: summary.statements, failed: summary.failed.count, fraction: reader.value.fractionRead,
                              current: Self.oneLine(text)))
        }
        while let item = try reader.value.next() {
            try Task.checkCancellation()
            switch item {
            case .skipped(let command, let line):
                summary.skipped.append("line \(line): \(command)")
            case .statement(let sql, let line):
                report(sql)
                do {
                    if let packetLimit, sql.utf8.count + 1 > packetLimit {
                        throw DatabaseError("The statement is \(Self.megabytes(sql.utf8.count)), more than the server's max_allowed_packet (\(Self.megabytes(packetLimit))).")
                    }
                    _ = try await connection.execute(SQLStatement(sql))
                } catch let error as DatabaseError {
                    try fail(error, line: line, sql: sql, summary: &summary)
                }
                summary.statements += 1
            case .copy(let sql, let line):
                report(sql)
                let source: CopySource = { try reader.value.copyData() }
                do {
                    _ = try await connection.copyIn(sql, from: source)
                } catch let error as DatabaseError {
                    try fail(error, line: line, sql: sql, summary: &summary)
                }
                summary.statements += 1
            }
            report("")
        }
        return summary
    }

    private func fail(_ error: DatabaseError, line: Int, sql: String, summary: inout Summary) throws {
        let what = "Line \(line): \(error.message)"
        guard continueOnError else {
            var e = error
            e.message = "\(what) (\(summary.statements) statement\(summary.statements == 1 ? "" : "s") ran before it.)"
            e.sql = sql.count > 2000 ? String(sql.prefix(2000)) + " …" : sql
            throw e
        }
        summary.failed.append(what)
    }

    static func oneLine(_ sql: String) -> String {
        let flat = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
