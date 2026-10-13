import DBKit
import Foundation

public enum ExportFormat: Codable, Hashable, Sendable {
    case csv(CSVOptions)
    case json(JSONOptions)
    case sql(SQLExportOptions)
    case xlsx(XLSXOptions)

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .sql(let o): o.gzip ? "sql.gz" : "sql"
        case .xlsx: "xlsx"
        }
    }
}

/// Where text goes as it's written: a file, or memory in tests.
public protocol TextSink: AnyObject {
    func write(_ text: String) throws
    func close() throws
}

public final class StringSink: TextSink {
    public private(set) var text = ""
    public init() {}
    public func write(_ text: String) throws { self.text += text }
    public func close() throws {}
}

/// Buffers writes and hands them to the file in large chunks.
public final class FileSink: TextSink {
    private let handle: FileHandle
    private var buffer = Data()
    private static let chunk = 256 * 1024

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseError("Couldn't create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.chunk { try flush() }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() throws {
        try flush()
        try handle.close()
    }
}

/// A file written under a hidden temporary name next to its destination and moved into place
/// only when complete, so a stopped or failed write leaves nothing (and an older file stays).
public struct PendingFile: Sendable {
    public let destination: URL
    public let temporary: URL

    public init(_ destination: URL) {
        self.destination = destination
        temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).tabula-\(UUID().uuidString.prefix(8))")
    }

    public func commit() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Runs `write` against the temporary file and moves it into place, or removes it on error.
    public func write<T>(_ body: (URL) async throws -> T) async throws -> T {
        do {
            let result = try await body(temporary)
            try commit()
            return result
        } catch {
            discard()
            throw error
        }
    }
}

/// Writes a table or a query result to a file in one format.
///
/// A table is read with one streamed SELECT (the grid's filter and sort, or the whole table), so
/// the export holds at most one batch in memory. The file is written next to the destination under
/// a temporary name and moved into place only when everything was written; a cancelled or failed
/// export leaves no file behind.
public struct ExportJob: Sendable {
    public enum Source: Sendable {
        /// `filter` and `sort` as the grid has them, or nil and empty for the whole table.
        case table(TableRef, filter: Filter?, sort: [SortKey], connection: any DatabaseConnection)
        /// Rows already loaded, such as a query result. `name` labels the SQL header and is the INSERT
        /// target.
        case rows(name: String, columns: [String], rows: [[DBValue]], dialect: any Dialect)
    }

    public var source: Source
    public var format: ExportFormat
    /// Rows per batch read from the database.
    public var batchSize: Int

    public init(source: Source, format: ExportFormat, batchSize: Int = 1000) {
        self.source = source
        self.format = format
        self.batchSize = max(1, batchSize)
    }

    private var name: String {
        switch source {
        case .table(let t, _, _, _): t.name
        case .rows(let name, _, _, _): name
        }
    }

    /// Writes the file and returns the number of rows. `progress` gets the running row count after
    /// each batch. Cancelling the task stops the export.
    @discardableResult
    public func run(to url: URL, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        if case .csv(let options) = format { try options.validate() }
        return try await PendingFile(url).write { temp in try await write(file: temp, progress: progress) }
    }

