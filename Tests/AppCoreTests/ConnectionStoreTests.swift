import Foundation
import Testing
@testable import AppCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "tabula-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "connections.json")
}

@MainActor
@Suite struct ConnectionStoreTests {
    @Test func missingFileIsEmpty() throws {
        let store = ConnectionStore(fileURL: tempFile())
        try store.load()
        #expect(store.connections.isEmpty)
    }

    @Test func roundTripsAndSortsByName() throws {
        let url = tempFile()
        let store = ConnectionStore(fileURL: url)
        let b = ConnectionConfig(name: "beta", filePath: "/tmp/b.db")
        let a = ConnectionConfig(name: "Alpha", filePath: "/tmp/a.db", readOnly: true)
        try store.save(b)
        try store.save(a)

        let reloaded = ConnectionStore(fileURL: url)
        try reloaded.load()
        #expect(reloaded.connections == [a, b])
    }

    @Test func saveReplacesById() throws {
        let store = ConnectionStore(fileURL: tempFile())
        var c = ConnectionConfig(name: "one", filePath: "/tmp/1.db")
        try store.save(c)
        c.name = "renamed"
        try store.save(c)
        #expect(store.connections.map(\.name) == ["renamed"])
    }

    @Test func deleteAndDuplicate() throws {
        let store = ConnectionStore(fileURL: tempFile())
        let c = ConnectionConfig(name: "main", filePath: "/tmp/m.db")
        try store.save(c)
        let copy = try #require(try store.duplicate(id: c.id))
        #expect(copy.id != c.id)
        #expect(store.connections.map(\.name) == ["main", "main copy"])
        try store.delete(id: c.id)
        #expect(store.connections.map(\.id) == [copy.id])
    }

    @Test func unreadableFileThrowsAndIsNotOverwritten() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = ConnectionStore(fileURL: url)
        #expect(throws: ConnectionStore.StoreError.self) { try store.load() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")

        let backup = try store.moveAsideUnreadableFile()
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
        try store.load()
        #expect(store.connections.isEmpty)
    }

    @Test func newerFormatIsRejected() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "connections": []}"#.utf8).write(to: url)
        let store = ConnectionStore(fileURL: url)
        #expect(throws: ConnectionStore.StoreError.self) { try store.load() }
    }

    @Test func missingOptionalFieldsGetDefaults() throws {
        let json = #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "driver": "sqlite"}"#
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        #expect(c.name == "")
        #expect(c.filePath == "")
        #expect(c.readOnly == false)
        #expect(c.displayName == "Untitled")
    }

    @Test func displayNameFallsBackToFileName() {
        let c = ConnectionConfig(filePath: "/data/app.sqlite", readOnly: true)
        #expect(c.displayName == "app.sqlite")
        #expect(c.summary == "SQLite · /data/app.sqlite · read-only")
    }

    @Test func openedFilesKeepTheirIDAcrossOpens() {
        let a = ConnectionConfig.sqliteFile(URL(filePath: "/tmp/x/../app.db"))
        let b = ConnectionConfig.sqliteFile(URL(filePath: "/tmp/app.db"))
        #expect(a.id == b.id)
        #expect(a.filePath == "/tmp/app.db")
        #expect(ConnectionConfig.sqliteFile(URL(filePath: "/tmp/other.db")).id != a.id)
    }
}
