import DBKit
import NIOCore
import WireSupport

/// Backend messages: a type byte, then an Int32 length that counts itself.
struct PGFramer: Framer {
    func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard buffer.readableBytes >= 5,
              let length: Int32 = buffer.getInteger(at: buffer.readerIndex + 1) else { return nil }
        guard length >= 4, length < 1 << 30 else {
            throw WireError.protocolViolation("message length \(length)")
        }
        let total = 1 + Int(length)
        guard buffer.readableBytes >= total else { return nil }
        return buffer.readSlice(length: total)
    }
}

/// A backend message: its type byte and body.
struct PGMessage {
    var type: UInt8
    var body: ByteBuffer

    init(frame: ByteBuffer) {
        var frame = frame
        type = frame.readInteger()!
        frame.moveReaderIndex(forwardBy: 4)
        body = frame
    }

    var kind: Character { Character(UnicodeScalar(type)) }
}

/// Frontend messages, written straight into a buffer.
enum PGFrontend {
    static let protocolVersion: Int32 = 196_608   // 3.0
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    /// A message with a type byte; the length is filled in after `body` writes.
    static func message(_ type: Character, into buffer: inout ByteBuffer, _ body: (inout ByteBuffer) -> Void) {
        buffer.writeInteger(UInt8(type.asciiValue!))
        let lengthAt = buffer.writerIndex
        buffer.writeInteger(Int32(0))
        body(&buffer)
        buffer.setInteger(Int32(buffer.writerIndex - lengthAt), at: lengthAt)
    }

    static func startup(_ parameters: [(String, String)], into buffer: inout ByteBuffer) {
        let lengthAt = buffer.writerIndex
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(protocolVersion)
        for (k, v) in parameters {
            buffer.writeCString(k)
            buffer.writeCString(v)
        }
        buffer.writeInteger(UInt8(0))
        buffer.setInteger(Int32(buffer.writerIndex - lengthAt), at: lengthAt)
    }

    static func sslRequest(into buffer: inout ByteBuffer) {
        buffer.writeInteger(Int32(8))
        buffer.writeInteger(sslRequestCode)
    }

    static func cancelRequest(processID: Int32, secretKey: [UInt8], into buffer: inout ByteBuffer) {
        buffer.writeInteger(Int32(12 + secretKey.count))
        buffer.writeInteger(cancelRequestCode)
        buffer.writeInteger(processID)
        buffer.writeBytes(secretKey)
    }

    static func password(_ bytes: [UInt8], into buffer: inout ByteBuffer) {
        message("p", into: &buffer) { $0.writeBytes(bytes) }
    }

    static func saslInitial(mechanism: String, _ data: [UInt8], into buffer: inout ByteBuffer) {
        message("p", into: &buffer) {
            $0.writeCString(mechanism)
            $0.writeInteger(Int32(data.count))
            $0.writeBytes(data)
        }
    }

    /// Parse + Bind + Describe portal + Execute + Sync for the unnamed statement and portal.
    /// Parameters go as text with unspecified types, so the server infers each from context,
    /// the way a literal in the same place would be typed. Results come back as text.
    static func extendedQuery(_ sql: String, parameters: [[UInt8]?], into buffer: inout ByteBuffer) {
        message("P", into: &buffer) {
            $0.writeCString("")
            $0.writeCString(sql)
            $0.writeInteger(Int16(0))
        }
        message("B", into: &buffer) {
            $0.writeCString("")
            $0.writeCString("")
            $0.writeInteger(Int16(0))                 // all parameters in text format
            $0.writeInteger(Int16(parameters.count))
            for p in parameters {
                if let p {
                    $0.writeInteger(Int32(p.count))
                    $0.writeBytes(p)
                } else {
                    $0.writeInteger(Int32(-1))
                }
            }
            $0.writeInteger(Int16(0))                 // all results in text format
        }
        message("D", into: &buffer) {
            $0.writeInteger(UInt8(ascii: "P"))
            $0.writeCString("")
        }
        message("E", into: &buffer) {
            $0.writeCString("")
            $0.writeInteger(Int32(0))
        }
        message("S", into: &buffer) { _ in }
    }

    static func simpleQuery(_ sql: String, into buffer: inout ByteBuffer) {
        message("Q", into: &buffer) { $0.writeCString(sql) }
    }

    static func copyFail(_ reason: String, into buffer: inout ByteBuffer) {
        message("f", into: &buffer) { $0.writeCString(reason) }
    }

    static func terminate(into buffer: inout ByteBuffer) {
        message("X", into: &buffer) { _ in }
    }
}

/// ErrorResponse / NoticeResponse fields.
struct PGNotice {
    var fields: [UInt8: String] = [:]

    init(_ body: ByteBuffer) {
        var body = body
        while let code: UInt8 = body.readInteger(), code != 0, let value = body.readCString() {
            fields[code] = value
        }
    }

    var severity: String { fields[UInt8(ascii: "V")] ?? fields[UInt8(ascii: "S")] ?? "ERROR" }
    var sqlState: String? { fields[UInt8(ascii: "C")] }
    var message: String { fields[UInt8(ascii: "M")] ?? "unknown error" }
    var detail: String? { fields[UInt8(ascii: "D")] }
    var hint: String? { fields[UInt8(ascii: "H")] }
    /// 1-based character position in the statement.
    var position: Int? { fields[UInt8(ascii: "P")].flatMap { Int($0) } }

    func error(sql: String?) -> DatabaseError {
        var text = message
        if let detail { text += "\nDETAIL: \(detail)" }
        if let hint { text += "\nHINT: \(hint)" }
        return DatabaseError(text, state: sqlState, sql: sql)
    }
}

extension DatabaseError {
    /// SQLSTATE 57014, what a cancel request produces.
    var isQueryCanceled: Bool { state == "57014" }
}
