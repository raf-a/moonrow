import AppCore
import AppKit
import DBKit

// M8's navigation through real mouse and key events where routing matters: preview tabs from
// sidebar clicks, Open in New Tab, Quick Open, Back / Forward, panes and workspace cycling. It
// leaves a known layout behind, saved as the session, for `TABULA_SESSION=check`.

extension DevHarness {
    static func navigationDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.displayIfNeeded()
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        try await makeKey(window)
        _ = try await waitFor("items") { workspace.environment.catalog.objects.isEmpty ? nil : true }
        let others = workspace.environment.catalog.objects
            .filter { SidebarViewController.opensInGrid($0) && $0.ref.name != table && $0.ref.name != "empty_table" }
            .map(\.ref.name).sorted()
        guard others.count >= 2, workspace.environment.catalog.objects.contains(where: { $0.ref.name == "empty_table" }) else {
            throw HarnessError("the database needs empty_table and two more tables or views besides \(table)")
        }
        let (second, third) = (others[0], others[1])
        let outline = try require(descendant(of: workspace.sidebar.view, SidebarOutline.self), "items list")

        func pressMenu(_ action: Selector, in target: NSWindow? = nil) async throws {
            try await DevHarness.pressMenu(action, in: target ?? window)
        }
        func click(item name: String, count: Int) async throws {
            // Another app coming to the front would take the click.
            if !window.isKeyWindow { try await makeKey(window) }
            let row = try require((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarViewController.Item).map { $0.newTableID == nil && $0.object.ref.name == name } ?? false
            }, "sidebar row \(name)")
            let rect = outline.rect(ofRow: row)
            let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            func mouse(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
                try require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1), "mouse event")
            }
            for clicks in 1...count {
                // The view's tracking loop takes the mouse-up from the queue.
                NSApp.postEvent(try mouse(.leftMouseUp, clicks: clicks), atStart: false)
                NSApp.sendEvent(try mouse(.leftMouseDown, clicks: clicks))
                try await Task.sleep(for: .milliseconds(40))
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        var titles: [String] { workspace.content.tabs.map { $0.isPreview ? "_\($0.tabItem.title)_" : $0.tabItem.title } }
        var currentTitle: String? { workspace.content.current?.tabItem.title }
        func loaded() async throws {
            let data = try await waitFor("table view") { workspace.tableController }
            _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        }

        // Preview tabs.
        try await click(item: table, count: 1)
        try await loaded()
        try check(titles == ["_\(table)_"], "a single click opens a preview tab \(titles)")
        try check(workspace.content.current?.tabItem.italic == true, "the preview tab's title is in italics")
        try check(window.firstResponder === outline, "the focus stays in the items list")
        try await click(item: second, count: 1)
        try await loaded()
        try check(titles == ["_\(second)_"], "the next single click replaces the preview \(titles)")
        snap("1-preview.png", window)
        try await click(item: second, count: 2)
        try check(titles == [second], "a double-click keeps the tab \(titles)")
        try await click(item: third, count: 1)
        try await loaded()
        try check(titles == [second, "_\(third)_"], "a new preview opens to the right of the selected tab \(titles)")
        let data = try require(workspace.tableController, "\(third) data")
        data.tableView(data.grid, didClick: data.grid.tableColumns[0])
        try check(titles == [second, third], "sorting makes the preview a regular tab \(titles)")
        try await click(item: table, count: 1)
        try await loaded()
        try check(titles == [second, third, "_\(table)_"], "another preview \(titles)")
        try await pressMenu(#selector(TabulaActions.showTableStructure(_:)))
        try check(titles == [second, third, table] && workspace.tableTab?.mode == .structure,
                  "⌃⌘] switches to Structure and keeps the tab \(titles)")
        try await pressMenu(#selector(TabulaActions.showTableData(_:)))

        // The same table twice, then a preview kept by staging a change.
        try await click(item: table, count: 1)
        let openInNewTab = try require(outline.menu?.items.firstIndex { $0.title == "Open in New Tab" }, "Open in New Tab")
        outline.menu?.performActionForItem(at: openInNewTab)
        try await loaded()
        try check(titles == [second, third, table, table], "Open in New Tab adds a second \(table) tab \(titles)")
        try await click(item: "empty_table", count: 1)
        try await loaded()
        try check(titles.last == "_empty_table_", "empty_table previews \(titles)")
        try await pressMenu(#selector(TabulaActions.addRow(_:)))
        try check(titles.last == "empty_table" && !workspace.changes.isEmpty, "⌘I stages a row and keeps the tab \(titles)")
        workspace.discardChanges(nil)
        try check(workspace.changes.isEmpty, "discarded")
        snap("2-tabs.png", window)

        // Quick Open.
        try await pressMenu(#selector(TabulaActions.quickOpen(_:)))
        let picker = try await waitFor("Quick Open") { workspace.picker }
        try check(picker.isVisible, "⌘P shows Quick Open")
        picker.field.stringValue = String(second.prefix(3))
        picker.refresh()
        _ = try await waitFor("ranked rows") { picker.rows.first?.title == second ? true : nil }
        snap("3-quick-open.png", picker.panel)
        picker.choose()
        try check(currentTitle == second && workspace.picker == nil, "Return opens \(second) (its tab is selected)")
        try check(window.isKeyWindow, "the workspace has the keyboard back")

        // Back and forward over the tabs shown.
        let before = workspace.history.backList.count
        try await pressMenu(#selector(TabulaActions.goBack(_:)))
        try check(currentTitle == "empty_table", "⌃⌘← goes back to empty_table (now \(currentTitle ?? "-"))")
        try await pressMenu(#selector(TabulaActions.goForward(_:)))
        try check(currentTitle == second && workspace.history.backList.count == before, "⌃⌘→ goes forward to \(second)")
        // A closed tab comes back as a preview.
        try await pressMenu(#selector(TabulaActions.goBack(_:)))
        try await pressMenu(#selector(TabulaActions.closeTab(_:)))
        try check(!titles.contains { $0.contains("empty_table") } && currentTitle != "empty_table", "⌘W closes empty_table")
        let afterClose = currentTitle
        try await pressMenu(#selector(TabulaActions.goBack(_:)))
        try await loaded()
        try check(currentTitle == "empty_table" && titles.contains("_empty_table_"),
                  "back to a closed tab reopens its table in the preview tab \(titles)")
        try await pressMenu(#selector(TabulaActions.goForward(_:)))
        try check(currentTitle == afterClose, "forward returns to \(afterClose ?? "-")")

        // Panes.
        workspace.content.select(0)
        try await pressMenu(#selector(TabulaActions.splitPaneRight(_:)))
        try check(workspace.panes.panes.count == 2 && workspace.panes.activeIndex == 1, "⇧⌘D adds a pane on the right, active")
        try check(workspace.content.tabs.map(\.tabItem.title) == [second], "the new pane shows \(second) too")
        try await click(item: table, count: 1)
        try await loaded()
        try check(workspace.panes.panes[1].tabs.map(\.tabItem.title) == [second, table], "a click opens in the active pane")
        let changesBefore = workspace.changes.changeCount
        try await pressMenu(#selector(TabulaActions.selectPreviousPane(_:)))
        try check(workspace.panes.activeIndex == 0, "⌥⌘[ activates the left pane")
        try await pressMenu(#selector(TabulaActions.selectNextPane(_:)))
        try check(workspace.panes.activeIndex == 1 && workspace.changes.changeCount == changesBefore, "⌥⌘] activates the right pane")
        workspace.newQueryTab(nil)
        let query = try require(workspace.queryController, "query tab")
        query.editor.insertText("select 42 as answer;\n", replacementRange: NSRange(location: 0, length: 0))
        snap("4-panes.png", window)

        // Workspaces: a second window on the same file, then ⇧⌘] / ⇧⌘[.
        let url = URL(filePath: workspace.config.expandedFilePath)
        app.connect(ConnectionConfig.sqliteFile(url), presentingErrorsIn: nil)
        let other = try await waitFor("second workspace") { app.workspaces.count == 2 ? app.workspaces[1] : nil }
        let otherWindow = try require(other.window, "second window")
        _ = try await waitFor("second window key") { otherWindow.isKeyWindow ? true : nil }
        try check(otherWindow.tabGroup === window.tabGroup && window.tabbedWindows?.count == 2,
                  "a new connection opens as a tab of the workspace window")
        try await pressMenu(#selector(TabulaActions.selectNextWorkspace(_:)), in: otherWindow)
        try check(window.isKeyWindow, "⇧⌘] goes to the next workspace")
        try await pressMenu(#selector(TabulaActions.selectPreviousWorkspace(_:)))
        try check(otherWindow.isKeyWindow, "⇧⌘[ goes back")
        for title in ["View", "Window"] {
            let menu = NSApp.mainMenu?.items.first { $0.title == title }?.submenu
            menu?.update()
            print("\(title) menu: \(menu?.items.map { $0.title + ($0.keyEquivalent.isEmpty ? "" : " [\($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)]") } ?? [])")
        }
        let overview = try require(menuItem(NSApp.mainMenu, action: #selector(NSWindow.toggleTabOverview(_:))), "Show All Tabs")
        let views = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items ?? []
        try check(overview.keyEquivalentModifierMask == [.command, .shift] && views.filter { $0.action == overview.action }.count == 1
                  && views.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }.count == 1,
                  "View has Show All Tabs (⇧⌘\\) and Enter Full Screen, once each")
        otherWindow.performClose(nil)
        _ = try await waitFor("second workspace closed") { app.workspaces.count == 1 ? true : nil }
        // Open Connection (⇧⌘K): a sheet listing the saved connections; the choice opens as a tab.
        var saved = ConnectionConfig.sqliteFile(url)
        saved.name = "sample (saved)"
        try app.store.save(saved)
        try await pressMenu(#selector(TabulaActions.showConnections(_:)))
        let connections = try await waitFor("connection picker") { app.picker }
        try check(connections.window.sheetParent === window && connections.list.shownConnections == ["sample (saved)"],
                  "⇧⌘K shows the saved connections as a sheet \(connections.list.shownConnections)")
        if let snapshots { snapshot(connections.window, to: snapshots.appending(path: "6-open-connection.png")) }
        connections.search.stringValue = "nothing like it"
        connections.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try check(connections.list.shownConnections.isEmpty && connections.selected == nil, "the search filters the list")
        connections.search.stringValue = "sample"
        connections.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        connections.connect(nil)
        let tabbed = try await waitFor("workspace from the picker") { app.workspaces.count == 2 ? app.workspaces[1].window : nil }
        try check(tabbed.tabGroup === window.tabGroup && app.picker == nil, "Connect opens it as a tab of this window")
        tabbed.performClose(nil)
        _ = try await waitFor("tab closed") { app.workspaces.count == 1 ? true : nil }

        // File ▸ New Window: the welcome window; what it connects opens in a window of its own.
        try await makeKey(window)
        try await pressMenu(#selector(TabulaActions.newWindow(_:)))
        let welcome = try await waitFor("welcome window") { app.welcome?.window?.isVisible == true ? app.welcome : nil }
        try check(true, "⌥⌘N shows the welcome window")
        welcome.connect(saved)
        let separate = try await waitFor("new window") { app.workspaces.count == 2 ? app.workspaces[1].window : nil }
        try check(separate.tabGroup !== window.tabGroup && (separate.tabbedWindows ?? [separate]).count == 1,
                  "a connection from the welcome window opens in a window of its own")
        separate.performClose(nil)
        _ = try await waitFor("window closed") { app.workspaces.count == 1 ? true : nil }
        try app.store.delete(id: saved.id)
        window.makeKeyAndOrderFront(nil)

        // SQL files (File ▸ Open…, Finder, the Dock) open in a query tab named after the file.
        let sqlFile = app.dataRoot.appending(path: "report.sql")
        try "select count(*) from \(table);\n".write(to: sqlFile, atomically: true, encoding: .utf8)
        app.application(NSApp, open: [sqlFile])
        try check(currentTitle == "report.sql" && workspace.queryController?.editor.string.hasPrefix("select count(*)") == true,
                  "a .sql file opens in a query tab named after it")
        let tabCount = workspace.panes.allTabs.count
        workspace.content.select(0)
        app.application(NSApp, open: [sqlFile])
        try check(currentTitle == "report.sql" && workspace.panes.allTabs.count == tabCount, "opening it again selects its tab")
        let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items ?? []
        try check(fileMenu.contains { $0.title == "Open…" && $0.action == #selector(NSDocumentController.openDocument(_:)) }
                  && !fileMenu.contains { $0.title.hasPrefix("Open Database File") },
                  "File has Open… (SQL files) and no Open Database File…")

        // Leave a known layout for the relaunch check.
        app.saveSession()
        let expected = describe(workspace)
        print("session:\n\(expected)")
        let file = app.dataRoot.appending(path: "session-expected.txt")
        try expected.write(to: file, atomically: true, encoding: .utf8)
    }

    /// A key press sent through the app, so the menus' key equivalents see it first.
    static func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                      in target: NSWindow) async throws {
        // The app can lose activation between steps; a key event then goes nowhere.
        if !target.isKeyWindow || !NSApp.isActive {
            let responder = target.firstResponder
            try await makeKey(target)
            if let responder, target.firstResponder !== responder { target.makeFirstResponder(responder) }
        }
        let event = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "key event")
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(80))
    }

    /// A menu item's shortcut, as the menu has it (AppKit adapts some to the keyboard layout).
    static func pressMenu(_ action: Selector, in target: NSWindow) async throws {
        let item = try require(menuItem(NSApp.mainMenu, action: action), "menu item \(action)")
        let key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask
        if key.count == 1, key.first!.isUppercase { modifiers.insert(.shift) }
        let arrows: [String: UInt16] = ["\u{F702}": 123, "\u{F703}": 124]
        if arrows[key] != nil { modifiers.formUnion([.numericPad, .function]) }
        try await press(key, code: arrows[key] ?? 0, modifiers, in: target)
    }

    /// With `TABULA_CONNECT` to a server with several schemas: Quick Open finds `table` in
    /// another schema and opens it; Open Database (⌘K) switches to that schema and back.
    static func openDatabaseDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        try await makeKey(window)
        // The schema the workspace starts in.
        let start: String = try await waitFor("schemas") { workspace.sidebar.schemaNames.isEmpty ? nil : workspace.sidebar.schema }

        try await pressMenu(#selector(TabulaActions.quickOpen(_:)), in: window)
        let quick = try await waitFor("Quick Open") { workspace.picker }
        quick.field.stringValue = String(table.prefix(5))
        quick.refresh()
        let found = try await waitFor("\(table) in another schema") { quick.rows.first { $0.title == table } }
        if let snapshots { snapshot(quick.panel, to: snapshots.appending(path: "opendb-1-quick-open.png")) }
        try check(found.detail != start, "Quick Open lists \(table) from schema \(found.detail)")
        quick.choose()
        let tab = try await waitFor("\(table) tab") { workspace.tableTab.flatMap { $0.table.name == table ? $0 : nil } }
        try check(tab.table.schema == found.detail && !tab.isPreview, "Return opens \(found.detail).\(table) in a regular tab")

        try await pressMenu(#selector(TabulaActions.openDatabase(_:)), in: window)
        let picker = try await waitFor("Open Database") { workspace.picker }
        picker.field.stringValue = found.detail
        picker.refresh()
        _ = try await waitFor("schema row") { picker.rows.first?.title == found.detail ? true : nil }
        if let snapshots { snapshot(picker.panel, to: snapshots.appending(path: "opendb-2-picker.png")) }
        picker.choose()
        _ = try await waitFor("switched") { workspace.sidebar.schema == found.detail ? true : nil }
        let listed = try await waitFor("listed") { workspace.environment.catalog.objects.first { $0.ref.schema == found.detail } }
        try check(listed.ref.schema == found.detail, "⌘K switches the workspace to \(found.detail) and lists its items")
        if let snapshots, let w = workspace.window { snapshot(w, to: snapshots.appending(path: "opendb-3-switched.png")) }
        try await pressMenu(#selector(TabulaActions.openDatabase(_:)), in: window)
        let back = try await waitFor("Open Database") { workspace.picker }
        back.field.stringValue = start
        back.refresh()
        _ = try await waitFor("schema row") { back.rows.first?.title == start ? true : nil }
        back.choose()
        _ = try await waitFor("switched back") { workspace.sidebar.schema == start ? true : nil }
        print("ok: and back to \(start)")
    }

    /// Groups in the welcome window: listing, collapsing (kept in the store), searching by tag,
    /// moving a connection into a group, deleting a group. Start from an empty store.
    static func welcomeDemo(_ app: AppDelegate, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let store = app.store
        guard store.connections.isEmpty else { throw HarnessError("TABULA_WELCOME needs an empty store") }
        let production = try store.addGroup(named: "Production")
        let local = try store.addGroup(named: "Local")
        try store.save(ConnectionConfig(name: "shop prod", driver: .postgres, host: "db.example.com", user: "shop",
                                        database: "shop", tag: .production, groupID: production.id))
        let staging = ConnectionConfig(name: "shop staging", driver: .postgres, host: "staging.example.com", user: "shop",
                                       database: "shop", tag: .staging)
        try store.save(staging)
        try store.save(ConnectionConfig(name: "notes.db", filePath: "~/notes.db", groupID: local.id))
        app.showConnections(nil)
        let welcome = try require(app.welcome, "welcome window")
        let window = try require(welcome.window, "window")
        let outline = welcome.outline
        func rows() -> [String] { welcome.list.shownRows }
        try check(rows() == ["[Local]", "notes.db", "[Production]", "shop prod", "shop staging"],
                  "groups by name, then connections in no group \(rows())")
        if let snapshots { snapshot(window, to: snapshots.appending(path: "welcome-1-groups.png")) }

        let localNode = try require(outline.item(atRow: 0), "Local row")
        outline.collapseItem(localNode)
        try check(rows() == ["[Local]", "[Production]", "shop prod", "shop staging"] && store.group(id: local.id)?.isCollapsed == true,
                  "collapsing a group is kept with it")

        welcome.search.stringValue = "production"
        welcome.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try check(rows() == ["[Production]", "shop prod"], "search matches the tag; groups without a match hide \(rows())")
        welcome.search.stringValue = "staging.example"
        welcome.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try check(rows() == ["shop staging"], "search matches the host \(rows())")
        welcome.search.stringValue = ""
        welcome.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try check(rows() == ["[Local]", "[Production]", "shop prod", "shop staging"], "clearing the search keeps Local collapsed")

        try check(welcome.move([staging.id], to: production.id), "a connection moves into a group")
        try check(rows() == ["[Local]", "[Production]", "shop prod", "shop staging"]
                  && store.connections(in: production.id).count == 2, "shop staging is in Production \(rows())")
        if let snapshots { snapshot(window, to: snapshots.appending(path: "welcome-2-moved.png")) }
        try store.deleteGroup(production.id)
        try check(rows() == ["[Local]", "shop prod", "shop staging"], "deleting a group keeps its connections \(rows())")

        // With no workspace open, Open Connection is a window of its own, grouped like the list.
        app.showConnections(nil)
        let picker = try await waitFor("connection picker") { app.picker }
        try check(picker.window.sheetParent == nil && picker.window.isVisible && picker.list.shownRows == rows(),
                  "⇧⌘K without a workspace shows the picker on its own, listed as the welcome window lists them \(picker.list.shownRows)")
        try check(picker.selected?.name == "shop prod", "the first connection shown is selected (\(picker.selected?.name ?? "none"))")
        if let snapshots { snapshot(picker.window, to: snapshots.appending(path: "welcome-3-open-connection.png")) }
    }

    /// The window's panes and tabs as text: `*` marks the selected tab, `_x_` a preview, `[S]`
    /// Structure, `>` the active pane.
    static func describe(_ workspace: WorkspaceWindowController) -> String {
        var lines = ["schema: \(workspace.sidebar.schema ?? "-")"]
        for (n, pane) in workspace.panes.panes.enumerated() {
            let tabs = pane.tabs.enumerated().map { i, tab -> String in
                var t = tab.tabItem.title
                if let table = tab as? TableTabViewController, table.mode == .structure { t += " [S]" }
                if let q = tab as? QueryEditorViewController {
                    t += " “\(q.editor.string.trimmingCharacters(in: .whitespacesAndNewlines))”"
                }
                if tab.isPreview { t = "_\(t)_" }
                return (i == pane.selectedIndex ? "*" : "") + t
            }
            lines.append((n == workspace.panes.activeIndex ? "> " : "  ") + tabs.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func sessionCheck(_ app: AppDelegate, snapshots: URL?) async throws {
        let file = app.dataRoot.appending(path: "session-expected.txt")
        let expected = try String(contentsOf: file, encoding: .utf8)
        let workspace = try await waitFor("restored workspace") { app.workspaces.first }
        _ = try await waitFor("restored tabs") { workspace.panes.allTabs.isEmpty ? nil : true }
        // Let every tab settle (and the sidebar list).
        try await Task.sleep(for: .seconds(1))
        let restored = describe(workspace)
        print("restored:\n\(restored)")
        if let snapshots, let window = workspace.window {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            window.displayIfNeeded()
            snapshot(window, to: snapshots.appending(path: "5-restored.png"))
        }
        guard restored == expected else { throw HarnessError("the restored layout differs from\n\(expected)") }
        print("ok: the workspace came back as it was left")
    }
}
