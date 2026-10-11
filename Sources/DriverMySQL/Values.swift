import DBKit
import Foundation
import NIOCore
import WireSupport

/// How cell values become `DBValue`s. Text-protocol and binary-protocol rows decode to the same
/// values, so a table looks the same whether or not its query had parameters.
enum ValueDecoding {
    enum Kind {
        case integer, float, double, bit, blob, text
    }

    static func kind(of column: ColumnDefinition) -> Kind {
        switch column.type {
        case FieldType.tiny, FieldType.short, FieldType.int24, FieldType.long, FieldType.longlong, FieldType.year:
            return .integer
        case FieldType.float: return .float
        case FieldType.double: return .double
        case FieldType.bit: return .bit
        case FieldType.geometry, FieldType.vector: return .blob
        case FieldType.tinyBlob, FieldType.mediumBlob, FieldType.longBlob, FieldType.blob,
             FieldType.varchar, FieldType.varString, FieldType.string:
            return column.isBinary ? .blob : .text
        default: return .text
        }
    }

    /// One text-protocol row: each cell a length-encoded string, 0xFB for NULL.
    static func textRow(_ packet: ByteBuffer, columns: [ColumnDefinition]) throws -> [DBValue] {
        var p = packet
        var row: [DBValue] = []
        row.reserveCapacity(columns.count)
        for column in columns {
            if p.firstByte == 0xFB {
                p.moveReaderIndex(forwardBy: 1)
                row.append(.null)
                continue
            }
            guard let cell = p.readLengthEncodedSlice() else { throw WireError.protocolViolation("short row") }
            row.append(textValue(cell, column))
        }
        return row
    }

    static func textValue(_ cell: ByteBuffer, _ column: ColumnDefinition) -> DBValue {
        switch kind(of: column) {
        case .integer:
            let s = String(buffer: cell)
            return Int64(s).map(DBValue.integer) ?? .text(s)
        case .float, .double:
            let s = String(buffer: cell)
            return Double(s).map(DBValue.double) ?? .text(s)
        case .bit:
            return bitValue(cell)
        case .blob:
            return .blob(Data(cell.readableBytesView))
        case .text:
            return .text(String(buffer: cell))
        }
    }

    static func bitValue(_ cell: ByteBuffer) -> DBValue {
        guard cell.readableBytes <= 8 else { return .blob(Data(cell.readableBytesView)) }
        var v: UInt64 = 0
        for b in cell.readableBytesView { v = v << 8 | UInt64(b) }
        return v <= UInt64(Int64.max) ? .integer(Int64(v)) : .text(String(v))
    }

    /// One binary-protocol row: 0x00, a NULL bitmap offset by two bits, then the non-NULL values.
    static func binaryRow(_ packet: ByteBuffer, columns: [ColumnDefinition]) throws -> [DBValue] {
        var p = packet
        guard p.readInteger(as: UInt8.self) == 0x00,
              let bitmap = p.readBytes(length: (columns.count + 7 + 2) / 8)
        else { throw WireError.protocolViolation("binary row header") }
        var row: [DBValue] = []
        row.reserveCapacity(columns.count)
        for (i, column) in columns.enumerated() {
            let bit = i + 2
            if bitmap[bit / 8] & (1 << (bit % 8)) != 0 {
                row.append(.null)
                continue
            }
            guard let value = binaryValue(&p, column) else { throw WireError.protocolViolation("short binary row") }
            row.append(value)
        }
        return row
    }

    static func binaryValue(_ p: inout ByteBuffer, _ column: ColumnDefinition) -> DBValue? {
        let unsigned = column.isUnsigned
        switch column.type {
        case FieldType.null:
            return .null
        case FieldType.tiny:
            guard let v = p.readInteger(as: UInt8.self) else { return nil }
            return .integer(unsigned ? Int64(v) : Int64(Int8(bitPattern: v)))
        case FieldType.short, FieldType.year:
            guard let v = p.readInteger(endianness: .little, as: UInt16.self) else { return nil }
            return .integer(unsigned || column.type == FieldType.year ? Int64(v) : Int64(Int16(bitPattern: v)))
        case FieldType.int24, FieldType.long:
            guard let v = p.readInteger(endianness: .little, as: UInt32.self) else { return nil }
            return .integer(unsigned ? Int64(v) : Int64(Int32(bitPattern: v)))
        case FieldType.longlong:
            guard let v = p.readInteger(endianness: .little, as: UInt64.self) else { return nil }
            if unsigned { return v <= UInt64(Int64.max) ? .integer(Int64(v)) : .text(String(v)) }
            return .integer(Int64(bitPattern: v))
        case FieldType.float:
            guard let v = p.readInteger(endianness: .little, as: UInt32.self) else { return nil }
            // Through the float's shortest decimal form, so 0.1 stays 0.1 as in text rows.
            let f = Float(bitPattern: v)
            return .double(Double(String(f)) ?? Double(f))
        case FieldType.double:
            guard let v = p.readInteger(endianness: .little, as: UInt64.self) else { return nil }
            return .double(Double(bitPattern: v))
        case FieldType.date, FieldType.newDate, FieldType.datetime, FieldType.datetime2,
             FieldType.timestamp, FieldType.timestamp2:
            return dateTime(&p, column).map(DBValue.text)
        case FieldType.time, FieldType.time2:
            return time(&p, column).map(DBValue.text)
        default:
            guard let cell = p.readLengthEncodedSlice() else { return nil }
            return textValue(cell, column)
        }
    }

