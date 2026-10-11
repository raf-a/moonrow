import DBKit
import Foundation
import NIOCore
import WireSupport

/// Splits the stream into MySQL packets: 3-byte little-endian payload length, sequence byte,
/// payload. A frame is the whole packet, header included.
public struct MySQLFramer: Framer {
    public init() {}

    public func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard buffer.readableBytes >= 4,
              let b0 = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
              let b1 = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              let b2 = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt8.self)
        else { return nil }
        let length = Int(b0) | Int(b1) << 8 | Int(b2) << 16
        guard buffer.readableBytes >= 4 + length else { return nil }
        return buffer.readSlice(length: 4 + length)
    }
}

/// Largest payload one packet carries; longer payloads continue in the next packet.
let maxPacketPayload = 0xFF_FFFF

struct Capabilities: OptionSet, Sendable {
    let rawValue: UInt32
    static let longPassword = Capabilities(rawValue: 0x1)
    static let foundRows = Capabilities(rawValue: 0x2)
    static let longFlag = Capabilities(rawValue: 0x4)
    static let connectWithDB = Capabilities(rawValue: 0x8)
    static let protocol41 = Capabilities(rawValue: 0x200)
    static let ssl = Capabilities(rawValue: 0x800)
    static let transactions = Capabilities(rawValue: 0x2000)
    static let secureConnection = Capabilities(rawValue: 0x8000)
    static let multiResults = Capabilities(rawValue: 0x2_0000)
    static let psMultiResults = Capabilities(rawValue: 0x4_0000)
    static let pluginAuth = Capabilities(rawValue: 0x8_0000)
    static let pluginAuthLenencData = Capabilities(rawValue: 0x20_0000)
    static let deprecateEOF = Capabilities(rawValue: 0x100_0000)
}

enum ServerStatus {
    static let moreResultsExist: UInt16 = 0x0008
}

extension ByteBuffer {
    /// A length-encoded integer. Nil at the end of the buffer or for the NULL marker (0xFB).
    mutating func readLengthEncodedInteger() -> UInt64? {
        guard let first = readInteger(as: UInt8.self) else { return nil }
        switch first {
        case 0..<0xFB: return UInt64(first)
        case 0xFC: return readInteger(endianness: .little, as: UInt16.self).map(UInt64.init)
        case 0xFD:
            guard let lo = readInteger(endianness: .little, as: UInt16.self),
                  let hi = readInteger(as: UInt8.self) else { return nil }
            return UInt64(lo) | UInt64(hi) << 16
        case 0xFE: return readInteger(endianness: .little, as: UInt64.self)
        default: return nil
        }
    }

    mutating func writeLengthEncodedInteger(_ v: UInt64) {
        switch v {
        case 0..<0xFB: writeInteger(UInt8(v))
        case 0xFB...0xFFFF:
            writeInteger(UInt8(0xFC))
            writeInteger(UInt16(v), endianness: .little)
        case 0x1_0000...0xFF_FFFF:
            writeInteger(UInt8(0xFD))
            writeInteger(UInt16(v & 0xFFFF), endianness: .little)
            writeInteger(UInt8(v >> 16))
        default:
            writeInteger(UInt8(0xFE))
            writeInteger(v, endianness: .little)
        }
    }

    mutating func readLengthEncodedSlice() -> ByteBuffer? {
        guard let n = readLengthEncodedInteger(), n <= UInt64(readableBytes) else { return nil }
        return readSlice(length: Int(n))
    }

    mutating func readLengthEncodedString() -> String? {
        readLengthEncodedSlice().map { String(buffer: $0) }
    }

    mutating func writeLengthEncodedBytes<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        writeLengthEncodedInteger(UInt64(bytes.count))
        writeBytes(bytes)
    }

    var firstByte: UInt8? { getInteger(at: readerIndex, as: UInt8.self) }
}

/// The parts of an OK packet the driver uses.
struct OKPacket {
    var affectedRows: UInt64
    var lastInsertID: UInt64
    var status: UInt16
    var warnings: UInt16

    /// Parses an OK packet (header 0x00, or 0xFE when it ends a result set).
    init?(_ packet: ByteBuffer) {
        var p = packet
        guard let header = p.readInteger(as: UInt8.self), header == 0x00 || header == 0xFE,
              let affected = p.readLengthEncodedInteger(),
              let insertID = p.readLengthEncodedInteger() else { return nil }
        affectedRows = affected
        lastInsertID = insertID
        status = p.readInteger(endianness: .little, as: UInt16.self) ?? 0
        warnings = p.readInteger(endianness: .little, as: UInt16.self) ?? 0
    }
}

/// The status flags of a pre-4.1-style EOF packet (0xFE, warnings, status).
func eofStatus(_ packet: ByteBuffer) -> UInt16 {
    var p = packet
    p.moveReaderIndex(forwardBy: 1)
    _ = p.readInteger(endianness: .little, as: UInt16.self)
    return p.readInteger(endianness: .little, as: UInt16.self) ?? 0
}

/// Turns an ERR packet (0xFF) into an error.
func serverError(_ packet: ByteBuffer, sql: String?) -> DatabaseError {
    var p = packet
    p.moveReaderIndex(forwardBy: 1)
    let code = p.readInteger(endianness: .little, as: UInt16.self).map(Int.init)
    var state: String?
    if p.firstByte == UInt8(ascii: "#") {
        p.moveReaderIndex(forwardBy: 1)
        state = p.readString(length: 5)
    }
    let message = p.readRemainingString()
    return DatabaseError(message.isEmpty ? "MySQL error \(code ?? 0)" : message, code: code, state: state, sql: sql)
}

