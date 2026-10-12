import DBKit
import Foundation
import Testing
@testable import AppCore

private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "tabula-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: name)
}

private func table(_ name: String, schema: String? = nil) -> DatabaseObject {
    DatabaseObject(TableRef(schema: schema, name), kind: .table)
}

@Suite struct TabPlacementTests {
    typealias Tab = TabPlacement.Tab
    let users = table("users"), orders = table("orders"), items = table("items")

    @Test func singleClickOpensAPreviewToTheRightOfTheSelectedTab() {
        let tabs = [Tab(object: nil), Tab(object: users)]
        #expect(TabPlacement.place(orders, intent: .preview, in: tabs, selected: 0) == .insert(at: 1, preview: true))
        #expect(TabPlacement.place(orders, intent: .preview, in: [], selected: nil) == .insert(at: 0, preview: true))
        #expect(TabPlacement.place(orders, intent: .preview, in: tabs, selected: nil) == .insert(at: 2, preview: true))
    }

    @Test func theNextSingleClickReplacesThePreview() {
        let tabs = [Tab(object: users), Tab(object: orders, isPreview: true)]
        #expect(TabPlacement.place(items, intent: .preview, in: tabs, selected: 0) == .replacePreview(1))
    }

    @Test func anOpenTabIsSelectedAndARegularOneIsPreferred() {
        let tabs = [Tab(object: users, isPreview: true), Tab(object: orders), Tab(object: users)]
        #expect(TabPlacement.place(users, intent: .preview, in: tabs, selected: 1) == .select(2))
        #expect(TabPlacement.place(orders, intent: .preview, in: tabs, selected: 0) == .select(1))
        #expect(TabPlacement.place(users, intent: .regular, in: tabs, selected: 0) == .select(2))
    }

    @Test func doubleClickMakesThePreviewRegular() {
        let tabs = [Tab(object: users), Tab(object: orders, isPreview: true)]
        #expect(TabPlacement.place(orders, intent: .regular, in: tabs, selected: 1) == .promote(1))
        #expect(TabPlacement.place(orders, intent: .preview, in: tabs, selected: 0) == .select(1))
    }

    @Test func doubleClickOnAnotherItemLeavesThePreviewAlone() {
        let tabs = [Tab(object: users, isPreview: true)]
        #expect(TabPlacement.place(orders, intent: .regular, in: tabs, selected: 0) == .insert(at: 1, preview: false))
    }

    @Test func openInNewTabAlwaysAddsARegularTab() {
        let tabs = [Tab(object: users), Tab(object: orders)]
        #expect(TabPlacement.place(users, intent: .newTab, in: tabs, selected: 0) == .insert(at: 1, preview: false))
        #expect(TabPlacement.place(users, intent: .newTab, in: tabs, selected: 1) == .insert(at: 2, preview: false))
    }

    @Test func queryAndNewTableTabsNeverTakeAnObject() {
        let tabs = [Tab(object: nil), Tab(object: nil)]
        #expect(TabPlacement.place(users, intent: .preview, in: tabs, selected: 1) == .insert(at: 2, preview: true))
    }

    @Test func sameNameInAnotherSchemaIsAnotherObject() {
        let tabs = [Tab(object: table("users", schema: "a"))]
        #expect(TabPlacement.place(table("users", schema: "b"), intent: .preview, in: tabs, selected: 0)
            == .insert(at: 1, preview: true))
    }
}

@Suite struct NavigationHistoryTests {
    @Test func backAndForwardWalkTheVisits() {
        var h = NavigationHistory<String>()
        #expect(!h.canGoBack && !h.canGoForward)
        for p in ["a", "b", "c"] { h.visit(p) }
        #expect(h.goBack() == "b")
        #expect(h.goBack() == "a")
        #expect(h.goBack() == nil)
        #expect(h.current == "a")
        #expect(h.goForward() == "b")
        #expect(h.goForward() == "c")
        #expect(h.goForward() == nil)
        #expect(h.current == "c")
    }

    @Test func aNewVisitDropsTheForwardList() {
        var h = NavigationHistory<String>()
        for p in ["a", "b", "c"] { h.visit(p) }
        _ = h.goBack()
        h.visit("d")
        #expect(!h.canGoForward)
        #expect(h.backList == ["a", "b"])
        #expect(h.goBack() == "b")
    }

    @Test func revisitingTheCurrentPlaceRecordsNothing() {
        var h = NavigationHistory<String>()
        h.visit("a")
        h.visit("a")
        #expect(!h.canGoBack)
    }

