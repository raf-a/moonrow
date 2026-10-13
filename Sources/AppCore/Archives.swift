import DBKit
import Foundation
import zlib

// Gzip and zip, written and read with zlib, so export,
// backup and import need no external tool: `.sql.gz` exports, gzipped dumps, and the zip
// container an XLSX workbook is.

// MARK: - CRC-32

/// CRC-32 as gzip and zip use it (zlib's).
public struct CRC32: Sendable {
    public private(set) var value: UInt32 = 0

    public init() {}

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        value = UInt32(zlib.crc32(uLong(value), base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}

// MARK: - zlib

/// A zlib stream in one direction. `windowBits` picks the wrapping: -15 raw DEFLATE (zip),
/// 31 gzip when compressing, 47 gzip or zlib (detected) when decompressing.
final class ZStream {
    private var stream = z_stream()
    private let compressing: Bool
    private static let bufferSize = 64 * 1024

    init(compress: Bool, windowBits: Int32, level: Int32 = 6) throws {
        compressing = compress
        let size = Int32(MemoryLayout<z_stream>.size)
        let status = compress
            ? deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size)
            : inflateInit2_(&stream, windowBits, ZLIB_VERSION, size)
        guard status == Z_OK else { throw DatabaseError("Couldn't start zlib (\(status)).") }
    }

    deinit {
        if compressing { deflateEnd(&stream) } else { inflateEnd(&stream) }
    }

    /// Compresses `input`; `finish` writes the end of the stream.
    func compress(_ input: UnsafeRawBufferPointer, finish: Bool, output: (UnsafeRawBufferPointer) throws -> Void) throws {
        let out = UnsafeMutablePointer<Bytef>.allocate(capacity: Self.bufferSize)
        defer { out.deallocate() }
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        while true {
            stream.next_out = out
            stream.avail_out = uInt(Self.bufferSize)
            let status = deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                throw DatabaseError("Compressing failed (\(status)).")
            }
            let produced = Self.bufferSize - Int(stream.avail_out)
            if produced > 0 { try output(UnsafeRawBufferPointer(start: out, count: produced)) }
            if finish ? status == Z_STREAM_END : (stream.avail_in == 0 && stream.avail_out > 0) { return }
        }
    }

    /// Decompresses from `input` until it's used up or the stream ends. Returns how many bytes
    /// were used and whether the stream ended (bytes after its end are left).
    func decompress(_ input: UnsafeRawBufferPointer, output: (UnsafeRawBufferPointer) throws -> Void) throws -> (used: Int, ended: Bool) {
        let out = UnsafeMutablePointer<Bytef>.allocate(capacity: Self.bufferSize)
        defer { out.deallocate() }
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        while true {
            stream.next_out = out
            stream.avail_out = uInt(Self.bufferSize)
            let status = inflate(&stream, Z_NO_FLUSH)
            let produced = Self.bufferSize - Int(stream.avail_out)
            if produced > 0 { try output(UnsafeRawBufferPointer(start: out, count: produced)) }
            switch status {
            case Z_STREAM_END:
                return (input.count - Int(stream.avail_in), true)
            case Z_OK, Z_BUF_ERROR:
                if stream.avail_in == 0 && stream.avail_out > 0 { return (input.count, false) }
            case Z_DATA_ERROR:
                throw DatabaseError("The compressed data is damaged.")
            default:
                throw DatabaseError("Decompressing failed (\(status)).")
            }
        }
    }

    /// Ready for another stream (the next member of a gzip file).
    func reset() {
        if compressing { deflateReset(&stream) } else { inflateReset(&stream) }
    }
}

// MARK: - Gzip

/// Writes a gzip file (RFC 1952) a piece at a time.
public final class GzipWriter: TextSink {
    private let handle: FileHandle
    private let zstream: ZStream
    private var buffer = Data()
    private var closed = false
    private static let chunk = 256 * 1024

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseError("Couldn't create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        zstream = try ZStream(compress: true, windowBits: 31)
    }

    public func write(_ text: String) throws { try write(Data(text.utf8)) }

    public func write(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= Self.chunk { try flush(finish: false) }
    }

    private func flush(finish: Bool) throws {
        var out = Data()
        try buffer.withUnsafeBytes { try zstream.compress($0, finish: finish) { out.append(contentsOf: $0) } }
        buffer.removeAll(keepingCapacity: true)
        if !out.isEmpty { try handle.write(contentsOf: out) }
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try flush(finish: true)
        try handle.close()
    }
}

/// Reads gzip data (one member or several concatenated, as `cat a.gz b.gz` makes) a chunk at a
/// time. zlib checks each member's CRC and size.
public final class GzipReader {
    private let handle: FileHandle
    private var input = Data()
    private var atEnd = false
    private let zstream: ZStream
    private var done = false
    /// Compressed bytes read from the file so far, for progress.
    public private(set) var bytesRead: Int64 = 0
    private static let chunk = 256 * 1024

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        zstream = try ZStream(compress: false, windowBits: 15 + 16)
    }

    deinit { try? handle.close() }

    /// Whether `data` starts like gzip.
    public static func isGzip(_ prefix: Data) -> Bool {
        prefix.count >= 2 && prefix[prefix.startIndex] == 0x1F && prefix[prefix.startIndex + 1] == 0x8B
    }

    private func fill(_ count: Int = 1) throws {
        while input.count < count, !atEnd {
            let more = try handle.read(upToCount: Self.chunk) ?? Data()
            if more.isEmpty { atEnd = true } else { input.append(more); bytesRead += Int64(more.count) }
        }
    }

    /// The next piece of decompressed data; nil at the end.
    public func next() throws -> Data? {
        while !done {
            try fill()
            if input.isEmpty {
                throw DatabaseError("The gzip file ends too early.")
            }
            var out = Data()
            let (used, ended) = try input.withUnsafeBytes { try zstream.decompress($0) { out.append(contentsOf: $0) } }
            input.removeFirst(used)
            if ended {
                // Another member may follow; anything else after the end (zero padding) is ignored.
                try fill(2)
                if Self.isGzip(input) { zstream.reset() } else { done = true }
            }
            if !out.isEmpty { return out }
        }
        return nil
    }

    /// Everything, for small files and tests.
    public static func decompress(_ url: URL) throws -> Data {
        let reader = try GzipReader(url: url)
        var out = Data()
        while let piece = try reader.next() { out.append(piece) }
        return out
    }
}

