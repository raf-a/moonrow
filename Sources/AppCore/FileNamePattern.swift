import Foundation

/// A file name with placeholders, for exports and backups: `{table}`, `{database}`,
/// `{connection}`, `{tag}` and the date and time when it's rendered (`{yyyy}-{MM}-{dd}`).
/// Unknown placeholders are kept as written. The extension isn't part of the pattern.
public struct FileNamePattern: Sendable, Hashable {
    public struct Token: Sendable, Hashable {
        public var placeholder: String
        public var title: String
    }

    public static let tokens: [Token] = [
        Token(placeholder: "{table}", title: "Table"),
        Token(placeholder: "{database}", title: "Database"),
        Token(placeholder: "{connection}", title: "Connection"),
        Token(placeholder: "{tag}", title: "Tag"),
        Token(placeholder: "{yyyy}", title: "Year"),
        Token(placeholder: "{MM}", title: "Month"),
        Token(placeholder: "{MMM}", title: "Month name"),
        Token(placeholder: "{dd}", title: "Day"),
        Token(placeholder: "{HH}", title: "Hour"),
        Token(placeholder: "{mm}", title: "Minute"),
        Token(placeholder: "{ss}", title: "Second"),
    ]

    public static let export = "{table}"
    public static let backup = "{database}-{yyyy}-{MM}-{dd}-{HH}{mm}{ss}"

    /// What the placeholders stand for.
    public struct Context: Sendable {
        public var table: String
        public var database: String
        public var connection: String
        public var tag: String
        public var date: Date

        public init(table: String = "", database: String = "", connection: String = "", tag: String = "", date: Date = Date()) {
            self.table = table
            self.database = database
            self.connection = connection
            self.tag = tag
            self.date = date
        }
    }

    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// The file name (without extension). Values can't add folders: `/` and `:` become `-`.
    /// A name that comes out empty is `fallback`.
    public func render(_ context: Context, fallback: String = "export") -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: context.date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "MMM"
        let values: [String: String] = [
            "table": context.table, "database": context.database, "connection": context.connection, "tag": context.tag,
            "yyyy": String(format: "%04d", c.year ?? 0), "MM": two(c.month), "MMM": month.string(from: context.date),
            "dd": two(c.day), "HH": two(c.hour), "mm": two(c.minute), "ss": two(c.second),
        ]
        var out = ""
        var rest = pattern[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let key = String(rest[rest.index(after: open)..<close])
            out += values[key].map(Self.clean) ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let name = Self.clean(out).trimmingCharacters(in: .whitespaces).drop { $0 == "." }
        return name.isEmpty ? fallback : String(name)
    }

    /// No folder separators, colons (Finder shows them as `/`) or control characters.
    static func clean(_ s: String) -> String {
        String(s.map { "/:".contains($0) ? "-" : $0 }.filter { !($0.asciiValue.map { $0 < 0x20 } ?? false) })
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`, … when `taken` (lowercased file names) has it.
    public static func unique(_ name: String, extension ext: String, taken: inout Set<String>) -> String {
        var candidate = name + "." + ext
        var n = 1
        while taken.contains(candidate.lowercased()) {
            n += 1
            candidate = "\(name) \(n).\(ext)"
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
