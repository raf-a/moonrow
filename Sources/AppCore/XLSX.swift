import DBKit
import Foundation

// Excel workbooks (Office Open XML, SpreadsheetML), written by hand: each sheet's XML is streamed
// to a temporary file as rows arrive, then the parts are zipped into the `.xlsx`. Cells are
// inline strings, numbers and booleans; no shared-string table, so nothing is held in memory.

public struct XLSXOptions: Codable, Hashable, Sendable {
    /// Column names as a bold first row, kept in view while scrolling.
    public var includeHeader: Bool

    public init(includeHeader: Bool = true) {
        self.includeHeader = includeHeader
    }
}

/// One worksheet's XML, a batch of rows at a time.
public struct XLSXSheetWriter: RowWriter {
    public static let maxRows = 1_048_576
    public static let maxColumns = 16_384
    public static let maxCellText = 32_767

    public var options: XLSXOptions
    /// Columns holding exact decimals as text (Postgres `numeric`); values with at most 15
    /// significant digits are written as numbers.
    public var decimalColumns: Set<Int>
    private var row = 0
    private var references: [String] = []
    /// Set when a row couldn't be written (too many rows); `rows` stops there.
    public private(set) var overflow = false

    public init(_ options: XLSXOptions = XLSXOptions(), decimalColumns: Set<Int> = []) {
        self.options = options
        self.decimalColumns = decimalColumns
    }

    /// Column types (`ResultColumn.typeName`) whose text values are decimals.
    public static func decimalColumns(_ typeNames: [String?]) -> Set<Int> {
        Set(typeNames.enumerated().compactMap { i, t in
            guard let t = t?.lowercased() else { return nil }
            return t.hasPrefix("numeric") || t.hasPrefix("decimal") ? i : nil
        })
    }

    public mutating func header(columns: [String]) -> String {
        row = 0
        references = (0..<min(columns.count, Self.maxColumns)).map(Self.columnName)
        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        out += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if options.includeHeader, !columns.isEmpty {
            out += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        }
        out += "<sheetData>\n"
        if options.includeHeader, !columns.isEmpty {
            row = 1
            out += "<row r=\"1\">"
            for (i, name) in columns.prefix(Self.maxColumns).enumerated() {
                out += "<c r=\"\(references[i])1\" t=\"inlineStr\" s=\"1\">" + Self.inline(name) + "</c>"
            }
            out += "</row>\n"
        }
        return out
    }

    public mutating func rows(_ rows: [[DBValue]]) -> String {
        var out = ""
        for values in rows {
            guard row < Self.maxRows else {
                overflow = true
                break
            }
            row += 1
            out += "<row r=\"\(row)\">"
            for (i, value) in values.prefix(references.count).enumerated() {
                out += cell(value, column: i)
            }
            out += "</row>\n"
        }
        return out
    }

    public mutating func footer() -> String { "</sheetData></worksheet>\n" }

    private func cell(_ value: DBValue, column: Int) -> String {
        let ref = references[column] + String(row)
        switch value {
        case .null:
            return ""
        case .integer(let n):
            // Past 2^53 a double loses digits; such numbers stay exact as text.
            if n.magnitude <= 1 << 53 { return "<c r=\"\(ref)\"><v>\(n)</v></c>" }
            return text(String(n), ref)
        case .double(let d):
            return d.isFinite ? "<c r=\"\(ref)\"><v>\(d)</v></c>" : text(value.displayString, ref)
        case .bool(let b):
            return "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
        case .blob(let data):
            return text(CSVWriter.hex(data), ref)
        case .text(let s):
            if decimalColumns.contains(column), let number = Self.decimalNumber(s) { return "<c r=\"\(ref)\"><v>\(number)</v></c>" }
            return text(s, ref)
        }
    }

    private func text(_ s: String, _ ref: String) -> String {
        "<c r=\"\(ref)\" t=\"inlineStr\">" + Self.inline(s) + "</c>"
    }

    /// A decimal's text when it fits a double without losing digits.
    static func decimalNumber(_ s: String) -> String? {
        guard s.wholeMatch(of: /-?\d+(\.\d+)?/) != nil else { return nil }
        let digits = s.filter(\.isNumber).drop { $0 == "0" }
        let significant = digits.reversed().drop { $0 == "0" }.count
        return significant <= 15 ? s : nil
    }