    @Test func goneplacesAreSkippedAndDropped() {
        var h = NavigationHistory<String>()
        for p in ["a", "gone", "b"] { h.visit(p) }
        #expect(h.goBack { $0 != "gone" } == "a")
        #expect(h.forwardList == ["b"])
        #expect(h.goForward { $0 != "gone" } == "b")
        #expect(h.backList == ["a"])
    }

    @Test func removingPlacesMergesNeighbours() {
        var h = NavigationHistory<String>()
        for p in ["a", "x", "a", "x", "b"] { h.visit(p) }
        h.removeAll { $0 == "x" }
        #expect(h.backList == ["a"])
        #expect(h.current == "b")
    }

    @Test func replacingTheCurrentPlace() {
        var h = NavigationHistory<String>()
        for p in ["a", "b"] { h.visit(p) }
        _ = h.goBack()
        h.replaceCurrent(with: "a2")
        #expect(h.current == "a2")
        #expect(h.goForward() == "b")
        #expect(h.goBack() == "a2")
    }

    @Test func oldPlacesAreForgottenPastTheLimit() {
        var h = NavigationHistory<Int>(limit: 3)
        for p in 0..<10 { h.visit(p) }
        #expect(h.backList == [6, 7, 8])
    }
}

@Suite struct QuickOpenTests {
    let objects = [
        table("users", schema: "public"), table("user_roles", schema: "public"),
        DatabaseObject(TableRef(schema: "public", "active_users"), kind: .view),
        DatabaseObject(TableRef(schema: "public", "refresh_users"), kind: .function),
        table("users", schema: "audit"), table("orders", schema: "sales"),
        DatabaseObject(TableRef(schema: "public", "users_id_seq"), kind: .sequence),
    ]
    var items: [QuickOpen.Item] {
        QuickOpen.items(objects: objects, savedQueries: [
            SavedQueries.Query(name: "users report", url: URL(filePath: "/q/users report.sql"), modified: .now),
        ])
    }

    func names(_ query: String, schema: String? = "public", recent: [QuickOpen.Item] = []) -> [String] {
        QuickOpen.rank(items, query: query, currentSchema: schema, recent: recent).map(\.qualifiedName)
    }

    @Test func sequencesAreLeftOut() {
        #expect(!items.contains { $0.name == "users_id_seq" })
        #expect(items.count == 7)
    }

    @Test func prefixBeatsWordStartsBeatsFuzzy() {
        // Word starts (user_roles), then fuzzy matches: current schema first, tables before
        // views, functions and saved queries.
        #expect(names("usr") == ["public.user_roles", "public.users", "public.active_users", "public.refresh_users",
                                 "users report", "audit.users"])
        #expect(names("ur").prefix(1) == ["public.user_roles"])
    }

    @Test func currentSchemaThenKindThenLength() {
        #expect(names("users") == ["public.users", "users report", "audit.users", "public.active_users",
                                   "public.refresh_users", "public.user_roles"])
        #expect(names("users", schema: "audit").first == "audit.users")
    }

    @Test func recentItemsComeFirstWithinATier() {
        let audit = QuickOpen.Item(table("users", schema: "audit"))
        #expect(names("users", recent: [audit]).first == "audit.users")
        // Recency never lifts a weaker match.
        let roles = QuickOpen.Item(table("user_roles", schema: "public"))
        #expect(names("users", recent: [roles]).first == "public.users")
    }

    @Test func aDottedQueryMatchesTheSchema() {
        #expect(names("sal.ord") == ["sales.orders"])
        #expect(names("aud.") == ["audit.users"])
        #expect(names("pub.users") == ["public.users", "public.active_users", "public.refresh_users", "public.user_roles"])
    }

    @Test func emptyQueryListsRecentThenCurrentSchemaAlphabetically() {
        let orders = QuickOpen.Item(table("orders", schema: "sales"))
        let all = names("", recent: [orders])
        #expect(all.first == "sales.orders")
        #expect(Set(all[1...2]) == ["public.users", "public.user_roles"])
        #expect(all.last == "audit.users")
    }

    @Test func noMatchIsEmpty() {
        #expect(names("zzz").isEmpty)
    }
}

