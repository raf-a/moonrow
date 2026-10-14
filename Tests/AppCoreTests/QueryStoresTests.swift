import DBKit
import DriverSQLite
import Foundation
import Testing
@testable import AppCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "moonrow-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
@Suite struct QueryHistoryTests {
    @Test func newestFirstOncePerStatement() {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "select 1", date: Date(timeIntervalSince1970: 1)))
        history.add(.init(sql: "  select 2\n", date: Date(timeIntervalSince1970: 2), ms: 5))
        history.add(.init(sql: "select 1", date: Date(timeIntervalSince1970: 3), ok: false))
        history.add(.init(sql: "   "))
        #expect(history.entries.map(\.sql) == ["select 1", "select 2"])
        #expect(history.entries[0].ok == false)

        let reloaded = QueryHistory(fileURL: url)
        #expect(reloaded.entries == history.entries)
        #expect(reloaded.entries[1].ms == 5)
    }

    @Test func multiLineStatementsSurviveAndSearchIgnoresCase() {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "SELECT *\nFROM Users\nWHERE id = 1"))
        history.add(.init(sql: "select * from orders"))
        let reloaded = QueryHistory(fileURL: url)
        #expect(reloaded.search("from users").map(\.sql) == ["SELECT *\nFROM Users\nWHERE id = 1"])
        #expect(reloaded.search("").count == 2)
    }

    @Test func compactsPastTheLimit() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url, limit: 10)
        for i in 0..<30 { history.add(.init(sql: "select \(i)")) }
        #expect(history.entries.count == 10)
        #expect(history.entries.first?.sql == "select 29")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count <= 11)
        #expect(QueryHistory(fileURL: url, limit: 10).entries.map(\.sql) == history.entries.map(\.sql))
    }

    @Test func skipsUnreadableLines() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "select 1"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        history.add(.init(sql: "select 2"))
        #expect(QueryHistory(fileURL: url).entries.map(\.sql) == ["select 2", "select 1"])
    }

    @Test func dateGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_028_800)  // 2026-10-03 12:00 UTC
        func entry(_ daysAgo: Double, _ sql: String) -> QueryHistory.Entry {
            .init(sql: sql, date: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let groups = QueryHistory.grouped(
            [entry(0, "a"), entry(0.2, "b"), entry(1, "c"), entry(3, "d"), entry(10, "e"), entry(40, "f"), entry(45, "g"), entry(80, "h")],
            now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August 2026", "July 2026"])
        #expect(groups.map { $0.entries.map(\.sql).joined() } == ["ab", "c", "d", "e", "fg", "h"])
    }

    @Test func removeAndClear() throws {
        let url = tempDir().appending(path: "h.jsonl")
        let history = QueryHistory(fileURL: url)
        history.add(.init(sql: "a"))
        history.add(.init(sql: "b"))
        try history.remove(history.entries[0])
        #expect(QueryHistory(fileURL: url).entries.map(\.sql) == ["a"])
        try history.clear()
        #expect(QueryHistory(fileURL: url).entries.isEmpty)
    }
}

@MainActor
@Suite struct SavedQueriesTests {
    @Test func saveListRenameDelete() throws {
        let store = SavedQueries(directory: tempDir())
        #expect(store.queries.isEmpty)
        let q = try store.save("select 1", as: "Daily totals")
        try store.save("select 2", as: "active users.sql")
        #expect(store.queries.map(\.name) == ["active users", "Daily totals"])
        #expect(try store.text(of: q) == "select 1")

        #expect(throws: SavedQueries.StoreError.self) { try store.save("x", as: "daily totals") }
        try store.save("select 3", as: "Daily totals", overwrite: true)
        #expect(try store.text(of: store.query(named: "Daily totals")!) == "select 3")

        let renamed = try store.rename(store.query(named: "Daily totals")!, to: "Totals by day")
        #expect(store.queries.map(\.name) == ["active users", "Totals by day"])
        #expect(throws: SavedQueries.StoreError.self) { try store.rename(renamed, to: "Active Users") }
        // Changing only the case is allowed.
        try store.rename(renamed, to: "totals by day")
        #expect(store.queries.map(\.name) == ["active users", "totals by day"])

        try store.delete(store.queries[0], trash: false)
        #expect(store.queries.map(\.name) == ["totals by day"])
    }

    @Test func folders() throws {
        let dir = tempDir()
        let store = SavedQueries(directory: dir)
        try store.save("select 1", as: "top")
        let monthly = try store.save("select 2", as: "monthly", in: "Reports")
        #expect(store.folders == ["Reports"])
        #expect(monthly.path == "Reports/monthly")
        #expect(store.queries.map(\.path) == ["top", "Reports/monthly"])
        // Names are per folder.
        try store.save("select 3", as: "monthly")
        #expect(store.query(path: "Reports/monthly")?.url.deletingLastPathComponent().lastPathComponent == "Reports")
        #expect(try store.text(of: store.query(path: "monthly")!) == "select 3")

        #expect(throws: SavedQueries.StoreError.self) { try store.move(store.query(path: "monthly")!, to: "Reports") }
        let moved = try store.move(store.query(path: "top")!, to: "Reports")
        #expect(moved.path == "Reports/top")
        try store.addFolder("Empty")
        #expect(store.folders == ["Empty", "Reports"])
        #expect(throws: SavedQueries.StoreError.self) { try store.addFolder("reports") }
        let renamed = try store.renameFolder("Reports", to: "Monthly reports")
        #expect(store.queries(in: renamed).map(\.name) == ["monthly", "top"])
        try store.deleteFolder(renamed, trash: false)
        #expect(store.folders == ["Empty"])
        #expect(store.queries.map(\.path) == ["monthly"])
        // A reopened store reads the same.
        #expect(SavedQueries(directory: dir).folders == ["Empty"])
    }

    @Test func putBackAndSearch() throws {
        let store = SavedQueries(directory: tempDir())
        let q = try store.save("select * from orders", as: "daily")
        try store.save("select 1", as: "other")
        #expect(store.queries.filter { store.matches($0, "ORDERS") }.map(\.name) == ["daily"])
        #expect(store.queries.filter { store.matches($0, "oth") }.map(\.name) == ["other"])
        #expect(store.queries.filter { store.matches($0, "") }.count == 2)

        let elsewhere = tempDir()
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let aside = elsewhere.appending(path: "daily.sql")
        try FileManager.default.moveItem(at: q.url, to: aside)
        store.reload()
        try store.putBack(aside, to: q.url)
        #expect(store.queries.map(\.name) == ["daily", "other"])
        // Nothing is overwritten.
        try Data("x".utf8).write(to: aside)
        #expect(throws: (any Error).self) { try store.putBack(aside, to: q.url) }
    }

    @Test func fileNames() {
        #expect(SavedQueries.fileName(for: "  a/b:c  ") == "a-b-c")
        #expect(SavedQueries.fileName(for: "..hidden.sql") == "hidden")
        #expect(SavedQueries.fileName(for: " ") == "")
        #expect(throws: SavedQueries.StoreError.self) { try SavedQueries(directory: tempDir()).save("x", as: "...") }
    }

    @Test func locationOfAFile() {
        let dir = tempDir()
        let store = SavedQueries(directory: dir)
        #expect(store.location(of: dir.appending(path: "daily.sql")) ?? ("?", "?") == ("", "daily"))
        #expect(store.location(of: dir.appending(path: "Reports/monthly.SQL")) ?? ("?", "?") == ("Reports", "monthly"))
        // Two folders down, another extension or another directory: a plain file.
        #expect(store.location(of: dir.appending(path: "Reports/2026/q1.sql")) == nil)
        #expect(store.location(of: dir.appending(path: "notes.txt")) == nil)
        #expect(store.location(of: tempDir().appending(path: "daily.sql")) == nil)
    }

    @Test func offersToSaveOnClose() {
        #expect(SavedQueries.offersToSave("select 1;", keptAs: []))
        #expect(!SavedQueries.offersToSave(" \n\t", keptAs: []))
        #expect(!SavedQueries.offersToSave("select 1;", keptAs: [nil, "select 1;"]))
        #expect(SavedQueries.offersToSave("select 1;\n", keptAs: ["select 1;", nil]))
    }
}

@MainActor
private final class ChangeCounter: NSObject {
    var own = 0
    var external = 0
    @objc func changed(_ note: Notification) {
        if SavedQueries.isExternal(note) { external += 1 } else { own += 1 }
    }
}

@MainActor
@Suite struct SavedQueriesFolderTests {
    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func files(in dir: URL) -> [String] {
        SavedQueries.contents(of: dir).queries.map { $0.folder.isEmpty ? $0.url.lastPathComponent : $0.folder + "/" + $0.url.lastPathComponent }.sorted()
    }

    @Test func directories() {
        let root = URL(filePath: "/data", directoryHint: .isDirectory)
        var c = ConnectionConfig(name: "Shop: prod", driver: .postgres)
        #expect(SavedQueries.directory(root: root, for: c).path == "/data/Queries/Shop- prod")
        c.queriesFolder = "Shared"
        #expect(SavedQueries.directory(root: root, for: c).path == "/data/Queries/Shared")
        c.queriesFolder = "/work/repo/sql/"
        #expect(SavedQueries.directory(root: root, for: c).path == "/work/repo/sql")
        c.queriesFolder = "~/sql"
        #expect(SavedQueries.directory(root: root, for: c).path == NSHomeDirectory() + "/sql")
        #expect(SavedQueries.defaultFolder(for: ConnectionConfig(driver: .postgres, host: "db")) == "db")
    }

    @Test func folderChangeCountsQueriesAndOtherUsers() throws {
        let root = tempDir()
        let staging = ConnectionConfig(name: "Staging", queriesFolder: "Staging")
        let twin = ConnectionConfig(name: "Staging 2", queriesFolder: "Staging")
        let queries = SavedQueries.queriesRoot(root)
        try write("select 1", "Staging/a.sql", in: queries)
        try write("select 2", "Staging/Reports/b.sql", in: queries)
        var moved = staging
        moved.name = "Staging renamed"
        #expect(SavedQueries.folderChange(from: staging, to: moved, among: [staging], root: root) == nil)
        moved.queriesFolder = "Shared"
        let change = try #require(SavedQueries.folderChange(from: staging, to: moved, among: [staging, twin], root: root))
        #expect(change.count == 2)
        #expect(change.sharedWith == ["Staging 2"])
        #expect(change.destination.lastPathComponent == "Shared")
        #expect(SavedQueries.folderChange(from: staging, to: moved, among: [staging], root: root)?.sharedWith == [])
    }

    @Test func moveMergesFoldersAndNumbersTakenNames() throws {
        let root = tempDir()
        let source = root.appending(path: "Queries/Staging", directoryHint: .isDirectory)
        let destination = root.appending(path: "Queries/Shared", directoryHint: .isDirectory)
        try write("staging top", "top.sql", in: source)
        try write("staging report", "Reports/report.sql", in: source)
        try FileManager.default.createDirectory(at: source.appending(path: "Empty"), withIntermediateDirectories: true)
        try write("shared report", "Reports/report.sql", in: destination)
        try write("not a query", "notes.txt", in: source)

        let moved = try SavedQueries.transfer(.move, from: source, to: destination, removeSource: true)
        #expect(files(in: destination) == ["Reports/report 2.sql", "Reports/report.sql", "top.sql"])
        #expect(SavedQueries.contents(of: destination).folders == ["Empty", "Reports"])
        #expect(try String(contentsOf: destination.appending(path: "Reports/report.sql"), encoding: .utf8) == "shared report")
        #expect(try String(contentsOf: destination.appending(path: "Reports/report 2.sql"), encoding: .utf8) == "staging report")
        #expect(moved == ["top": "top", "Reports/report": "Reports/report 2"])
        // The emptied folders go; the source stays for the file that isn't a query.
        #expect(files(in: source).isEmpty)
        #expect(SavedQueries.contents(of: source).folders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "notes.txt").path))
    }

    @Test func copyLeavesTheSourceAndAMoveCanRemoveIt() throws {
        let root = tempDir()
        let source = root.appending(path: "a", directoryHint: .isDirectory)
        let destination = root.appending(path: "b", directoryHint: .isDirectory)
        try write("select 1", "q.sql", in: source)
        let copied = try SavedQueries.transfer(.copy, from: source, to: destination)
        #expect(copied.count == 1)
        #expect(files(in: source) == ["q.sql"] && files(in: destination) == ["q.sql"])

        let other = root.appending(path: "c", directoryHint: .isDirectory)
        try SavedQueries.transfer(.move, from: source, to: other)
        #expect(FileManager.default.fileExists(atPath: source.path))
        try write("select 2", "r.sql", in: source)
        try SavedQueries.transfer(.move, from: source, to: other, removeSource: true)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(files(in: other) == ["q.sql", "r.sql"])
    }

    @Test func aDestinationInsideTheSourceIsNotOneOfItsFolders() throws {
        let source = tempDir()
        let destination = source.appending(path: "Inner", directoryHint: .isDirectory)
        try write("select 1", "q.sql", in: source)
        try write("select 2", "Inner/old.sql", in: source)
        try SavedQueries.transfer(.move, from: source, to: destination)
        #expect(files(in: destination) == ["old.sql", "q.sql"])
    }

    @Test func legacyFoldersAreKept() throws {
        let root = tempDir()
        let store = ConnectionStore(fileURL: root.appending(path: "connections.json"))
        let old = ConnectionConfig(name: "Shop", driver: .postgres)
        let new = ConnectionConfig(name: "Shop", driver: .mysql)
        let chosen = ConnectionConfig(name: "Chosen", queriesFolder: "~/elsewhere")
        for config in [old, new, chosen] { try store.save(config) }
        let queries = SavedQueries.queriesRoot(root)
        try write("select 1", "\(old.id.uuidString)/report.sql", in: queries)

        try SavedQueries.adoptLegacyFolders(store: store, root: root)
        #expect(store.connection(id: old.id)?.queriesFolder == old.id.uuidString)
        #expect(store.connection(id: new.id)?.queriesFolder == "Shop")
        #expect(store.connection(id: chosen.id)?.queriesFolder == "~/elsewhere")
        #expect(files(in: SavedQueries.directory(root: root, for: store.connection(id: old.id)!)) == ["report.sql"])
        #expect(SavedQueries.contents(of: queries).folders == [old.id.uuidString])
    }

    @Test func changesOnDiskAreNoticed() async throws {
        let dir = tempDir()
        let store = SavedQueries(directory: dir)
        let counter = ChangeCounter()
        NotificationCenter.default.addObserver(counter, selector: #selector(ChangeCounter.changed(_:)), name: SavedQueries.didChange, object: store)
        // Its own writes aren't reported again by the watcher.
        try store.save("select 1", as: "mine")
        try await Task.sleep(for: .seconds(1))
        #expect(counter.own == 1 && counter.external == 0)

        try write("select 2", "Reports/theirs.sql", in: dir)
        for _ in 0..<50 where counter.external == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.external == 1)
        #expect(store.queries.map(\.path) == ["mine", "Reports/theirs"])
    }
}

@MainActor
@Suite struct SchemaCatalogTests {
    @Test func loadsColumnsOnDemand() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        _ = try await db.execute("CREATE TABLE users (id INTEGER, email TEXT)")
        let catalog = SchemaCatalog(connection: db)
        catalog.setObjects(try await db.objects(schema: nil))
        #expect(catalog.completionCatalog.tables == ["users"])
        var changes = 0
        catalog.onChange = { changes += 1 }
        catalog.loadColumns(of: ["USERS", "missing"])
        catalog.loadColumns(of: ["users"])
        await catalog.idle()
        #expect(changes == 1)
        #expect(catalog.completionCatalog.columns(of: "Users") == ["id", "email"])
    }
}
