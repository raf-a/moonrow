import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

/// Running Queries against the test servers: a sleeping statement on one session shows in the
/// list read from another, and Kill stops it while the session lives on.
@Suite struct ServerSessionsTests {
    static let servers = Backend.all.filter { $0.kind != .sqlite }

    private func open(_ backend: Backend) async throws -> any DatabaseConnection {
        let (config, password) = try #require(ConnectionConfig.parse(url: backend.url!.absoluteString))
        var c = config
        c.tlsMode = .disable
        return try await ConnectionFactory.open(c, password: password)
    }

    @Test(arguments: servers) func listsAndCancelsAnotherSessionsQuery(_ backend: Backend) async throws {
        let busy = try await open(backend)
        let watcher = try await open(backend)
        defer { Task { await busy.close(); await watcher.close() } }
        #expect(ServerSessions.isSupported(watcher))
        let busyID = try #require(await ServerSessions.ownID(of: busy))
        let sleep = backend.kind == .postgres ? "SELECT pg_sleep(30)" : "SELECT SLEEP(30)"
        let started = ContinuousClock.now
        let running = Task { try await busy.execute(sleep) }

        // Wait until the server shows it running.
        var found: ServerSession?
        for _ in 0..<50 {
            found = try await ServerSessions.list(on: watcher).first { $0.id == busyID }
            if found?.isIdle == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(found)
        #expect(!session.isIdle)
        #expect(session.query.lowercased().contains("sleep"))
        // The asking session isn't listed.
        let watcherID = try #require(await ServerSessions.ownID(of: watcher))
        #expect(try await ServerSessions.list(on: watcher).allSatisfy { $0.id != watcherID })

        try await ServerSessions.kill(busyID, terminate: false, on: watcher)
        let result = await running.result
        #expect(ContinuousClock.now - started < .seconds(20))
        if backend.kind == .postgres {
            // pg_cancel_backend: the statement fails with query_canceled.
            #expect(throws: (any Error).self) { try result.get() }
        } else {
            // KILL QUERY: SLEEP returns 1 early.
            #expect((try? result.get())?.rows.first?.first == .integer(1) || (try? result.get()) == nil)
        }
        // The session itself goes on.
        #expect(try await busy.execute("SELECT 1").rows.first?.first == .integer(1))
        #expect(ServerSessions.killSQL(7, terminate: true, on: watcher).contains("7"))
    }

    @Test func sqliteHasNoSessions() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(!ServerSessions.isSupported(db))
        await #expect(throws: (any Error).self) { try await ServerSessions.list(on: db) }
    }
}