    /// `<is><t>…</t></is>` with the text escaped and cut to Excel's cell limit.
    static func inline(_ s: String) -> String {
        var text = s
        if text.utf16.count > maxCellText {
            text = String(text.utf16.prefix(maxCellText)) ?? String(text.prefix(maxCellText / 2))
        }
        let preserve = text.first?.isWhitespace == true || text.last?.isWhitespace == true || text.contains("\n")
        return (preserve ? "<is><t xml:space=\"preserve\">" : "<is><t>") + escape(text) + "</t></is>"
    }

    /// XML text escaping, plus SpreadsheetML's `_xHHHH_` for characters XML can't hold (control
    /// characters) and for a literal `_xHHHH_` already in the text.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let u = scalars[i]
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            case "_" where isEscapeSequence(scalars, at: i):
                out += "_x005F_"
            case _ where u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF:
                out += String(format: "_x%04X_", u.value)
            default:
                out.unicodeScalars.append(u)
            }
            i += 1
        }
        return out
    }

    private static func isEscapeSequence(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + 6 < s.count, s[i + 1] == "x", s[i + 6] == "_" else { return false }
        return s[(i + 2)...(i + 5)].allSatisfy { $0.properties.isASCIIHexDigit }
    }

    /// 0 → A, 25 → Z, 26 → AA.
    public static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }
}

/// Puts sheets (their XML already written to files) together into an `.xlsx`.
public struct XLSXWorkbook {
    public struct Sheet {
        public var name: String
        public var xml: URL

        public init(name: String, xml: URL) {
            self.name = name
            self.xml = xml
        }
    }

    public var sheets: [Sheet] = []
    public var date = Date()

    public init(sheets: [Sheet] = []) {
        self.sheets = sheets
    }

    /// A name Excel accepts: at most 31 characters, none of `: \ / ? * [ ]`, not starting or
    /// ending with `'`, and unique (ignoring case) among `taken`.
    public static func sheetName(_ name: String, taken: [String]) -> String {
        var base = String(name.map { ":\\/?*[]".contains($0) ? "_" : $0 })
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if base.isEmpty { base = "Sheet" }
        let used = Set(taken.map { $0.lowercased() })
        var candidate = String(base.prefix(31))
        var n = 1
        while used.contains(candidate.lowercased()) {
            n += 1
            let suffix = " (\(n))"
            candidate = String(base.prefix(31 - suffix.count)) + suffix
        }
        return candidate
    }

    public func write(to url: URL) throws {
        let zip = try ZipWriter(url: url, date: date)
        do {
            try zip.add("[Content_Types].xml", data: Data(contentTypes.utf8))
            try zip.add("_rels/.rels", data: Data(Self.rootRels.utf8))
            try zip.add("docProps/app.xml", data: Data(Self.app.utf8))
            try zip.add("docProps/core.xml", data: Data(core.utf8))
            try zip.add("xl/workbook.xml", data: Data(workbook.utf8))
            try zip.add("xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8))
            try zip.add("xl/styles.xml", data: Data(Self.styles.utf8))
            for (i, sheet) in sheets.enumerated() {
                try zip.add("xl/worksheets/sheet\(i + 1).xml", contentsOf: sheet.xml)
            }
            try zip.close()
        } catch {
            try? zip.close()
            throw error
        }
    }

    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    private var contentTypes: String {
        Self.header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
            + #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
            + #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#
            + sheets.indices.map {
                "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            }.joined()
            + "</Types>"
    }

    private static let rootRels = header
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>"#
        + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
        + #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>"#
        + "</Relationships>"

    private static let app = header
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Moonrow</Application></Properties>"#

    private var core: String {
        let stamp = date.ISO8601Format()
        return Self.header
            + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:creator>Moonrow</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    private var workbook: String {
        Self.header
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
            + sheets.enumerated().map { i, s in
                "<sheet name=\"\(XLSXSheetWriter.escape(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            }.joined()
            + "</sheets></workbook>"
    }

    private var workbookRels: String {
        Self.header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + sheets.indices.map {
                "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
            }.joined()
            + "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>"
    }

    /// Two cell formats: plain (0) and bold for the header row (1).
    private static let styles = header
        + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        + #"<fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>"#
        + #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
        + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
        + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        + #"<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>"#
        + #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>"#
        + "</styleSheet>"
}
