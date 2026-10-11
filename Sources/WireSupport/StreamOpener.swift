import Foundation

/// A byte stream to a server that something else carries, such as an SSH tunnel: one end of a
/// connected socket pair, the other end held by the carrier.
public struct OpenedStream: Sendable {
    /// Ours to read and write; the channel built on it takes ownership.
    public var descriptor: Int32
    /// Why the stream ended, once it has (the carrier's own error output). Asked for when the
    /// server side closes, so "the connection closed" can say what actually went wrong.
    public var diagnostics: @Sendable () async -> String?

    public init(descriptor: Int32, diagnostics: @escaping @Sendable () async -> String? = { nil }) {
        self.descriptor = descriptor
        self.diagnostics = diagnostics
    }
}

/// Opens a new stream to the same server each time a session (or a cancel request) connects.
/// Compared by identity.
public final class StreamOpener: Sendable, Hashable, CustomStringConvertible {
    /// For messages, e.g. `db.internal:5432 via ssh deploy@bastion`.
    public let description: String
    /// The database server's own host name, for TLS (SNI and verify-full); nil for IP literals.
    public let hostName: String?
    private let opener: @Sendable () async throws -> OpenedStream

    public init(description: String, hostName: String?, open: @escaping @Sendable () async throws -> OpenedStream) {
        self.description = description
        self.hostName = hostName.flatMap { Endpoint.isIPAddress($0) ? nil : $0 }
        self.opener = open
    }

    public func open() async throws -> OpenedStream { try await opener() }

    public static func == (a: StreamOpener, b: StreamOpener) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
