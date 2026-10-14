import DBKit
import Foundation
import SQLScript

/// Runs the query editor's statements one after another and reports progress as events, so
/// the results grid can fill in while rows are still arriving.
///
/// Stopping the consumer (or cancelling its task) cancels the running statement; statements
/// after it don't run.
public enum ScriptRunner {
    public struct Options: Sendable, Hashable {
        /// Rows kept per result; the statement is stopped once it would return more. Nil keeps all.
        public var rowLimit: Int?
        /// Skip the remaining statements after one fails.
        public var stopOnError: Bool
        public var batchSize: Int

        public init(rowLimit: Int? = nil, stopOnError: Bool = true, batchSize: Int = 500) {
            self.rowLimit = rowLimit.flatMap { $0 > 0 ? $0 : nil }
            self.stopOnError = stopOnError
            self.batchSize = max(1, batchSize)
        }
    }

    /// How one statement ended.
    public struct Outcome: Sendable, Hashable {
        /// Rows the statement returned (and the grid holds).
        public var rowCount: Int
        /// For statements that change rows.
        public var rowsAffected: Int?
        /// The row limit cut the result short.
        public var truncated: Bool
        public var duration: Duration
    }

    /// How a statement failed.
    public struct Failure: Sendable, Hashable {
        /// The error's text; may run over several lines (Postgres' DETAIL and HINT).
        public var message: String
        /// Where in the statement's text the error is, as a UTF-16 offset, when the server says.
        public var position: Int?
        public var duration: Duration

        public init(message: String, position: Int? = nil, duration: Duration) {
            self.message = message
            self.position = position
            self.duration = duration
        }

        /// The message's first line.
        public var headline: String {
            message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        }

        /// What to mark in the editor, as UTF-16 offsets into its text: the token at the error's
        /// position (the next one when the position falls between tokens), else the statement.
        public func range(in statement: SQLStatementRange, dialect: LexerDialect) -> Range<Int> {
            guard let position, position >= 0, position < statement.text.utf16.count else { return statement.range }
            let token = SQLLexer(statement.text, dialect: dialect).tokens().first { !$0.kind.isTrivia && $0.range.upperBound > position }
            guard let local = token?.range else { return statement.range }
            return (statement.range.lowerBound + local.lowerBound)..<(statement.range.lowerBound + local.upperBound)
        }
    }

    public enum Event: Sendable {
        case started(index: Int)
        /// The statement returns rows with these columns. Sent once, before any rows.
        case columns(index: Int, [ResultColumn])
        case rows(index: Int, [[DBValue]])
        case finished(index: Int, Outcome)
        case failed(index: Int, Failure)
        /// Every statement ran, or the run stopped at an error. Not sent when cancelled.
        case done
    }

    public static func run(
        _ statements: [SQLStatementRange], on connection: any DatabaseConnection, options: Options = Options()
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                for (index, statement) in statements.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(.started(index: index))
                    let clock = ContinuousClock()
                    let start = clock.now
                    var rowCount = 0
                    var sentColumns = false
                    var rowsAffected: Int?
                    var truncated = false
                    do {
                        let stream = connection.stream(SQLStatement(statement.text), batchSize: options.batchSize)
                        for try await batch in stream {
                            if !sentColumns, !batch.columns.isEmpty {
                                sentColumns = true
                                continuation.yield(.columns(index: index, batch.columns))
                            }
                            var rows = batch.rows
                            if let limit = options.rowLimit, rowCount + rows.count > limit {
                                rows = Array(rows.prefix(limit - rowCount))
                                truncated = true
                            }
                            if !rows.isEmpty {
                                rowCount += rows.count
                                continuation.yield(.rows(index: index, rows))
                            }
                            rowsAffected = batch.rowsAffected ?? rowsAffected
                            // Leaving the loop ends the stream, which stops the statement.
                            if truncated { break }
                        }
                        if Task.isCancelled { break }
                        continuation.yield(.finished(index: index, Outcome(
                            rowCount: rowCount, rowsAffected: rowsAffected, truncated: truncated,
                            duration: clock.now - start)))
                    } catch {
                        if Task.isCancelled || error is CancellationError { break }
                        let position = (error as? DatabaseError).flatMap { $0.sql == statement.text ? $0.position : nil }
                        continuation.yield(.failed(index: index, Failure(
                            message: message(error), position: position, duration: clock.now - start)))
                        if options.stopOnError {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                }
                if !Task.isCancelled { continuation.yield(.done) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? DatabaseError)?.message ?? error.localizedDescription
    }
}

/// The statements Run Current and Run All pick from the editor.
public enum ScriptSelection {
    /// The selected text's statements when something is selected, else the statement at the
    /// cursor. Ranges are UTF-16 offsets into `text`.
    public static func current(in text: String, selection: Range<Int>, dialect: LexerDialect) -> [SQLStatementRange] {
        if !selection.isEmpty { return statements(in: text, within: selection, dialect: dialect) }
        return SQLSplitter.statement(at: selection.lowerBound, in: text, dialect: dialect).map { [$0] } ?? []
    }

    /// Every statement, or only the selected ones when there is a selection.
    public static func all(in text: String, selection: Range<Int>, dialect: LexerDialect) -> [SQLStatementRange] {
        if !selection.isEmpty { return statements(in: text, within: selection, dialect: dialect) }
        return SQLSplitter.split(text, dialect: dialect)
    }

    /// Splits just the selected text; ranges are shifted back into `text`.
    private static func statements(in text: String, within selection: Range<Int>, dialect: LexerDialect) -> [SQLStatementRange] {
        let units = Array(text.utf16)
        let clamped = selection.clamped(to: 0..<units.count)
        let part = String(decoding: units[clamped], as: UTF16.self)
        return SQLSplitter.split(part, dialect: dialect).map { s in
            var s = s
            s.range = (s.range.lowerBound + clamped.lowerBound)..<(s.range.upperBound + clamped.lowerBound)
            s.fullRange = (s.fullRange.lowerBound + clamped.lowerBound)..<(s.fullRange.upperBound + clamped.lowerBound)
            return s
        }
    }
}