/// A result column, as the server describes it.
struct ColumnDefinition: Sendable {
    var name: String
    var characterSet: UInt16
    var length: UInt32
    var type: UInt8
    var flags: UInt16
    var decimals: UInt8

    init(_ packet: ByteBuffer) throws {
        var p = packet
        // catalog, schema, table, org_table
        for _ in 0..<4 {
            guard p.readLengthEncodedSlice() != nil else { throw WireError.protocolViolation("column definition") }
        }
        guard let name = p.readLengthEncodedString(),
              p.readLengthEncodedSlice() != nil, // org_name
              p.readLengthEncodedInteger() != nil, // length of the fixed fields
              let charset = p.readInteger(endianness: .little, as: UInt16.self),
              let length = p.readInteger(endianness: .little, as: UInt32.self),
              let type = p.readInteger(as: UInt8.self),
              let flags = p.readInteger(endianness: .little, as: UInt16.self),
              let decimals = p.readInteger(as: UInt8.self)
        else { throw WireError.protocolViolation("column definition") }
        self.name = name
        self.characterSet = charset
        self.length = length
        self.type = type
        self.flags = flags
        self.decimals = decimals
    }

    init(name: String, type: UInt8, characterSet: UInt16 = 45, flags: UInt16 = 0, decimals: UInt8 = 0) {
        self.name = name
        self.characterSet = characterSet
        self.length = 0
        self.type = type
        self.flags = flags
        self.decimals = decimals
    }

    var isUnsigned: Bool { flags & 0x20 != 0 }
    var isBinary: Bool { characterSet == 63 }

    var resultColumn: ResultColumn { ResultColumn(name: name, typeName: typeName) }

    var typeName: String {
        let unsigned = isUnsigned ? " UNSIGNED" : ""
        switch type {
        case FieldType.tiny: return "TINYINT" + unsigned
        case FieldType.short: return "SMALLINT" + unsigned
        case FieldType.int24: return "MEDIUMINT" + unsigned
        case FieldType.long: return "INT" + unsigned
        case FieldType.longlong: return "BIGINT" + unsigned
        case FieldType.float: return "FLOAT"
        case FieldType.double: return "DOUBLE"
        case FieldType.decimal, FieldType.newDecimal: return "DECIMAL"
        case FieldType.null: return "NULL"
        case FieldType.timestamp, FieldType.timestamp2: return "TIMESTAMP"
        case FieldType.date, FieldType.newDate: return "DATE"
        case FieldType.time, FieldType.time2: return "TIME"
        case FieldType.datetime, FieldType.datetime2: return "DATETIME"
        case FieldType.year: return "YEAR"
        case FieldType.bit: return "BIT"
        case FieldType.json: return "JSON"
        case FieldType.vector: return "VECTOR"
        case FieldType.enumType: return "ENUM"
        case FieldType.set: return "SET"
        case FieldType.geometry: return "GEOMETRY"
        case FieldType.tinyBlob, FieldType.mediumBlob, FieldType.longBlob, FieldType.blob:
            return isBinary ? "BLOB" : "TEXT"
        case FieldType.varchar, FieldType.varString:
            if flags & 0x100 != 0 { return "ENUM" }
            if flags & 0x800 != 0 { return "SET" }
            return isBinary ? "VARBINARY" : "VARCHAR"
        case FieldType.string:
            if flags & 0x100 != 0 { return "ENUM" }
            if flags & 0x800 != 0 { return "SET" }
            return isBinary ? "BINARY" : "CHAR"
        default: return "UNKNOWN"
        }
    }
}

enum FieldType {
    static let decimal: UInt8 = 0x00
    static let tiny: UInt8 = 0x01
    static let short: UInt8 = 0x02
    static let long: UInt8 = 0x03
    static let float: UInt8 = 0x04
    static let double: UInt8 = 0x05
    static let null: UInt8 = 0x06
    static let timestamp: UInt8 = 0x07
    static let longlong: UInt8 = 0x08
    static let int24: UInt8 = 0x09
    static let date: UInt8 = 0x0A
    static let time: UInt8 = 0x0B
    static let datetime: UInt8 = 0x0C
    static let year: UInt8 = 0x0D
    static let newDate: UInt8 = 0x0E
    static let varchar: UInt8 = 0x0F
    static let bit: UInt8 = 0x10
    static let timestamp2: UInt8 = 0x11
    static let datetime2: UInt8 = 0x12
    static let time2: UInt8 = 0x13
    static let vector: UInt8 = 0xF2
    static let json: UInt8 = 0xF5
    static let newDecimal: UInt8 = 0xF6
    static let enumType: UInt8 = 0xF7
    static let set: UInt8 = 0xF8
    static let tinyBlob: UInt8 = 0xF9
    static let mediumBlob: UInt8 = 0xFA
    static let longBlob: UInt8 = 0xFB
    static let blob: UInt8 = 0xFC
    static let varString: UInt8 = 0xFD
    static let string: UInt8 = 0xFE
    static let geometry: UInt8 = 0xFF
}
