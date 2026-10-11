import DBKit
import Foundation

public enum ExportFormat: Codable, Hashable, Sendable {
    case csv(CSVOptions)
    case json(JSONOptions)
    case sql(SQLExportOptions)

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .sql: "sql"
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

    /// Writes the file and returns the number of rows. `progress` gets the running row count after
    /// each batch. Cancelling the task stops the export.
    @discardableResult
    public func run(to url: URL, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        if case .csv(let options) = format { try options.validate() }
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tabula-\(UUID().uuidString.prefix(8))")
        let sink = try FileSink(url: temp)
        do {
            let count = try await write(to: sink, progress: progress)
            try sink.close()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
            return count
        } catch {
            try? sink.close()
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Writes everything to `sink` (which stays open). Returns the number of rows.
    @discardableResult
    public func write(to sink: TextSink, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        switch source {
        case .rows(let name, let columns, let rows, let dialect):
            var writer = try await makeWriter(dialect: dialect, table: TableRef(name), source: name, create: nil)
            try sink.write(writer.header(columns: columns))
            var written = 0
            for start in stride(from: 0, to: rows.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(rows[start..<min(rows.count, start + batchSize)])
                try sink.write(writer.rows(batch))
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
                let kind: ObjectKind = (try? await connection.objects(schema: table.schema))?
                    .first { $0.ref.name == table.name }?.kind ?? .table
                do {
                    create = try await connection.definition(of: DatabaseObject(table, kind: kind))
                } catch {
                    create = "-- No CREATE statement is available for \(table.name)."
                }
            }
            var writer = try await makeWriter(dialect: dialect, table: table, source: table.description, create: create)
            let select = dialect.select(BrowseRequest(table, filter: filter, sort: sort), allColumns: info.map(\.name))
            var wroteHeader = false
            var written = 0
            for try await batch in connection.stream(select.statement(for: dialect), batchSize: batchSize) {
                try Task.checkCancellation()
                if !wroteHeader {
                    let names = batch.columns.isEmpty ? info.map(\.name) : batch.columns.map(\.name)
                    try sink.write(writer.header(columns: names))
                    wroteHeader = true
                }
                try sink.write(writer.rows(batch.rows))
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

    private func makeWriter(dialect: any Dialect, table: TableRef, source: String, create: String?) async throws -> any RowWriter {
        switch format {
        case .csv(let o): CSVWriter(o)
        case .json(let o): JSONWriter(o)
        case .sql(let o): SQLWriter(o, dialect: dialect, table: table, createStatement: create, source: source)
        }
    }
}