@MainActor
@Suite struct SessionStoreTests {
    @Test func roundTrips() throws {
        let store = SessionStore(fileURL: tempFile("session.json"))
        let session = WorkspaceSession(
            connectionID: UUID(), filePath: "/tmp/a.sqlite", schema: "public",
            panes: [
                .init(tabs: [.table(table("users", schema: "public"), isPreview: true),
                             .query(text: "select 1;\n", savedQuery: nil),
                             .table(DatabaseObject(TableRef("v"), kind: .view), structure: true)],
                      selected: 1),
                .init(tabs: [.query(text: "", savedQuery: "report"), .query(text: "select 2;", file: "/tmp/q.sql")], selected: 0),
            ],
            activePane: 1)
        try store.save([session])
        #expect(store.load() == [session])
        #expect(session.panes[0].tabs[2].object == DatabaseObject(TableRef("v"), kind: .view))
        #expect(session.panes[0].tabs[1].object == nil)
    }

    @Test func missingOrBrokenFilesReopenNothing() throws {
        let url = tempFile("session.json")
        #expect(SessionStore(fileURL: url).load().isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(SessionStore(fileURL: url).load().isEmpty)
    }

    @Test func unreadableEntriesAreSkipped() throws {
        let url = tempFile("session.json")
        let id = UUID()
        let json = """
        {"version": 1, "workspaces": [
          {"connectionID": "not a uuid"},
          {"connectionID": "\(id.uuidString)", "activePane": 7, "panes": [
            {"selected": 5, "tabs": [{"kind": "chart"}, {"kind": "table", "name": "users"}, {"kind": "query", "text": "x"}]}
          ]}
        ]}
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let loaded = SessionStore(fileURL: url).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].connectionID == id)
        #expect(loaded[0].activePane == 0)
        #expect(loaded[0].panes[0].tabs.map(\.kind) == [.table, .query])
        #expect(loaded[0].panes[0].selected == 1)
        #expect(loaded[0].panes[0].tabs[0].object == table("users"))
    }

    @Test func reopenWorkspacesDefaultsOn() throws {
        #expect(AppSettings().reopenWorkspaces)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reopenWorkspaces": false}"#.utf8))
        #expect(!off.reopenWorkspaces)
    }
}

@MainActor
@Suite struct ConnectionGroupTests {
    @Test func groupsRoundTripAndSortByName() throws {
        let url = tempFile("connections.json")
        let store = ConnectionStore(fileURL: url)
        let prod = try store.addGroup(named: "  Production ")
        let dev = try store.addGroup(named: "dev")
        let a = ConnectionConfig(name: "a", filePath: "/tmp/a.db")
        let b = ConnectionConfig(name: "b", filePath: "/tmp/b.db")
        try store.save(a)
        try store.save(b)
        try store.move([a.id], to: prod.id)
        try store.setGroup(dev.id, collapsed: true)

        let reloaded = ConnectionStore(fileURL: url)
        try reloaded.load()
        #expect(reloaded.groups.map(\.name) == ["dev", "Production"])
        #expect(reloaded.group(id: dev.id)?.isCollapsed == true)
        #expect(reloaded.connections(in: prod.id).map(\.id) == [a.id])
        #expect(reloaded.connections(in: nil).map(\.id) == [b.id])
    }

    @Test func deletingAGroupKeepsItsConnections() throws {
        let store = ConnectionStore(fileURL: tempFile("connections.json"))
        let g = try store.addGroup(named: "")
        #expect(g.name == "New Group")
        let a = ConnectionConfig(name: "a", filePath: "/tmp/a.db", groupID: g.id)
        try store.save(a)
        try store.deleteGroup(g.id)
        #expect(store.groups.isEmpty)
        #expect(store.connections.map(\.id) == [a.id])
        #expect(store.connections[0].groupID == nil)
    }

    @Test func renameAndUnknownGroups() throws {
        let store = ConnectionStore(fileURL: tempFile("connections.json"))
        let g = try store.addGroup(named: "x")
        try store.renameGroup(g.id, to: "  ")
        #expect(store.group(id: g.id)?.name == "x")
        try store.renameGroup(g.id, to: "Staging")
        #expect(store.group(id: g.id)?.name == "Staging")
        // A connection naming a group that isn't there is listed as ungrouped.
        try store.save(ConnectionConfig(name: "orphan", filePath: "/tmp/o.db", groupID: UUID()))
        #expect(store.connections(in: nil).map(\.name) == ["orphan"])
        // Moving into a group that isn't there does nothing.
        try store.move(store.connections.map(\.id), to: UUID())
        #expect(store.connections(in: g.id).isEmpty)
    }

    @Test func filesWithoutGroupsStayAsTheyWere() throws {
        let url = tempFile("connections.json")
        let store = ConnectionStore(fileURL: url)
        try store.save(ConnectionConfig(name: "a", filePath: "/tmp/a.db"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("groups"))
        #expect(!text.contains("groupID"))
    }
}
