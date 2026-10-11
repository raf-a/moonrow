import AppCore
import AppKit
import DBKit
import Darwin

/// Developer self-checks, off unless `TABULA_BENCH` or `TABULA_DEMO` names a table:
///
///     TABULA_BENCH=events TABULA_SNAPSHOTS=build/snapshots Tabula build/sample.sqlite
///     TABULA_DEMO=users TABULA_SNAPSHOTS=build/snapshots Tabula /tmp/copy-of-sample.sqlite
///     TABULA_QUERY=events TABULA_STORE=/tmp/tabula-dev/connections.json TABULA_SNAPSHOTS=… Tabula build/sample.sqlite
///     TABULA_CONNECT=postgres://postgres:tabula@127.0.0.1:55432/postgres TABULA_STORE=… TABULA_SNAPSHOTS=… Tabula
///     TABULA_FORM=mysql TABULA_STORE=… TABULA_SNAPSHOTS=… Tabula
///     TABULA_STRUCTURE=users TABULA_STORE=… TABULA_SNAPSHOTS=… Tabula /tmp/copy-of-sample.sqlite
///
/// The bench opens the table in the first workspace with every row in one page, scrolls it like
/// a fast trackpad, jumps to far-apart rows, prints timings and quits. The demo drives the grid's
/// editing UI (sort, filter, edit, insert, delete, preview, commit) and snapshots each step; it
/// COMMITS to the database, so point it at a copy. The query demo types a script into a query
/// tab (autocomplete included), runs it, cancels an endless query, saves a query and shows the
/// history; it only reads the database but writes history and saved queries next to
/// `TABULA_STORE`, which it requires. The structure demo edits a table's columns and indexes
/// through the structure editor, commits, then designs and creates a new table; it COMMITS DDL,
/// so point it at a copy (or a TABULA_CONNECT scratch database). Snapshots are rendered
/// in-process (no screen-recording permission needed).
@MainActor
enum DevHarness {
    static func runIfRequested(_ app: AppDelegate) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        let snapshots = env["TABULA_SNAPSHOTS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        // `TABULA_CONNECT=postgres://user:pw@host:port/db` opens a server workspace without saving
        // the connection; `TABULA_FORM=postgres` opens a new connection form for that driver.
        if let url = env["TABULA_CONNECT"] {
            guard env["TABULA_STORE"] != nil, let (config, password) = ConnectionConfig.parse(url: url) else {
                print("TABULA_CONNECT needs TABULA_STORE and a postgres:// or mysql:// URL")
                NSApp.terminate(nil)
                return
            }
            app.connect(config, password: .some(password), presentingErrorsIn: nil)
            // `TABULA_OPEN=schema.table` switches schema, opens the table and snapshots it.
            if let target = env["TABULA_OPEN"], let snapshots {
                Task {
                    do {
                        try await openAndSnapshot(app, target, snapshots: snapshots)
                    } catch {
                        print("open failed: \(error)")
                    }
                    NSApp.terminate(nil)
                }
                return
            }
        }
        if let driver = env["TABULA_FORM"].flatMap(DriverKind.init(rawValue:)) {
            app.editConnection(ConnectionConfig(driver: driver), isNew: true)
        }
        if let table = env["TABULA_QUERY"] {
            Task {
                do {
                    guard env["TABULA_STORE"] != nil else { throw HarnessError("TABULA_QUERY needs TABULA_STORE") }
                    try await queryDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("query demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let table = env["TABULA_STRUCTURE"] {
            Task {
                do {
                    try await structureDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("structure demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let table = env["TABULA_DEMO"] {
            Task {
                do {
                    try await demo(app, table: table, snapshots: snapshots)
                } catch {
                    print("demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let table = env["TABULA_BENCH"] else {
            if let snapshots { snapshotWindowsAndQuit(to: snapshots) }
            return
        }
        Task {
            do {
                try await run(app, table: table, snapshots: snapshots)
            } catch {
                print("bench failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func openAndSnapshot(_ app: AppDelegate, _ target: String, snapshots: URL) async throws {
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
        let table = parts.last!
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        if parts.count == 2 {
            _ = try await waitFor("schema \(parts[0])") { workspace.sidebar.switchSchema(to: parts[0]) ? true : nil }
        }
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        try await Task.sleep(for: .seconds(1.5))
        guard let window = workspace.window else { return }
        snapshot(window, to: snapshots.appending(path: "\(target).png"))
    }

    /// With only `TABULA_SNAPSHOTS` set: renders every visible window once launched, then quits.
    private static func snapshotWindowsAndQuit(to dir: URL) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                let name = window.title.isEmpty ? "window" : window.title
                snapshot(window, to: dir.appending(path: "\(i)-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func run(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow) {
            if let snapshots { snapshot(window, to: snapshots.appending(path: name)) }
        }

        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.tableController }
        _ = try await waitFor("first page") { data.cache }
        data.showAllRows()
        let cache = try await waitFor("all rows") { data.cache.flatMap { $0.rowCount == data.total ? $0 : nil } }
        let grid = data.grid
        _ = try await waitFor("first rows") { visibleLoaded(grid, cache) ? true : nil }
        snap("1-top.png", window)
        print("rows: \(cache.rowCount), columns: \(grid.numberOfColumns), visible rows: \(grid.rows(in: grid.visibleRect).length)")

        let scroll = try require(grid.enclosingScrollView, "scroll view")
        let clip = scroll.contentView
        let clock = ContinuousClock()

        // Continuous scrolling: 3 rows per 60 Hz frame, 10 seconds' worth.
        var frames: [Double] = []
        var pendingFrames = 0
        for _ in 0..<600 {
            let d = clock.measure {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 3 * grid.rowHeight))
                scroll.reflectScrolledClipView(clip)
                window.displayIfNeeded()
            }
            frames.append(d.ms)
            if !visibleLoaded(grid, cache) { pendingFrames += 1 }
            try await Task.sleep(for: .milliseconds(16))
        }
        frames.sort()
        print(String(format: "scroll 600 frames: p50 %.2f ms, p95 %.2f ms, max %.2f ms; frames with unloaded rows on screen: %d",
                     frames[300], frames[570], frames[599], pendingFrames))

        // Jumps, like dragging the scroller thumb: time until every visible row has data.
        let n = cache.rowCount
        for target in [n / 2, n - 1, n / 8, 0, n * 7 / 9, n - 1].filter({ $0 >= 0 }) {
            let start = clock.now
            let draw = clock.measure {
                grid.scrollRowToVisible(target)
                window.displayIfNeeded()
            }
            _ = try await waitFor("rows at \(target)") { visibleLoaded(grid, cache) ? true : nil }
            window.displayIfNeeded()
            print(String(format: "jump to row %7d: drawn in %.2f ms, data on screen after %.1f ms",
                         target, draw.ms, (clock.now - start).ms))
        }
        snap("2-bottom.png", window)
        print("blocks held: \(cache.loadedBlocks.count) (max \(cache.maxBlocks)), resident memory: \(residentMB()) MB")
    }

    /// Walks through every grid edit path with the real controls and prints what happens.
    private static func demo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.tableController }
        let grid = data.grid
        func loaded() async throws {
            _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(grid, $0) ? true : nil } }
            window.displayIfNeeded()
        }
        try await loaded()
        print("page: \(data.query.page.describe(total: data.total))")

        // Sort by the second column, descending (two header clicks).
        let second = grid.tableColumns[1]
        for _ in 0..<2 {
            let before = data.cache.map(ObjectIdentifier.init)
            data.tableView(grid, didClick: second)
            _ = try await waitFor("sorted page") { data.cache.map(ObjectIdentifier.init) != before ? true : nil }
            try await loaded()
        }
        print("sort: \(data.query.sort)")

        // Quick filter on the second column.
        data.toggleFilters(nil)
        let before = data.cache.map(ObjectIdentifier.init)
        data.filterBar.apply(FilterCondition(.column(second.title), .contains, "1"))
        _ = try await waitFor("filtered page") { data.cache.map(ObjectIdentifier.init) != before ? true : nil }
        try await loaded()
        print("filter: \(data.query.filter!) → \(data.total) rows")
        snap("1-sorted-filtered.png", window)

        // Edit a cell by typing, set one to NULL, delete a row, add a row.
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([0], byExtendingSelection: false)
        grid.focusedColumn = second.identifier
        grid.keyDown(with: try key("\r", code: 36))
        let editor = try require(window.firstResponder as? NSTextView, "field editor")
        editor.selectAll(nil)
        editor.insertText("edited by demo", replacementRange: editor.selectedRange())
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([1], byExtendingSelection: false)
        grid.focusedColumn = grid.tableColumns.last!.identifier
        data.setNull(nil)
        grid.selectRowIndexes([2], byExtendingSelection: false)
        data.deleteRows(nil)
        data.addRow(nil)
        if let field = window.firstResponder as? NSTextView {
            field.insertText("new row", replacementRange: field.selectedRange())
        }
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([3], byExtendingSelection: false)
        data.duplicateRows(nil)
        // The copy would repeat a UNIQUE value in the last column; clear it.
        grid.focusedColumn = grid.tableColumns.last!.identifier
        data.setNull(nil)
        window.displayIfNeeded()
        snap("2-staged-bottom.png", window)
        grid.scrollRowToVisible(0)
        window.displayIfNeeded()
        snap("2-staged-top.png", window)

        data.previewChanges(nil)
        try await Task.sleep(for: .milliseconds(300))
        let preview = NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
        snap("3-preview.png", preview)
        print("preview:")
        for line in data.browser!.preview(data.edits) { print("  \(line)") }

        let staged = data.cache.map(ObjectIdentifier.init)
        data.commitChanges(nil)
        do {
            _ = try await waitFor("reload after commit") { data.cache.map(ObjectIdentifier.init) != staged ? true : nil }
        } catch {
            snap("4-commit-failed.png", window)
            throw error
        }
        try await loaded()
        print("committed; staged changes left: \(data.edits.isEmpty ? 0 : 1), page: \(data.query.page.describe(total: data.total))")
        snap("4-committed.png", window)
    }

    /// Edits a table's structure through the editor's controls, commits, then creates a table.
    private static func structureDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.displayIfNeeded()
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let tab = try await waitFor("table tab") { workspace.tableTab }
        tab.switchTo(.structure)
        let s = try await waitFor("structure view") { tab.structure }
        let loaded = try await waitFor("structure") { s.editor }
        print("columns: \(loaded.columns.map(\.value.name)), indexes: \(loaded.indexes.map(\.value.name))")
        snap("1-structure.png", window)

        let grid = s.columnsGrid
        func typeIntoCell(row: Int, field: String, _ text: String) throws {
            window.makeFirstResponder(grid)
            grid.selectRowIndexes([row], byExtendingSelection: false)
            grid.focusedColumn = NSUserInterfaceItemIdentifier(field)
            grid.keyDown(with: try key("\r", code: 36))
            let editor = try require(window.firstResponder as? NSTextView, "field editor for \(field)")
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            window.makeFirstResponder(grid)
        }
        func toggle(row: Int, field: String) throws {
            window.makeFirstResponder(grid)
            grid.selectRowIndexes([row], byExtendingSelection: false)
            grid.focusedColumn = NSUserInterfaceItemIdentifier(field)
            grid.keyDown(with: try key("\r", code: 36))
        }

        // A new column with a default, a renamed column, a nullability flip and an index.
        let second = loaded.columns[1].value.name
        try typeIntoCell(row: 1, field: "name", second + "_renamed")
        if loaded.columns.count > 2, loaded.primaryKey.contains(loaded.columns[2].value.name) == false {
            try toggle(row: 2, field: "nullable")
        }
        grid.selectRowIndexes([grid.numberOfRows - 1], byExtendingSelection: false)
        s.addRow(nil)
        if let field = window.firstResponder as? NSTextView {
            field.selectAll(nil)
            field.insertText("demo_note", replacementRange: field.selectedRange())
        }
        window.makeFirstResponder(grid)
        let added = grid.numberOfRows - 1
        try typeIntoCell(row: added, field: "defaultValue", "pending")
        grid.selectRowIndexes([added], byExtendingSelection: false)
        s.addIndex(nil)
        window.makeFirstResponder(grid)
        snap("2-staged.png", window)

        s.previewChanges(nil)
        try await Task.sleep(for: .milliseconds(300))
        snap("3-preview.png", NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible })
        let editor = try require(s.editor, "editor")
        print("preview:\n" + (try editor.plan(for: workspace.connection.dialect).preview))

        s.commitChanges(nil)
        _ = try await waitFor("structure after commit") {
            s.editor.flatMap { $0.hasChanges ? nil : $0.original.columns.contains { $0.name == "demo_note" } ? $0 : nil }
        }
        let after = try require(s.editor, "editor")
        print("committed: columns \(after.original.columns.map(\.name)), indexes \(after.original.indexes.map(\.name))")
        snap("4-committed.png", window)

        tab.switchTo(.data)
        let data = try await waitFor("data view") { tab.data }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        snap("5-data.png", window)

        // A new table, named and created from the structure editor.
        workspace.newTable(nil)
        let newTab = try await waitFor("new table tab") { workspace.tableTab.flatMap { $0 === tab ? nil : $0 } }
        let ns = try await waitFor("new structure view") { newTab.structure }
        ns.nameField.stringValue = "demo_table"
        ns.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: ns.nameField))
        ns.addRow(nil)
        if let field = window.firstResponder as? NSTextView {
            field.selectAll(nil)
            field.insertText("title", replacementRange: field.selectedRange())
        }
        window.makeFirstResponder(ns.columnsGrid)
        snap("6-new-table.png", window)
        print("create:\n" + (try require(ns.editor, "new editor").plan(for: workspace.connection.dialect).preview))
        ns.commitChanges(nil)
        _ = try await waitFor("created table") { ns.editor.flatMap { $0.exists && !$0.hasChanges ? $0 : nil } }
        print("created: \(newTab.table)")
        snap("7-created.png", window)
    }

    /// Types a script into a query tab with autocomplete, runs it, cancels, saves, shows history.
    private static func queryDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("catalog") { workspace.environment.catalog.objects.isEmpty ? nil : true }
        workspace.newQueryTab(nil)
        let query = try require(workspace.queryController, "query tab")
        let editor = query.editor
        window.makeFirstResponder(editor)

        func type(_ text: String) {
            for ch in text {
                if ch == "\n" { editor.insertNewline(nil) } else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
            }
        }
        func popup() -> NSWindow? { NSApp.windows.first { $0 is NSPanel && $0.isVisible } }
        func shown(_ what: String) async throws -> [String] {
            _ = try await waitFor("completion list (\(what))") { query.isCompletionVisible ? true : nil }
            let names = query.completionItems.prefix(6).map { "\($0.text) (\($0.kind))" }
            print("completions after \(what): \(names.joined(separator: ", "))")
            return names
        }
        func idle() async throws {
            _ = try await waitFor("query to finish") { query.isRunning ? nil : true }
            window.displayIfNeeded()
        }

        // Table names after FROM, ranked by prefix.
        type("select * from " + table.prefix(2))
        _ = try await shown("FROM \(table.prefix(2))")
        snap("q1-editor.png", window)
        snap("q1-completion.png", popup())
        editor.keyDown(with: try key("\r", code: 36))
        // Columns through an alias, loaded on demand.
        type(" t where t.")
        _ = try await shown("alias t.")
        snap("q2-completion-columns.png", popup())
        editor.keyDown(with: try key("\t", code: 48))
        type(" is not null;\nselect count(*) as n from \(table);\nselect * from no_such_table;\n")
        print("script:\n\(editor.string)")

        // Run all: stops at the error, which shows in Messages.
        query.runAllQueries(nil)
        try await idle()
        print("run all: \(query.results.results.count) result tabs, rows \(query.results.results.map(\.rows.count)), messages shown: \(query.results.showsMessagesTab)")
        print(query.results.messagesText)
        snap("q3-run-all.png", window)

        // Run current with the cursor in the first statement.
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        query.runCurrentQuery(nil)
        try await idle()
        let first = try require(query.results.results.first, "result")
        print("run current: \(first.rows.count) rows, \(first.columns.count) columns, truncated: \(first.outcome?.truncated ?? false)")
        snap("q4-run-current.png", window)

        // An endless query, stopped.
        workspace.newQueryTab(nil)
        let endless = try require(workspace.queryController, "second query tab")
        endless.setText("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        endless.runCurrentQuery(nil)
        try await Task.sleep(for: .milliseconds(400))
        let clock = ContinuousClock()
        let start = clock.now
        endless.cancelQuery(nil)
        _ = try await waitFor("cancel") { endless.isRunning ? nil : true }
        print(String(format: "cancel took %.1f ms", (clock.now - start).ms))
        window.displayIfNeeded()
        snap("q5-cancelled.png", window)

        // Save the first query, then show Queries and History.
        let saved = try workspace.environment.savedQueries.save(editor.string, as: "Demo query", overwrite: true)
        query.savedQueryChanged(to: saved)
        workspace.showSavedQueries(nil)
        window.displayIfNeeded()
        snap("q6-saved-queries.png", window)
        workspace.showQueryHistory(nil)
        window.displayIfNeeded()
        print("history: \(workspace.environment.history.entries.count) entries, newest: \(workspace.environment.history.entries.first?.sql.prefix(60) ?? "")")
        snap("q7-history.png", window)

        // A table tab next to the query tabs.
        workspace.focusItemFilter(nil)
        _ = workspace.sidebar.select(named: table)
        let data = try await waitFor("table tab") { workspace.tableController }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        window.displayIfNeeded()
        print("tabs: \(workspace.content.tabs.map(\.tabItem.title))")
        snap("q8-tabs.png", window)
    }

    private static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "key event")
    }

    private static func visibleLoaded(_ grid: NSTableView, _ cache: RowCache) -> Bool {
        let r = grid.rows(in: grid.visibleRect)
        guard r.length > 0 else { return true }
        return cache.row(at: r.location) != nil && cache.row(at: min(cache.rowCount - 1, r.location + r.length - 1)) != nil
    }

    private static func waitFor<T>(_ what: String, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(15)
        while true {
            if let value = probe() { return value }
            guard Date() < deadline else { throw HarnessError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw HarnessError("no \(what)") }
        return value
    }

    /// Renders the window's frame view, toolbar included.
    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : -1
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Duration {
    fileprivate var ms: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