    /// Writes the whole file at `url` (no temporary name); the multi-table export calls this too.
    func write(file url: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> Int {
        switch format {
        case .xlsx:
            let sheet = url.appendingPathExtension("sheet")
            defer { try? FileManager.default.removeItem(at: sheet) }
            let sink = try FileSink(url: sheet)
            let count: Int
            do {
                count = try await write(to: sink, progress: progress)
                try sink.close()
            } catch {
                try? sink.close()
                throw error
            }
            try XLSXWorkbook(sheets: [.init(name: XLSXWorkbook.sheetName(name, taken: []), xml: sheet)]).write(to: url)
            return count
        case .sql(let o) where o.gzip:
            let sink = try GzipWriter(url: url)
            do {
                let count = try await write(to: sink, progress: progress)
                try sink.close()
                return count
            } catch {
                try? sink.close()
                throw error
            }
        default:
            let sink = try FileSink(url: url)
            do {
                let count = try await write(to: sink, progress: progress)
                try sink.close()
                return count
            } catch {
                try? sink.close()
                throw error
            }
        }
    }

    /// Writes everything to `sink` (which stays open). Returns the number of rows.
    @discardableResult
    public func write(to sink: TextSink, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        switch source {
        case .rows(let name, let columns, let rows, let dialect):
            var writer = makeWriter(dialect: dialect, table: TableRef(name), source: name, create: nil)
            try sink.write(writer.header(columns: columns))
            var written = 0
            for start in stride(from: 0, to: rows.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(rows[start..<min(rows.count, start + batchSize)])
                try sink.write(writer.rows(batch))
                try Self.checkOverflow(writer)
                written += batch.count
                progress(written)
            }
            try sink.write(writer.footer())
            return written

        case .table(let table, let filter, let sort, let connection):
            let dialect = connection.dialect
            let info = try await connection.columns(of: table)
            var create: String?
            if case .sql(let o) = format, o.includeStructure {
                create = await Self.createStatement(table, connection: connection)
            }
            var writer = makeWriter(dialect: dialect, table: table, source: table.description, create: create)
            if var sql = writer as? SQLWriter {
                sql.sequences = SequenceStatements(table: table, columns: info, dialect: dialect)
                writer = sql
            }
            let select = dialect.select(BrowseRequest(table, filter: filter, sort: sort), allColumns: info.map(\.name))
            var wroteHeader = false
            var written = 0
            for try await batch in connection.stream(select.statement(for: dialect), batchSize: batchSize) {
                try Task.checkCancellation()
                if !wroteHeader {
                    let names = batch.columns.isEmpty ? info.map(\.name) : batch.columns.map(\.name)
                    if var sheet = writer as? XLSXSheetWriter {
                        let types = batch.columns.isEmpty ? info.map(\.typeName) : batch.columns.map(\.typeName)
                        sheet.decimalColumns = XLSXSheetWriter.decimalColumns(types)
                        writer = sheet
                    }
                    try sink.write(writer.header(columns: names))
                    wroteHeader = true
                }
                try sink.write(writer.rows(batch.rows))
                try Self.checkOverflow(writer)
                written += batch.rows.count
                progress(written)
            }
            // A cancelled consumer sees the stream end early.
            try Task.checkCancellation()
            if !wroteHeader { try sink.write(writer.header(columns: info.map(\.name))) }
            try sink.write(writer.footer())
            return written
        }
    }

    /// The object's CREATE statement, or a comment saying there is none.
    static func createStatement(_ table: TableRef, connection: any DatabaseConnection) async -> String {
        let kind: ObjectKind = (try? await connection.objects(schema: table.schema))?
            .first { $0.ref.name == table.name }?.kind ?? .table
        do {
            return try await connection.definition(of: DatabaseObject(table, kind: kind))
        } catch {
            return "-- No CREATE statement is available for \(table.name)."
        }
    }

    static func checkOverflow(_ writer: any RowWriter) throws {
        if let sheet = writer as? XLSXSheetWriter, sheet.overflow {
            throw DatabaseError("An Excel sheet holds at most \(XLSXSheetWriter.maxRows.formatted()) rows, the header included.")
        }
    }

    private func makeWriter(dialect: any Dialect, table: TableRef, source: String, create: String?) -> any RowWriter {
        switch format {
        case .csv(let o): CSVWriter(o)
        case .json(let o): JSONWriter(o)
        case .sql(let o): SQLWriter(o, dialect: dialect, table: table, createStatement: create, source: source)
        case .xlsx(let o): XLSXSheetWriter(o)
        }
    }
}

/// Exports several tables and views at once:
/// - CSV and JSON: one file per table in a folder, named by a pattern;
/// - SQL: one script, with DROP / CREATE / rows chosen per table;
/// - Excel: one workbook, a sheet per table.
///
/// Every file is complete or absent: each is written under a temporary name and moved into
/// place when done. Stopping keeps the files already finished.
public struct TablesExportJob: Sendable {
    public struct Item: Sendable, Hashable {
        public var object: DatabaseObject
        /// SQL only: what the script holds for this table.
        public var structure: Bool
        public var drop: Bool
        public var data: Bool

        public init(_ object: DatabaseObject, structure: Bool = true, drop: Bool = false, data: Bool = true) {
            self.object = object
            self.structure = structure
            self.drop = drop
            self.data = data
        }
    }

    public var items: [Item]
    public var format: ExportFormat
    public var connection: any DatabaseConnection
    /// Names the files: per table for CSV and JSON (`{table}` filled in), once for SQL and Excel.
    public var pattern: FileNamePattern
    public var context: FileNamePattern.Context
    public var batchSize: Int

