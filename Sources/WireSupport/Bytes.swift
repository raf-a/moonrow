import Foundation
import NIOCore

extension ByteBuffer {
    public mutating func readCString() -> String? {
        guard let end = readableBytesView.firstIndex(of: 0) else { return nil }
        let s = readString(length: end - readerIndex)
        moveReaderIndex(forwardBy: 1)
        return s
    }

    public mutating func writeCString(_ s: String) {
        writeString(s)
        writeInteger(UInt8(0))
    }

    /// The remaining bytes as UTF-8 text (invalid sequences replaced).
    public mutating func readRemainingString() -> String {
        String(decoding: readBytes(length: readableBytes) ?? [], as: UTF8.self)
    }
}

extension Data {
    /// Upper-case hex digits.
    public var hexString: String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses hex digits (either case); nil on anything else.
    public init?<S: Sequence>(hexDigits: S) where S.Element == UInt8 {
        var out = Data()
        var high: UInt8?
        for c in hexDigits {
            let v: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high {
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        guard high == nil else { return nil }
        self = out
    }
}

/// Set once from any thread, read from any thread.
public final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    /// Returns true for the call that set it.
    @discardableResult
    public func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }
}