// MARK: - Zip

/// Writes a zip archive (PKWARE APPNOTE, no zip64): each entry DEFLATE-compressed, then the
/// central directory. Entries are written one after another; an entry's sizes and CRC go into its
/// local header once its data is written.
public final class ZipWriter {
    private let handle: FileHandle
    private var entries: [(name: Data, crc: UInt32, compressed: UInt32, size: UInt32, offset: UInt32)] = []
    private var offset: UInt64 = 0
    private let date: (time: UInt16, day: UInt16)

    public init(url: URL, date: Date = Date()) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseError("Couldn't create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        self.date = Self.dosDate(date)
    }

    static func dosDate(_ date: Date) -> (time: UInt16, day: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    public func add(_ name: String, data: Data) throws {
        try add(name) { write in try write(data) }
    }

    /// Adds the file at `source` as `name`, reading it a chunk at a time.
    public func add(_ name: String, contentsOf source: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        try add(name) { write in
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try write(chunk) }
        }
    }

    private func add(_ name: String, body: ((Data) throws -> Void) throws -> Void) throws {
        let nameBytes = Data(name.utf8)
        let start = offset
        guard start < UInt64(UInt32.max) else { throw DatabaseError("The file is too large for a zip archive (over 4 GB).") }
        try put(localHeader(nameBytes, crc: 0, compressed: 0, size: 0))
        let deflate = try ZStream(compress: true, windowBits: -15)
        var crc = CRC32()
        var size: UInt64 = 0
        var compressed: UInt64 = 0
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            compressed += UInt64(bytes.count)
            try put(Data(bytes))
        }
        try body { data in
            crc.update(data)
            size += UInt64(data.count)
            try data.withUnsafeBytes { try deflate.compress($0, finish: false, output: emit) }
        }
        try deflate.compress(UnsafeRawBufferPointer(start: nil, count: 0), finish: true, output: emit)
        guard size < UInt64(UInt32.max), compressed < UInt64(UInt32.max) else {
            throw DatabaseError("The file is too large for a zip archive (over 4 GB).")
        }
        let end = offset
        try handle.seek(toOffset: start)
        try handle.write(contentsOf: localHeader(nameBytes, crc: crc.value, compressed: UInt32(compressed), size: UInt32(size)))
        try handle.seek(toOffset: end)
        entries.append((nameBytes, crc.value, UInt32(compressed), UInt32(size), UInt32(start)))
    }

    private func put(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func localHeader(_ name: Data, crc: UInt32, compressed: UInt32, size: UInt32) -> Data {
        var h = Data()
        h.appendLittleEndian(UInt32(0x0403_4B50))
        h.appendLittleEndian(UInt16(20))        // version needed
        h.appendLittleEndian(UInt16(1 << 11))   // UTF-8 names
        h.appendLittleEndian(UInt16(8))         // DEFLATE
        h.appendLittleEndian(date.time)
        h.appendLittleEndian(date.day)
        h.appendLittleEndian(crc)
        h.appendLittleEndian(compressed)
        h.appendLittleEndian(size)
        h.appendLittleEndian(UInt16(name.count))
        h.appendLittleEndian(UInt16(0))
        h.append(name)
        return h
    }

    /// Writes the central directory and closes the file.
    public func close() throws {
        let directoryStart = offset
        for e in entries {
            var h = Data()
            h.appendLittleEndian(UInt32(0x0201_4B50))
            h.appendLittleEndian(UInt16(20))   // made by
            h.appendLittleEndian(UInt16(20))   // needed
            h.appendLittleEndian(UInt16(1 << 11))
            h.appendLittleEndian(UInt16(8))
            h.appendLittleEndian(date.time)
            h.appendLittleEndian(date.day)
            h.appendLittleEndian(e.crc)
            h.appendLittleEndian(e.compressed)
            h.appendLittleEndian(e.size)
            h.appendLittleEndian(UInt16(e.name.count))
            h.appendLittleEndian(UInt16(0))    // extra
            h.appendLittleEndian(UInt16(0))    // comment
            h.appendLittleEndian(UInt16(0))    // disk
            h.appendLittleEndian(UInt16(0))    // internal attributes
            h.appendLittleEndian(UInt32(0))    // external attributes
            h.appendLittleEndian(e.offset)
            h.append(e.name)
            try put(h)
        }
        guard offset < UInt64(UInt32.max) else { throw DatabaseError("The file is too large for a zip archive (over 4 GB).") }
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt32(offset - directoryStart))
        end.appendLittleEndian(UInt32(directoryStart))
        end.appendLittleEndian(UInt16(0))
        try put(end)
        try handle.close()
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}
