import DBKit
import Foundation

/// What the cell editor window shows for a value.
public enum CellViewer {
    /// JSON laid out with two-space indents, keys in their original order and every string,
    /// number and literal exactly as written. Nil when `text` isn't a JSON object or array.
    public static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil
        else { return nil }
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        let chars = Array(trimmed)
        var i = 0
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // An empty container stays on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out += c == "{" ? "{}" : "[]"
                    i = j
                } else {
                    out.append(c)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out += ": "
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }

    /// `hexdump -C` style lines: offset, 16 bytes in hex, the printable ASCII. At most `limit`
    /// bytes are shown; the rest is summarized on a last line.
    public static func hexDump(_ data: Data, limit: Int = 64 * 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 2)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for (k, b) in chunk.enumerated() {
                hex += String(format: "%02x ", b)
                if k == 7 { hex += " " }
            }
            hex = hex.padding(toLength: 49, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex + " |" + ascii + "|")
            offset += 16
        }
        if data.count > limit {
            lines.append("… \((data.count - limit).formatted()) more bytes")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a column stores bytes (a file loaded into it becomes a blob rather than text).
    public static func isBinary(typeName: String) -> Bool {
        let t = typeName.uppercased()
        return ["BLOB", "BYTEA", "BINARY", "VARBINARY"].contains { t.contains($0) }
    }

    /// The value a file loads as in a column: bytes for binary columns, else UTF-8 text (nil
    /// when the file isn't UTF-8 text).
    public static func value(fromFile data: Data, typeName: String) -> DBValue? {
        if isBinary(typeName: typeName) { return .blob(data) }
        return String(data: data, encoding: .utf8).map(DBValue.text)
    }

    /// Largest file Set Value ▸ From File… loads.
    public static let fileLimit = 64 * 1024 * 1024
}