    private static func dateTime(_ p: inout ByteBuffer, _ column: ColumnDefinition) -> String? {
        guard let length = p.readInteger(as: UInt8.self) else { return nil }
        var year: UInt16 = 0, month: UInt8 = 0, day: UInt8 = 0
        var hour: UInt8 = 0, minute: UInt8 = 0, second: UInt8 = 0, micro: UInt32 = 0
        if length >= 4 {
            guard let y = p.readInteger(endianness: .little, as: UInt16.self),
                  let m = p.readInteger(as: UInt8.self), let d = p.readInteger(as: UInt8.self) else { return nil }
            (year, month, day) = (y, m, d)
        }
        if length >= 7 {
            guard let h = p.readInteger(as: UInt8.self), let mi = p.readInteger(as: UInt8.self),
                  let s = p.readInteger(as: UInt8.self) else { return nil }
            (hour, minute, second) = (h, mi, s)
        }
        if length >= 11 {
            guard let us = p.readInteger(endianness: .little, as: UInt32.self) else { return nil }
            micro = us
        }
        let date = pad(Int(year), 4) + "-" + pad(Int(month), 2) + "-" + pad(Int(day), 2)
        if column.type == FieldType.date || column.type == FieldType.newDate { return date }
        return date + " " + pad(Int(hour), 2) + ":" + pad(Int(minute), 2) + ":" + pad(Int(second), 2)
            + fraction(micro, column.decimals)
    }

    private static func time(_ p: inout ByteBuffer, _ column: ColumnDefinition) -> String? {
        guard let length = p.readInteger(as: UInt8.self) else { return nil }
        var negative = false, days: UInt32 = 0, hour: UInt8 = 0, minute: UInt8 = 0, second: UInt8 = 0
        var micro: UInt32 = 0
        if length >= 8 {
            guard let n = p.readInteger(as: UInt8.self), let d = p.readInteger(endianness: .little, as: UInt32.self),
                  let h = p.readInteger(as: UInt8.self), let mi = p.readInteger(as: UInt8.self),
                  let s = p.readInteger(as: UInt8.self) else { return nil }
            (negative, days, hour, minute, second) = (n == 1, d, h, mi, s)
        }
        if length >= 12 {
            guard let us = p.readInteger(endianness: .little, as: UInt32.self) else { return nil }
            micro = us
        }
        let hours = Int(days) * 24 + Int(hour)
        return (negative ? "-" : "") + pad(hours, 2) + ":" + pad(Int(minute), 2) + ":" + pad(Int(second), 2)
            + fraction(micro, column.decimals)
    }

    /// Fractional seconds to the column's declared digits (31 means "not fixed": show if present).
    private static func fraction(_ micro: UInt32, _ decimals: UInt8) -> String {
        let digits = decimals == 31 ? (micro == 0 ? 0 : 6) : min(Int(decimals), 6)
        guard digits > 0 else { return "" }
        return "." + String(pad(Int(micro), 6).prefix(digits))
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

enum ParameterEncoding {
    /// The NULL bitmap, the types and the values of COM_STMT_EXECUTE.
    static func write(_ values: [DBValue], into b: inout ByteBuffer) {
        var bitmap = [UInt8](repeating: 0, count: (values.count + 7) / 8)
        for (i, v) in values.enumerated() where v.isNull { bitmap[i / 8] |= 1 << (i % 8) }
        b.writeBytes(bitmap)
        b.writeInteger(UInt8(1)) // new-params-bound
        for v in values {
            let type: UInt8 = switch v {
            case .null: FieldType.null
            case .integer: FieldType.longlong
            case .double: FieldType.double
            case .bool: FieldType.tiny
            case .text: FieldType.varString
            case .blob: FieldType.blob
            }
            b.writeInteger(type)
            b.writeInteger(UInt8(0))
        }
        for v in values {
            switch v {
            case .null: break
            case .integer(let n): b.writeInteger(UInt64(bitPattern: n), endianness: .little)
            case .double(let d): b.writeInteger(d.bitPattern, endianness: .little)
            case .bool(let f): b.writeInteger(UInt8(f ? 1 : 0))
            case .text(let s): b.writeLengthEncodedBytes(Array(s.utf8))
            case .blob(let d): b.writeLengthEncodedBytes(d)
            }
        }
    }
}
