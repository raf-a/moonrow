import DBKit
import Foundation
import NIOCore
import WireSupport

/// Built-in type OIDs (from pg_type.dat) and how their text output becomes a `DBValue`.
enum PGType {
    static let bool: UInt32 = 16
    static let bytea: UInt32 = 17
    static let int8: UInt32 = 20
    static let int2: UInt32 = 21
    static let int4: UInt32 = 23
    static let oid: UInt32 = 26
    static let float4: UInt32 = 700
    static let float8: UInt32 = 701

    static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 24: "regproc",
        25: "text", 26: "oid", 28: "xid", 114: "json", 142: "xml", 600: "point", 601: "lseg", 602: "path",
        603: "box", 604: "polygon", 628: "line", 650: "cidr", 700: "float4", 701: "float8", 718: "circle",
        774: "macaddr8", 790: "money", 829: "macaddr", 869: "inet", 1000: "_bool", 1001: "_bytea",
        1005: "_int2", 1007: "_int4", 1009: "_text", 1014: "_bpchar", 1015: "_varchar", 1016: "_int8",
        1021: "_float4", 1022: "_float8", 1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time",
        1114: "timestamp", 1115: "_timestamp", 1182: "_date", 1184: "timestamptz", 1185: "_timestamptz",
        1186: "interval", 1231: "_numeric", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric",
        2205: "regclass", 2206: "regtype", 2249: "record", 2278: "void", 2950: "uuid", 2951: "_uuid",
        3614: "tsvector", 3615: "tsquery", 3802: "jsonb", 3807: "_jsonb", 3904: "int4range",
        3906: "numrange", 3908: "tsrange", 3910: "tstzrange", 3912: "daterange", 3926: "int8range",
        4089: "regnamespace", 4096: "regrole", 4451: "int4multirange",
    ]

    /// A text-format value as the grid's value kinds: integers, floats, booleans and bytea
    /// become typed values; everything else stays exactly the text the server printed.
    static func decode(_ bytes: inout ByteBuffer, length: Int, type: UInt32) -> DBValue {
        switch type {
        case int2, int4, int8, oid:
            if let s = bytes.readString(length: length), let n = Int64(s) { return .integer(n) }
        case float4, float8:
            if let s = bytes.readString(length: length) {
                switch s {
                case "NaN": return .double(.nan)
                case "Infinity": return .double(.infinity)
                case "-Infinity": return .double(-.infinity)
                default: if let d = Double(s) { return .double(d) }
                }
                return .text(s)
            }
        case bool:
            if let b: UInt8 = bytes.readInteger() {
                bytes.moveReaderIndex(forwardBy: length - 1)
                return .bool(b == UInt8(ascii: "t"))
            }
        case bytea:
            // bytea_output is set to hex at startup: `\x` then two digits per byte.
            if let view = bytes.readSlice(length: length) {
                let digits = view.readableBytesView
                if digits.count >= 2, digits.first == UInt8(ascii: "\\"),
                   let data = Data(hexDigits: digits.dropFirst(2)) {
                    return .blob(data)
                }
                return .text(String(decoding: digits, as: UTF8.self))
            }
        default:
            if let s = bytes.readString(length: length) { return .text(s) }
            if let raw = bytes.readBytes(length: length) { return .text(String(decoding: raw, as: UTF8.self)) }
        }
        return .null
    }

    /// A binding in text format. The server parses it as the type it infers for the parameter.
    static func encode(_ value: DBValue) -> [UInt8]? {
        switch value {
        case .null: nil
        case .integer(let v): Array(String(v).utf8)
        case .double(let v):
            Array((v.isNaN ? "NaN" : v.isInfinite ? (v < 0 ? "-Infinity" : "Infinity") : String(v)).utf8)
        case .text(let v): Array(v.utf8)
        case .blob(let d): Array(("\\x" + d.hexString).utf8)
        case .bool(let v): Array((v ? "true" : "false").utf8)
        }
    }

    /// How a binding appears in the server's log (`$1 = '…'`), for comparing previews with it.
    static func logged(_ value: DBValue) -> String {
        guard let bytes = encode(value) else { return "NULL" }
        return "'" + String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "'", with: "''") + "'"
    }
}