    public init(
        items: [Item], format: ExportFormat, connection: any DatabaseConnection,
        pattern: FileNamePattern, context: FileNamePattern.Context, batchSize: Int = 1000
    ) {
        self.items = items
        self.format = format
        self.connection = connection
        self.pattern = pattern
        self.context = context
        self.batchSize = max(1, batchSize)
    }

    /// Whether the export is one file (SQL, Excel) or a folder of files (CSV, JSON).
    public var isSingleFile: Bool {
        switch format {
        case .sql, .xlsx: true
        case .csv, .json: false
        }
    }

    /// The file name for one table (CSV, JSON) or for the whole export (SQL, Excel).
    public func fileName(for table: String?, taken: inout Set<String>) -> String {
        var c = context
        c.table = table ?? ""
        return FileNamePattern.unique(pattern.render(c, fallback: table ?? (context.database.isEmpty ? "export" : context.database)),
                                      extension: format.fileExtension, taken: &taken)
    }

    /// Progress: which item (index), and rows written for it so far.
    public typealias Progress = @Sendable (_ item: Int, _ rows: Int) -> Void

    /// Writes the export to `destination`: the folder for CSV and JSON, the file for SQL and
    /// Excel. Returns the files written.
    @discardableResult
    public func run(to destination: URL, progress: @escaping Progress = { _, _ in }) async throws -> [URL] {
        guard !items.isEmpty else { throw DatabaseError("Choose at least one table to export.") }
        if case .csv(let options) = format { try options.validate() }
        switch format {
        case .csv, .json:
            // A file already in the folder with a table's name is replaced; two tables of this
            // export never share a name.
            var taken = Set<String>()
            var written: [URL] = []
            for (i, item) in items.enumerated() {
                try Task.checkCancellation()
                let url = destination.appending(path: fileName(for: item.object.ref.name, taken: &taken))
                let job = ExportJob(source: .table(item.object.ref, filter: nil, sort: [], connection: connection), format: format, batchSize: batchSize)
                _ = try await job.run(to: url) { progress(i, $0) }
                written.append(url)
            }
            return written
        case .sql(let options):
            try await PendingFile(destination).write { temp in
                let sink: TextSink = options.gzip ? try GzipWriter(url: temp) : try FileSink(url: temp)
                do {
                    try await writeScript(options, to: sink, progress: progress)
                    try sink.close()
                } catch {
                    try? sink.close()
                    throw error
                }
            }
            return [destination]
        case .xlsx(let options):
            try await PendingFile(destination).write { temp in
                let folder = temp.appendingPathExtension("sheets")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                var sheets: [XLSXWorkbook.Sheet] = []
                for (i, item) in items.enumerated() {
                    try Task.checkCancellation()
                    let xml = folder.appending(path: "sheet\(i + 1).xml")
                    let job = ExportJob(source: .table(item.object.ref, filter: nil, sort: [], connection: connection), format: .xlsx(options), batchSize: batchSize)
                    let sink = try FileSink(url: xml)
                    do {
                        _ = try await job.write(to: sink) { progress(i, $0) }
                        try sink.close()
                    } catch {
                        try? sink.close()
                        throw error
                    }
                    sheets.append(.init(name: XLSXWorkbook.sheetName(item.object.ref.name, taken: sheets.map(\.name)), xml: xml))
                }
                try XLSXWorkbook(sheets: sheets).write(to: temp)
            }
            return [destination]
        }
    }

    /// One script for every item: the drops first (tables referenced by others last), then each
    /// table's CREATE and rows, referenced tables first so the script runs in order.
    func writeScript(_ options: SQLExportOptions, to sink: TextSink, progress: @escaping Progress) async throws {
        let dialect = connection.dialect
        let ordered = await dependencyOrder()
        let source = context.database.isEmpty ? (items.count == 1 ? items[0].object.ref.description : "\(items.count) tables")
            : "\(context.database) (\(items.count) table\(items.count == 1 ? "" : "s"))"
        try sink.write(SQLWriter.comment(source: source, dialect: dialect, date: context.date))
        let (before, after) = Self.keyChecks(dialect, count: items.count)
        if let before { try sink.write(before + "\n\n") }
        let drops = ordered.reversed().filter { items[$0].drop }
        for i in drops {
            let item = items[i]
            let word = item.object.kind == .view ? "VIEW" : item.object.kind == .materializedView ? "MATERIALIZED VIEW" : "TABLE"
            try sink.write("DROP \(word) IF EXISTS \(dialect.qualified(item.object.ref));\n")
        }
        if !drops.isEmpty { try sink.write("\n") }
        for i in ordered {
            try Task.checkCancellation()
            let item = items[i]
            var o = options
            o.dropTable = false
            o.includeStructure = item.structure
            o.includeData = item.data && item.object.kind == .table
            if !o.includeStructure && !o.includeData { continue }
            var create: String?
            if o.includeStructure { create = try await createStatement(item.object) }
            if o.includeData {
                var writer = SQLWriter(o, dialect: dialect, table: item.object.ref, createStatement: create, source: item.object.ref.description, date: context.date)
                writer.writeComment = false
                try await Self.stream(item.object.ref, connection: connection, writer: writer, batchSize: batchSize, to: sink) { progress(i, $0) }
            } else if let create {
                let sequences = SequenceStatements(table: item.object.ref, columns: (try? await connection.columns(of: item.object.ref)) ?? [], dialect: dialect)
                try sink.write(sequences.beforeCreate.map { $0 + ";\n" }.joined() + create + "\n\n"
                               + sequences.afterCreate.map { $0 + ";\n" }.joined())
            }
            progress(i, 0)
        }
        if let after { try sink.write("\n" + after + "\n") }
    }

    private func createStatement(_ object: DatabaseObject) async throws -> String {
        do {
            return try await connection.definition(of: object)
        } catch {
            return "-- No CREATE statement is available for \(object.ref.name)."
        }
    }

    private static func stream(
        _ table: TableRef, connection: any DatabaseConnection, writer: SQLWriter, batchSize: Int, to sink: TextSink,
        progress: @Sendable (Int) -> Void
    ) async throws {
        var writer = writer
        let dialect = connection.dialect
        let info = try await connection.columns(of: table)
        writer.sequences = SequenceStatements(table: table, columns: info, dialect: dialect)
        let select = dialect.select(BrowseRequest(table), allColumns: info.map(\.name))
        try sink.write(writer.header(columns: info.map(\.name)))
        var written = 0
        for try await batch in connection.stream(select.statement(for: dialect), batchSize: batchSize) {
            try Task.checkCancellation()
            try sink.write(writer.rows(batch.rows))
            written += batch.rows.count
            progress(written)
        }
        try Task.checkCancellation()
        try sink.write(writer.footer())
        try sink.write("\n")
    }

    /// Statements around a script of several tables that keep key checks from failing on the
    /// order rows arrive in, where the database has such a switch.
    static func keyChecks(_ dialect: any Dialect, count: Int) -> (String?, String?) {
        guard count > 1 else { return (nil, nil) }
        if dialect is MySQLDialect { return ("SET FOREIGN_KEY_CHECKS = 0;", "SET FOREIGN_KEY_CHECKS = 1;") }
        if dialect is SQLiteDialect { return ("PRAGMA foreign_keys = OFF;", "PRAGMA foreign_keys = ON;") }
        return (nil, nil)
    }

    /// Item indexes with every table after the tables it references (when the database reports
    /// its foreign keys), views after tables; otherwise in the given order. Cycles keep the given
    /// order.
    func dependencyOrder() async -> [Int] {
        var references: [Int: Set<Int>] = [:]
        let index = Dictionary(items.enumerated().map { ($0.element.object.ref, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (i, item) in items.enumerated() where item.object.kind == .table {
            let keys = (try? await connection.foreignKeys(of: item.object.ref)) ?? []
            references[i] = Set(keys.compactMap { key in
                var target = key.referencedTable
                if target.schema == nil { target.schema = item.object.ref.schema }
                return index[target] ?? index[TableRef(target.name)]
            }.filter { $0 != i })
        }
        var order: [Int] = []
        var placed = Set<Int>()
        var visiting = Set<Int>()
        func visit(_ i: Int) {
            if placed.contains(i) || visiting.contains(i) { return }
            visiting.insert(i)
            for j in (references[i] ?? []).sorted() { visit(j) }
            visiting.remove(i)
            placed.insert(i)
            order.append(i)
        }
        let tables = items.indices.filter { items[$0].object.kind == .table }
        for i in tables { visit(i) }
        for i in items.indices where !placed.contains(i) {
            placed.insert(i)
            order.append(i)
        }
        return order
    }
}
