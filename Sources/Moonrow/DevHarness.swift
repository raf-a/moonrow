import AppCore
import AppKit
import DBKit
import Darwin

/// Developer self-checks, off unless `MOONROW_BENCH` or `MOONROW_DEMO` names a table:
///
///     MOONROW_BENCH=events MOONROW_SNAPSHOTS=build/snapshots Moonrow build/sample.sqlite
///     MOONROW_DEMO=users MOONROW_SNAPSHOTS=build/snapshots Moonrow /tmp/copy-of-sample.sqlite
///     MOONROW_QUERY=events MOONROW_STORE=/tmp/moonrow-dev/connections.json MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_CONNECT=postgres://postgres:moonrow@127.0.0.1:55432/postgres MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow
///     MOONROW_CONNECT=postgres://…@moonrow-test-pg:5432/postgres MOONROW_SSH=ssh://moonrow:moonrow@127.0.0.1:52222 MOONROW_STORE=… Moonrow
///     MOONROW_FORM=mysql MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow
///     MOONROW_STRUCTURE=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow /tmp/copy-of-sample.sqlite
///     MOONROW_SAFETY=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_PREFS=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_MCP=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_EXPORT=events MOONROW_STORE=… MOONROW_SNAPSHOTS=build/snapshots Moonrow build/sample.sqlite
///     MOONROW_IMPORT=empty_table=/tmp/rows.csv MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow /tmp/copy-of-sample.sqlite
///     MOONROW_STAGED=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_EDITING=notes MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow /tmp/copy-with-a-small-table.sqlite
///     MOONROW_NAVIGATE=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_SESSION=check MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow        (after MOONROW_NAVIGATE)
///     MOONROW_CONNECT=postgres://… MOONROW_OPENDB=far_away MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow
///     MOONROW_WELCOME=1 MOONROW_STORE=<empty dir>/connections.json MOONROW_SNAPSHOTS=… Moonrow
///     MOONROW_QUERIES=1 MOONROW_STORE=<empty dir>/connections.json MOONROW_SNAPSHOTS=… Moonrow build/sample.sqlite
///     MOONROW_OBJECTS=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow /tmp/copy-of-sample.sqlite   (or MOONROW_CONNECT to a scratch database)
///     MOONROW_TRANSFER=users MOONROW_STORE=… MOONROW_SNAPSHOTS=… Moonrow /tmp/copy-of-sample.sqlite  (or MOONROW_CONNECT to a scratch database)
///     MOONROW_FEED_URL=http://127.0.0.1:8000/appcast.xml MOONROW_STORE=… open build/copy/Moonrow.app
///     MOONROW_UPDATE=install MOONROW_FEED_URL=… MOONROW_STORE=… MOONROW_SNAPSHOTS=… open build/copy/Moonrow.app
///     MOONROW_UPDATE=check MOONROW_FEED_URL=… MOONROW_STORE=… open build/Moonrow.app
///
/// The bench opens the table in the first workspace with every row in one page, scrolls it like
/// a fast trackpad, jumps to far-apart rows, prints timings and quits. The demo drives the grid's
/// editing UI (sort, filter, edit, insert, delete, preview, commit) and snapshots each step; it
/// COMMITS to the database, so point it at a copy. The query demo types a script into a query
/// tab (autocomplete included), runs it, cancels an endless query, saves a query and shows the
/// history; it only reads the database but writes history and saved queries next to
/// `MOONROW_STORE`, which it requires. The structure demo edits a table's columns and indexes
/// through the structure editor, commits, then designs and creates a new table; it COMMITS DDL,
/// so point it at a copy (or a MOONROW_CONNECT scratch database). The safety demo walks safe mode's
/// levels in a query tab (reads pass, writes ask, a wrong password is refused, lowering the level
/// asks); its writes go to a TEMP table, so the file isn't changed. The preferences demo shows
/// each pane, rebinds Run All from the Keymap pane, switches theme, appearance and grid font, and
/// snapshots a workspace in the new style; it writes `settings.json` next to `MOONROW_STORE`,
/// which the safety and preferences demos require. The export demo opens the table, filters it,
/// and exports it through the export sheet as CSV, JSON and SQL into `MOONROW_SNAPSHOTS`
/// (snapshotting the sheet for each format). The import demo opens the table, loads the CSV file
/// into the import sheet, snapshots it and imports; it COMMITS, so point it at a copy. Snapshots
/// are rendered in-process (no screen-recording permission needed).
@MainActor
enum DevHarness {
    /// Saved workspaces reopen at launch only outside the harnesses (and in the relaunch check).
    static var allowsSessionRestore: Bool {
        let quiet: Set = ["MOONROW_STORE", "MOONROW_SNAPSHOTS", "MOONROW_SESSION", "MOONROW_FEED_URL", "MOONROW_BACKGROUND"]
        return !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("MOONROW_") && !quiet.contains($0) }
    }

    static func runIfRequested(_ app: AppDelegate) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        // The harnesses name their SQLite database on the command line. The app itself only
        // opens databases through connections.
        if !allowsSessionRestore {
            let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
                .map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            for url in files {
                var config = ConnectionConfig.sqliteFile(url)
                config.safeMode = app.settings.settings.defaultSafeMode
                app.connect(config, presentingErrorsIn: nil)
            }
        }
        let snapshots = env["MOONROW_SNAPSHOTS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        // `MOONROW_CONNECT=postgres://user:pw@host:port/db` opens a server workspace without saving
        // the connection; `MOONROW_FORM=postgres` opens a new connection form for that driver.
        if let url = env["MOONROW_CONNECT"] {
            guard env["MOONROW_STORE"] != nil, let (parsed, password) = ConnectionConfig.parse(url: url) else {
                print("MOONROW_CONNECT needs MOONROW_STORE and a postgres:// or mysql:// URL")
                NSApp.terminate(nil)
                return
            }
            var config = parsed
            // `MOONROW_SSH=ssh://user:pw@host:port` goes through that SSH server, trusting its key.
            var sshPassword: String?
            if let ssh = env["MOONROW_SSH"] {
                do {
                    sshPassword = try config.applySSH(url: ssh)
                    app.autoTrustHostKeys = true
                } catch {
                    print(error)
                }
            }
            app.connect(config, password: .some(password), sshPassword: sshPassword, presentingErrorsIn: nil)
            // `MOONROW_OPEN=schema.table` switches schema, opens the table and snapshots it.
            if let target = env["MOONROW_OPEN"], let snapshots {
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
        if let driver = env["MOONROW_FORM"].flatMap(DriverKind.init(rawValue:)) {
            var config = ConnectionConfig(driver: driver)
            if let ssh = env["MOONROW_SSH"] { _ = try? config.applySSH(url: ssh) }
            app.editConnection(config, isNew: true)
        }
        if let table = env["MOONROW_QUERY"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_QUERY needs MOONROW_STORE") }
                    try await queryDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("query demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        for (key, demo) in [("MOONROW_SAFETY", safetyDemo), ("MOONROW_PREFS", preferencesDemo), ("MOONROW_MCP", mcpDemo)] as [(String, (AppDelegate, String, URL?) async throws -> Void)] {
            guard let table = env[key] else { continue }
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("\(key) needs MOONROW_STORE") }
                    try await demo(app, table, snapshots)
                } catch {
                    print("\(key) demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // `MOONROW_UPDATE=install` installs the update `MOONROW_FEED_URL` offers; Sparkle relaunches the app.
        // `MOONROW_UPDATE=check` only shows the update, release notes and all, and leaves it up.
        if let mode = env["MOONROW_UPDATE"], ["install", "check"].contains(mode) {
            Task {
                do {
                    try await updateDemo(app, install: mode == "install", snapshots: snapshots)
                } catch {
                    print("update demo failed: \(error)")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        // `MOONROW_SHOW=Sample:users,events,?;Other` opens saved connections by name and, in each,
        // the tables listed (`?` is a query tab), then leaves the app running to be looked at.
        // `-users` marks a table for deletion, `~users` truncates it and `+` adds a new table, all
        // staged; `=users` selects it in the list, `#report` a saved query in the Queries pane, `!`
        // shows the History pane, and
        // `/text` searches the database for text and clicks the first result.
        // With `MOONROW_SNAPSHOTS` it renders the windows instead and quits.
        if let spec = env["MOONROW_SHOW"] {
            Task {
                do {
                    try await show(app, spec)
                } catch {
                    print("show failed: \(error)")
                }
                if let snapshots { snapshotWindowsAndQuit(to: snapshots) }
            }
            return
        }
        // Staged changes across pages, tabs and reloads, then discarded: it never commits.
        if let table = env["MOONROW_STAGED"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_STAGED needs MOONROW_STORE") }
                    try await stagedDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("staged demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // Preview tabs, Open in New Tab, Quick Open, Back / Forward, panes and workspaces, then the
        // session it leaves for `MOONROW_SESSION=check`. It never commits.
        if let table = env["MOONROW_NAVIGATE"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_NAVIGATE needs MOONROW_STORE") }
                    try await navigationDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("navigation demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // M9: cells, paste, Quick Filter, columns, the cell editor, Beautify, parameters, pinned
        // results and charts, the query log, saved-query folders, history groups, Running
        // Queries (servers). It stages edits and discards them; it never commits.
        if let table = env["MOONROW_POWER"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_POWER needs MOONROW_STORE") }
                    try await powerDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("power demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // M10: views, triggers, clones, routines, Search in Database and the diagram. It commits.
        if let table = env["MOONROW_OBJECTS"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_OBJECTS needs MOONROW_STORE") }
                    try await objectsDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("objects demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // M11: export, import, backup and restore. It commits.
        if let table = env["MOONROW_TRANSFER"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_TRANSFER needs MOONROW_STORE") }
                    try await transferDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("transfer demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let table = env["MOONROW_OPENDB"] {
            Task {
                do {
                    try await openDatabaseDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("open database demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // Saved queries on disk and the connection's queries folder. It writes connections and
        // queries into MOONROW_STORE's folder.
        if env["MOONROW_QUERIES"] != nil {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_QUERIES needs MOONROW_STORE") }
                    try await queriesFolderDemo(app, snapshots: snapshots)
                } catch {
                    print("queries folder demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // Connection groups in the welcome window. It writes connections into MOONROW_STORE.
        if env["MOONROW_WELCOME"] != nil {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_WELCOME needs MOONROW_STORE") }
                    try await welcomeDemo(app, snapshots: snapshots)
                } catch {
                    print("welcome demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // Run after MOONROW_NAVIGATE with the same MOONROW_STORE and no file: the workspace it left
        // must come back as it was.
        if env["MOONROW_SESSION"] == "check" {
            Task {
                do {
                    try await sessionCheck(app, snapshots: snapshots)
                } catch {
                    print("session check failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        // Undo, the sidebar's delete keys, adding rows by double-click, the right sidebar and the
        // Changes item, then ⌘S. It commits, so point it at a copy; the table should be small
        // enough to leave room below its rows.
        if let table = env["MOONROW_EDITING"] {
            Task {
                do {
                    guard env["MOONROW_STORE"] != nil else { throw HarnessError("MOONROW_EDITING needs MOONROW_STORE") }
                    try await editingDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("editing demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let table = env["MOONROW_STRUCTURE"] {
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
        if let table = env["MOONROW_EXPORT"] {
            Task {
                do {
                    try await exportDemo(app, table: table, snapshots: snapshots)
                } catch {
                    print("export demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let spec = env["MOONROW_IMPORT"] {
            Task {
                do {
                    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw HarnessError("MOONROW_IMPORT=<table>=<csv path>") }
                    try await importDemo(app, table: parts[0], file: URL(filePath: (parts[1] as NSString).expandingTildeInPath), snapshots: snapshots)
                } catch {
                    print("import demo failed: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let table = env["MOONROW_DEMO"] {
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
        guard let table = env["MOONROW_BENCH"] else {
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

    private static func show(_ app: AppDelegate, _ spec: String) async throws {
        for part in spec.split(separator: ";") {
            let fields = part.split(separator: ":", maxSplits: 1).map(String.init)
            let config = try require(app.store.connections.first { $0.name == fields[0] }, "saved connection \(fields[0])")
            app.connect(config, presentingErrorsIn: nil, placement: .window)
            let workspace = try await waitFor("workspace \(fields[0])") { app.workspaces.first { $0.config.id == config.id } }
            for name in fields.count > 1 ? fields[1].split(separator: ",").map(String.init) : [] {
                if name == "?" {
                    workspace.newQueryTab(nil)
                } else if name == "+" {
                    workspace.newTable(nil)
                } else if name.hasPrefix("/") {
                    _ = try await waitFor("tables") { workspace.environment.catalog.objects.isEmpty ? nil : true }
                    workspace.searchInDatabase(nil)
                    let search = workspace.leftSidebar.search
                    search.field.stringValue = String(name.dropFirst())
                    search.start(nil)
                    _ = try await waitFor("search results") { !search.isSearching && !search.results.isEmpty ? true : nil }
                    search.list.selectRowIndexes([0], byExtendingSelection: false)
                } else if name == "!" {
                    workspace.leftSidebar.show(.history)
                } else if name.hasPrefix("#") {
                    workspace.leftSidebar.show(.queries)
                    guard workspace.leftSidebar.queries.selectRow(String(name.dropFirst())) else {
                        throw HarnessError("no saved query \(name.dropFirst())")
                    }
                } else if let mark = name.first, "-~=".contains(mark) {
                    let object = try await waitFor("table \(name)") { workspace.sidebar.object(named: String(name.dropFirst())) }
                    switch mark {
                    case "-":
                        var deletion = SidebarViewController.Deletion()
                        deletion.objects = [object]
                        workspace.markForDeletion(deletion)
                    case "~":
                        let plan = try await ObjectActions.truncatePlan([object.ref], options: TruncateOptions(), on: workspace.connection)
                        workspace.changes.perform("Truncate Table", at: EditPlace(side: .sidebar, objects: [object])) {
                            workspace.changes.stage(StagedAction(.truncate, object, plan: plan))
                        }
                    default:
                        workspace.sidebar.reveal([object.ref])
                    }
                } else {
                    let object = try await waitFor("table \(name)") { workspace.sidebar.object(named: name) }
                    workspace.open(object, intent: .newTab, focus: false)
                }
            }
        }
    }

    /// With only `MOONROW_SNAPSHOTS` set: renders every visible window once launched, then quits.
    /// It also prints any editable field in them that wraps.
    private static func snapshotWindowsAndQuit(to dir: URL) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                let name = window.title.isEmpty ? "window" : window.title
                for field in wrappingFields(in: window.contentView) {
                    print("wrapping field in \(name): \(field.placeholderString ?? field.stringValue) (\(type(of: field)))")
                }
                snapshot(window, to: dir.appending(path: "\(i)-\(name).png"))
                // On macOS 26 the glass toolbar isn't in the window's capture; its items' views are.
                for item in window.toolbar?.items ?? [] {
                    guard let view = item.view else { continue }
                    snapshot(view, to: dir.appending(path: "\(i)-\(name)-\(item.itemIdentifier.rawValue).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Editable fields that wrap, so a long value grows them onto a second line. Token fields,
    /// and fields given a line limit, wrap on purpose.
    static func wrappingFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable, field.cell?.wraps == true,
           !(field is NSTokenField), field.maximumNumberOfLines == 0 {
            found.append(field)
        }
        for sub in view.subviews { found += wrappingFields(in: sub) }
        return found
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

        workspace.previewChanges(nil)
        try await Task.sleep(for: .milliseconds(300))
        snap("3-preview.png", window.attachedSheet)
        print("preview:\n" + (try workspace.changes.plan(dialect: workspace.connection.dialect).preview))

        let staged = data.cache.map(ObjectIdentifier.init)
        workspace.commitChanges(nil)
        do {
            _ = try await waitFor("reload after commit") { data.cache.map(ObjectIdentifier.init) != staged ? true : nil }
        } catch {
            snap("4-commit-failed.png", window)
            throw error
        }
        try await loaded()
        print("committed; staged changes left: \(workspace.changes.isEmpty ? 0 : 1), page: \(data.query.page.describe(total: data.total))")
        snap("4-committed.png", window)
    }

    /// Staged changes belong to the workspace (M6.5): an edit survives paging, closing the tab
    /// and reopening the table, and ⌘R; a truncate, a drop and a new table join it in one
    /// preview; Discard All drops everything. Nothing is committed.
    private static func stagedDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
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
        let changes = workspace.changes
        let ref = TableRef(schema: workspace.sidebar.schema, table)
        func open() async throws -> TableDataViewController {
            _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
            let data = try await waitFor("table view") { workspace.tableController.flatMap { $0.table.name == table ? $0 : nil } }
            _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
            return data
        }
        func pageChange(_ data: TableDataViewController, _ go: () -> Void) async throws {
            let before = data.cache.map(ObjectIdentifier.init)
            go()
            _ = try await waitFor("page") { data.cache.map(ObjectIdentifier.init) != before ? true : nil }
            _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        }

        var data = try await open()
        let grid = data.grid
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([0], byExtendingSelection: false)
        grid.focusedColumn = grid.tableColumns[1].identifier
        grid.keyDown(with: try key("\r", code: 36))
        let editor = try require(window.firstResponder as? NSTextView, "field editor")
        editor.selectAll(nil)
        editor.insertText("staged by demo", replacementRange: editor.selectedRange())
        window.makeFirstResponder(grid)
        let edited = try require(data.cache?.row(at: 0), "row 0")
        try check(data.edits.state(of: edited) == .edited, "row 0 is edited")

        try await pageChange(data) { data.nextPage(nil) }
        try check(data.edits.state(of: data.cache?.row(at: 0)) == .unchanged && data.edits.summary == "1 edited",
                  "page 2 shows other rows; the edit is still staged")
        try await pageChange(data) { data.previousPage(nil) }
        try check(data.edits.state(of: data.cache?.row(at: 0)) == .edited, "back on page 1 the edit shows again")

        workspace.closeTab(nil)
        try check(workspace.tableTab == nil && changes.edits(for: ref) != nil, "closing the tab keeps the edit, without asking")
        data = try await open()
        try check(data.edits.state(of: data.cache?.row(at: 0)) == .edited, "reopening the table shows the edit")
        snap("1-reopened.png", window)

        try await pageChange(data) { workspace.reloadWorkspace(nil) }
        try check(data.edits.state(of: data.cache?.row(at: 0)) == .edited, "⌘R keeps the edit")

        // The sidebar's Truncate and Delete stage what their dialogs worked out.
        let others = workspace.environment.catalog.objects.filter { $0.kind == .table && $0.ref.name != table }
        if let truncated = others.first {
            let plan = try await ObjectActions.truncatePlan([truncated.ref], options: TruncateOptions(), on: workspace.connection)
            changes.stage(StagedAction(.truncate, truncated, plan: plan))
        }
        if others.count > 1 {
            let plan = try await ObjectActions.dropPlan([others[1]], options: DropOptions(), on: workspace.connection)
            changes.stage(StagedAction(.drop, others[1], plan: plan))
        }
        workspace.newTable(nil)
        _ = try await waitFor("new table tab") { workspace.tableTab?.newTableID }
        snap("2-marks.png", window)
        let plan = try changes.plan(dialect: workspace.connection.dialect)
        print("preview:\n" + plan.preview)
        try check(plan.sections.count == 2 + min(2, others.count), "one preview covers every table")
        workspace.previewChanges(nil)
        try await Task.sleep(for: .milliseconds(300))
        snap("3-preview.png", window.attachedSheet)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        workspace.previewSheet = nil

        workspace.discardChanges(nil)
        try check(changes.isEmpty, "Discard All empties the workspace")
        try check(!workspace.tableTabs.contains { $0.newTableID != nil }, "the new table's tab closed")
        let shown = try await waitFor("table tab") { workspace.tableTabs.first { $0.table == ref }?.data }
        _ = try await waitFor("rows") { shown.cache.flatMap { visibleLoaded(shown.grid, $0) ? true : nil } }
        try check(shown.edits.state(of: shown.cache?.row(at: 0)) == .unchanged, "the grid shows the loaded value again")
        snap("4-discarded.png", window)
    }

    /// M7's workspace editing, through real key and mouse events where routing matters.
    private static func editingDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
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
        let changes = workspace.changes
        let undo = changes.undoManager
        /// A key press sent through the app, so menus' key equivalents see it first.
        func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) async throws {
            if !window.isKeyWindow || !NSApp.isActive {
                let responder = window.firstResponder
                try await makeKey(window)
                if let responder, window.firstResponder !== responder { window.makeFirstResponder(responder) }
            }
            let event = try require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "key event")
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        func undoKey() async throws { try await press("z", code: 6, .command) }
        func redoKey() async throws { try await press("Z", code: 6, [.command, .shift]) }
        func doubleClick(_ view: NSView, at point: NSPoint) async throws {
            let location = view.convert(point, to: nil)
            func mouse(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
                try require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1), "mouse event")
            }
            for clicks in [1, 2] {
                // The view's tracking loop takes the mouse-up from the queue.
                NSApp.postEvent(try mouse(.leftMouseUp, clicks: clicks), atStart: false)
                NSApp.sendEvent(try mouse(.leftMouseDown, clicks: clicks))
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        let outline = try require(descendant(of: workspace.sidebar.view, SidebarOutline.self), "items list")
        let filter = try require(descendant(of: workspace.sidebar.view, NSSearchField.self), "filter field")
        try check(window.firstResponder === outline, "the items list, not the filter, has the focus when the workspace opens")

        // Space and ⌥⌫ are menu shortcuts, but in a text field they still type.
        window.makeFirstResponder(filter)
        filter.currentEditor()?.insertText("ab cd")
        try await press(" ", code: 49)
        try check(filter.stringValue == "ab cd ", "Space types a space in a text field (got “\(filter.stringValue)”)")
        try await press("\u{7F}", code: 51, .option)
        try check(filter.stringValue == "ab ", "⌥⌫ deletes a word in a text field (got “\(filter.stringValue)”)")
        filter.stringValue = ""
        workspace.sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        // ⌫ on a table marks it for deletion at once; ⌘Z and ⇧⌘Z take it back and forth.
        _ = try await waitFor("sidebar items") { workspace.environment.catalog.objects.isEmpty ? nil : true }
        let victim = try require(workspace.environment.catalog.objects.first { $0.kind == .table && $0.ref.name != table }, "another table")
        workspace.sidebar.reveal([victim.ref])
        window.makeFirstResponder(outline)
        try await press("\u{7F}", code: 51)
        _ = try await waitFor("drop staged") { changes.mark(for: victim.ref) == .dropped ? true : nil }
        try check(undo.undoMenuItemTitle == "Undo Delete Table", "the step is “Delete Table”")
        let markedCell = outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? SidebarCell
        try check(markedCell?.accessibilityLabel() == "\(victim.ref.name), deleted", "VoiceOver reads the item as deleted")
        snap("1-marked.png", window)
        try await press("\u{7F}", code: 51)
        try await Task.sleep(for: .milliseconds(100))
        try check(changes.actions.count == 1 && undo.undoMenuItemTitle == "Undo Delete Table", "⌫ on a marked item adds nothing")
        try await undoKey()
        try check(changes.isEmpty, "⌘Z unmarks it")
        try await redoKey()
        try check(changes.mark(for: victim.ref) == .dropped, "⇧⌘Z marks it again")
        try await undoKey()
        // ⌘⌫ goes through Edit ▸ Delete, to the list while it has the focus.
        window.makeFirstResponder(outline)
        let deleteItem = try require(menuItem(NSApp.mainMenu, action: #selector(MoonrowActions.deleteRows(_:))), "Delete item")
        deleteItem.menu?.update()
        try check(deleteItem.isEnabled && deleteItem.title == "Delete Table", "Edit ▸ Delete Table is enabled while the list has the focus")
        // A synthetic ⌘⌫ matches no menu item (AppKit maps the real key itself), so the item's
        // action is sent once the item validates for the list.
        NSApp.sendAction(#selector(MoonrowActions.deleteRows(_:)), to: nil, from: deleteItem)
        _ = try await waitFor("drop staged by ⌘⌫") { changes.mark(for: victim.ref) == .dropped ? true : nil }
        try await undoKey()
        try check(changes.isEmpty, "⌘Z unmarks it again")

        // A new table; ⌫ removes it and closes its tab; ⌘Z brings both back.
        workspace.newTable(nil)
        let newID = try await waitFor("new table tab") { workspace.tableTab?.newTableID }
        try check(undo.undoMenuItemTitle == "Undo New Table", "New Table stages a new table")
        workspace.sidebar.reveal(newTable: newID)
        window.makeFirstResponder(outline)
        try await press("\u{7F}", code: 51)
        try check(changes.newTables.isEmpty && !workspace.tableTabs.contains { $0.newTableID != nil }, "⌫ removes the new table and closes its tab")
        try await undoKey()
        try check(changes.newTable(newID) != nil && workspace.tableTab?.newTableID == newID, "⌘Z brings back the table and its tab")
        // The list's Delete removes it too, with no dialog.
        workspace.sidebar.reveal(newTable: newID)
        let menu = try require(outline.menu, "the list's menu")
        let menuDelete = try require(menu.items.firstIndex { $0.action == NSSelectorFromString("deleteItem:") }, "Delete in the list's menu")
        menu.update()
        try check(menu.items[menuDelete].isEnabled && menu.items[menuDelete].title == "Delete", "the menu's Delete is enabled for a new table")
        menu.performActionForItem(at: menuDelete)
        _ = try await waitFor("new table removed by the menu") { changes.newTables.isEmpty ? true : nil }
        try await undoKey()
        try check(changes.newTable(newID) != nil, "⌘Z brings it back again")
        snap("2-new-table-back.png", window)
        // Its name can't be emptied or taken.
        let structure = try require(workspace.tableTab?.structure, "new table's structure")
        window.makeFirstResponder(structure.nameField)
        structure.nameField.currentEditor()?.selectAll(nil)
        structure.nameField.currentEditor()?.delete(nil)
        window.makeFirstResponder(structure.columnsGrid)
        try check(structure.nameField.stringValue == "untitled_table" && changes.newTable(newID)?.name == "untitled_table",
                  "an emptied name comes back")
        try await undoKey()
        try check(changes.newTables.isEmpty && workspace.tableTab?.newTableID == nil, "⌘Z undoes New Table and closes its tab")

        // The table's rows. ⌘Z while typing in a cell undoes the typing, not staged changes.
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.tableController.flatMap { $0.table.name == table ? $0 : nil } }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        let grid = data.grid
        try check(grid.numberOfRows >= 2, "\(table) has at least two rows")
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([0], byExtendingSelection: false)
        grid.focusedColumn = grid.tableColumns[1].identifier
        grid.keyDown(with: try key("\r", code: 36))
        let editor = try require(window.firstResponder as? NSTextView, "field editor")
        let before = editor.string
        editor.selectAll(nil)
        editor.insertText("typed", replacementRange: editor.selectedRange())
        try await undoKey()
        try check(editor.string == before && changes.isEmpty, "⌘Z in a cell undoes the typing")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        // Double-click below the last row adds one.
        window.makeFirstResponder(grid)
        let end = grid.rect(ofRow: grid.numberOfRows - 1).maxY
        try check(grid.bounds.height > end + 10, "room below the rows")
        try await doubleClick(grid, at: NSPoint(x: 20, y: end + 8))
        try check(data.edits.insertedRowCount == 1 && undo.undoMenuItemTitle == "Undo Add Row", "double-click below the rows adds one")
        if let cell = window.firstResponder as? NSTextView {
            cell.insertText("from double-click", replacementRange: cell.selectedRange())
            window.makeFirstResponder(grid)
        }
        snap("3-added-row.png", window)

        // Space opens the right sidebar; editing a field stages it for both selected rows.
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([0, 1], byExtendingSelection: false)
        if workspace.isInspectorVisible { workspace.toggleRightSidebar(nil) }
        try await press(" ", code: 49)
        try check(workspace.isInspectorVisible, "Space in the grid shows the right sidebar")
        let column = try require(data.browser?.columns.firstIndex { $0.primaryKeyPosition == nil && $0.typeName.uppercased().contains("TEXT") },
                                 "a text column")
        let field = try await waitFor("inspector field") {
            descendant(of: workspace.inspector.view, NSTextField.self) { $0.tag == column && $0.isEditable }
        }
        snap("4-inspector.png", window)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        field.currentEditor()?.insertText("set from the sidebar")
        window.makeFirstResponder(grid)
        try check(grid.selectedRowIndexes == [0, 1], "the rows stay selected")
        let rows = [0, 1].compactMap { data.cache?.row(at: $0) }
        try check(rows.allSatisfy { data.edits.change(in: $0, column: column) == .value(.text("set from the sidebar")) },
                  "one field edit stages both rows")
        try check(undo.undoMenuItemTitle == "Undo Edit Cells", "as one step")
        try await Task.sleep(for: .milliseconds(200))
        snap("5-inspector-edited.png", window)

        // Structure: double-click below the last column adds one; ⌘Z takes it away.
        workspace.tableTab?.switchTo(.structure)
        let s = try await waitFor("structure") { workspace.tableTab?.structure.flatMap { $0.editor != nil ? $0 : nil } }
        let columns = s.columnsGrid.numberOfRows
        window.makeFirstResponder(s.columnsGrid)
        try await doubleClick(s.columnsGrid, at: NSPoint(x: 20, y: s.columnsGrid.rect(ofRow: columns - 1).maxY + 8))
        window.makeFirstResponder(s.columnsGrid)
        try check(s.columnsGrid.numberOfRows == columns + 1, "double-click below the columns adds one")
        try await undoKey()
        try check(s.columnsGrid.numberOfRows == columns && changes.structure(for: data.table) == nil, "⌘Z removes it")
        workspace.tableTab?.switchTo(.data)

        // The Changes item counts what's staged; ⌘S commits from anywhere, here the sidebar.
        let item = try require(workspace.toolbarItem(.init("changes")), "Changes item")
        try check(item.isEnabled && workspace.shownChangeCount == changes.changeCount, "the toolbar shows \(changes.changeCount) changes")
        snap("6-before-commit.png", window)
        window.makeFirstResponder(outline)
        let oldCache = data.cache.map(ObjectIdentifier.init)
        try await press("s", code: 1, .command)
        _ = try await waitFor("commit") { changes.isEmpty ? true : nil }
        try check(!undo.canUndo && !item.isEnabled && workspace.shownChangeCount == 0, "after ⌘S nothing is staged and nothing can be undone")
        let reloaded = try await waitFor("reloaded rows") {
            data.cache.flatMap { ObjectIdentifier($0) != oldCache ? $0.row(at: 0) : nil }
        }
        try check(reloaded[column] == .text("set from the sidebar"), "the database has the new value")
        snap("7-committed.png", window)
    }

    static func descendant<T: NSView>(of view: NSView, _ type: T.Type, where match: (T) -> Bool = { _ in true }) -> T? {
        if let v = view as? T, match(v) { return v }
        for sub in view.subviews { if let found = descendant(of: sub, type, where: match) { return found } }
        return nil
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

        workspace.previewChanges(nil)
        try await Task.sleep(for: .milliseconds(300))
        snap("3-preview.png", window.attachedSheet)
        print("preview:\n" + (try workspace.changes.plan(dialect: workspace.connection.dialect).preview))

        workspace.commitChanges(nil)
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
        print("create:\n" + (try workspace.changes.plan(dialect: workspace.connection.dialect).preview))
        workspace.commitChanges(nil)
        _ = try await waitFor("created table") {
            newTab.newTableID == nil ? newTab.structure?.editor.flatMap { $0.exists && !$0.hasChanges ? $0 : nil } : nil
        }
        print("created: \(newTab.table)")
        snap("7-created.png", window)
    }

    /// Safe mode in a query tab: what passes, what asks, what a wrong password does.
    private static func safetyDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.displayIfNeeded()
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        let gate = workspace.safety
        workspace.newQueryTab(nil)
        let query = try require(workspace.queryController, "query tab")
        func run(_ sql: String) {
            query.setText(sql)
            query.runAllQueries(nil)
        }
        func finished() async throws -> String {
            _ = try await waitFor("run to finish") { query.isRunning ? nil : true }
            try await Task.sleep(for: .milliseconds(50))
            return query.results.messagesText.split(separator: "\n").last.map(String.init) ?? ""
        }
        func prompt() async throws -> SafetyPrompt {
            try await waitFor("safe mode prompt") { gate.prompt.flatMap { $0.sheet.isVisible ? $0 : nil } }
        }

        // What the password levels want: the password in MOONROW_CONNECT, else the connection's name.
        let answer = gate.credential.kind == .password
            ? ProcessInfo.processInfo.environment["MOONROW_CONNECT"].flatMap { ConnectionConfig.parse(url: $0)?.password } ?? ""
            : gate.connectionName
        /// Changes the level, giving the password when lowering it asks for one.
        func setLevel(_ level: SafeMode) async throws {
            let change = Task { await gate.change(to: level) }
            while gate.level != level {
                if let p = gate.prompt, p.sheet.isVisible { p.respond(password: answer) }
                try await Task.sleep(for: .milliseconds(20))
            }
            await change.value
        }
        print("starting level: \(gate.level.title)")
        try await setLevel(.alertWrites)
        print("level: \(gate.level.title)")
        run("select count(*) from \(table)")
        print("read under \(gate.level.title): prompt \(gate.prompt != nil ? "shown" : "not shown"); \(try await finished())")

        let script = "create temp table moonrow_safety_demo (x integer);\ninsert into moonrow_safety_demo values (1);\nselect * from moonrow_safety_demo"
        run(script)
        var p = try await prompt()
        snap("s1-confirm.png", window)
        snap("s1-confirm-sheet.png", p.sheet)
        p.cancel(nil)
        try await Task.sleep(for: .milliseconds(100))
        print("cancelled: running \(query.isRunning), results \(query.results.results.count)")
        run(script)
        p = try await prompt()
        p.respond(password: nil)
        print("confirmed: \(try await finished()); result rows \(query.results.results.first?.rows.count ?? -1)")

        try await setLevel(.password)
        print("level: \(gate.level.title) (credential: \(gate.credential.kind))")
        run("select count(*) from \(table)")
        p = try await prompt()
        p.respond(password: "wrong")
        print("wrong answer: sheet still open \(p.sheet.isVisible), error shown \(p.errorShown)")
        snap("s2-password.png", window)
        snap("s2-password-sheet.png", p.sheet)
        p.respond(password: answer)
        print("right answer: \(try await finished())")

        // Touch ID answers in place of the password (a stand-in here); a failed one leaves the
        // sheet and its password field.
        try app.settings.update { $0.safeModeTouchID = true }
        _ = try await waitFor("previous run done") { !query.isRunning && !query.isAwaitingApproval ? true : nil }
        let asked = HarnessLog()
        BiometricUnlock.override = { reason in
            asked.add(reason)
            return true
        }
        run("select count(*) from \(table)")
        _ = try await waitFor("Touch ID asked") { asked.lines.isEmpty ? nil : true }
        _ = try await waitFor("sheet closed") { gate.prompt == nil ? true : nil }
        print("touch id: \(try await finished()); asked \(asked.lines.count) time(s), to \(asked.lines.first ?? "-")")
        BiometricUnlock.override = { _ in false }
        _ = try await waitFor("previous run done") { !query.isRunning && !query.isAwaitingApproval ? true : nil }
        run("select count(*) from \(table)")
        p = try await prompt()
        try await Task.sleep(for: .milliseconds(100))
        snap("s2b-touch-id-sheet.png", p.sheet)
        print("touch id failed: sheet still open \(p.sheet.isVisible), Use Touch ID shown \(!p.touchIDButton.isHidden)")
        p.respond(password: answer)
        print("then the password: \(try await finished())")
        BiometricUnlock.override = nil
        try app.settings.update { $0.safeModeTouchID = false }

        let lowering = Task { await gate.change(to: .silent) }
        p = try await prompt()
        snap("s3-lowering-sheet.png", p.sheet)
        p.respond(password: answer)
        await lowering.value
        print("lowered to: \(gate.level.title)")
        snap("s4-toolbar.png", window)
    }

    /// Lines collected from callbacks.
    final class HarnessLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }

    /// Each settings pane, a rebinding from the Keymap pane, then a workspace in another style.
    private static func preferencesDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.displayIfNeeded()
            if let snapshots, let window { snapshot(window, to: snapshots.appending(path: name)) }
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        app.showPreferences(nil)
        let prefs = try await waitFor("settings window") { NSApp.windows.first { $0.windowController is PreferencesWindowController && $0.isVisible } }
        let controller = try require(prefs.windowController as? PreferencesWindowController, "settings controller")
        for (i, name) in ["p1-general", "p2-fonts", "p3-keymap"].enumerated() {
            controller.show(pane: i)
            try await Task.sleep(for: .milliseconds(500))
            let pane = controller.tabs.tabViewItems[i].viewController!.view
            print("\(name): content \(prefs.contentLayoutRect.size), pane needs \(pane.fittingSize)")
            snap("\(name).png", prefs)
        }

        // A two-line safe-mode hint grows the General pane, then a one-line one shrinks it back.
        controller.show(pane: 0)
        let popup = controller.general.safeModePopup
        for (mode, name) in [(SafeMode.alertWrites, "p1b-general-long-hint"), (.silent, "p1c-general-short-hint")] {
            popup.selectItem(at: SafeMode.allCases.firstIndex(of: mode) ?? 0)
            NSApp.sendAction(try require(popup.action, "popup action"), to: popup.target, from: popup)
            try await Task.sleep(for: .milliseconds(500))
            let pane = controller.general.view
            print("\(name): content \(prefs.contentLayoutRect.size), pane needs \(pane.fittingSize)")
            snap("\(name).png", prefs)
        }
        controller.show(pane: 2)
        try await Task.sleep(for: .milliseconds(500))

        // Scrolled partway, so a section header sits at the top of the list.
        let headerRow = try require(controller.keymap.row(ofGroup: "SQL Editor"), "SQL Editor header row")
        controller.keymap.table.scrollRowToVisible(controller.keymap.table.numberOfRows - 1)
        controller.keymap.table.scrollRowToVisible(headerRow)
        try await Task.sleep(for: .milliseconds(200))
        snap("p3b-keymap-scrolled.png", prefs)

        // Rebind Run All to ⌃⌘R with the recorder, as a key press would.
        let runAll = try require(Keymap.command("runAllQueries:"), "Run All command")
        let event = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0, windowNumber: prefs.windowNumber,
            context: nil, characters: "\u{12}", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15), "key event")
        print("recorded: \(ShortcutRecorder.key(for: event) ?? "?") with \(KeyBinding.Modifiers(event.modifierFlags))")
        controller.keymap.assign(KeyBinding(ShortcutRecorder.key(for: event) ?? "r", .init(event.modifierFlags)), to: runAll)
        // ⌘C is Copy's and is refused.
        controller.keymap.assign(KeyBinding("c"), to: runAll)
        try await Task.sleep(for: .milliseconds(200))
        snap("p4-keymap-changed.png", prefs)
        let item = menuItem(NSApp.mainMenu, action: #selector(MoonrowActions.runAllQueries(_:)))
        print("Run All in the menu: \(item.map { KeyBinding($0.keyEquivalent, .init($0.keyEquivalentModifierMask)).display } ?? "missing")")

        // The query tab is selected before the switch: its tab must follow the new appearance.
        prefs.close()
        let window = try require(workspace.window, "workspace window")
        try app.settings.update { $0.appearance = .light }
        workspace.newQueryTab(nil)
        let query = try require(workspace.queryController, "query tab")
        query.setText("-- paper theme, dark\nselect id, 'text' as s, 42 from \(table) where id > $1;")
        try await Task.sleep(for: .milliseconds(200))
        snap("p4b-light-editor.png", window)
        try app.settings.update {
            $0.appearance = .dark
            $0.editorTheme = EditorTheme.paper.id
            $0.editorFontSize = 15
            $0.gridFontSize = 14
            $0.alternatingRows = false
        }
        try await Task.sleep(for: .milliseconds(200))
        snap("p5-dark-editor.png", window)
        _ = workspace.sidebar.select(named: table)
        let data = try await waitFor("table tab") { workspace.tableController }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        print("grid row height: \(data.grid.rowHeight)")
        snap("p6-dark-grid.png", window)
        try app.settings.update { $0 = AppSettings() }
    }

    static func menuItem(_ menu: NSMenu?, action: Selector) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(item.submenu, action: action) { return found }
        }
        return nil
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

        try await editorChecks(workspace, table: table, snap: snap)
    }

    /// Exports a filtered table as CSV, JSON and SQL through the export sheet.
    private static func exportDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        let dir = try require(snapshots, "MOONROW_SNAPSHOTS (where the files go)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.tableController }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        // Rows whose id ends in 7, newest first.
        let before = data.cache.map(ObjectIdentifier.init)
        data.toggleFilters(nil)
        data.filterBar.apply(FilterCondition(.column("id"), .hasSuffix, "7"))
        _ = try await waitFor("filtered page") { data.cache.map(ObjectIdentifier.init) != before ? true : nil }
        _ = try await waitFor("filtered rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        window.displayIfNeeded()
        print("filter: \(data.query.filter!) → \(data.total) rows")

        workspace.exportData(nil)
        let sheet = try await waitFor("export sheet") { window.attachedSheet?.windowController as? ExportSheetController }
        for (i, ext) in ["csv", "json", "sql"].enumerated() {
            sheet.selectFormat(i)
            snapshot(sheet.window!, to: dir.appending(path: "export-\(i + 1)-\(ext)-sheet.png"))
            let url = dir.appending(path: "\(table).\(ext)")
            var outcome: Result<Int, any Error>?
            sheet.onFinish = { outcome = $0 }
            sheet.export(to: url)
            let result = try await waitFor("\(ext) export") { outcome }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("\(ext): \(try result.get()) rows, \(size) bytes → \(url.path)")
            if i == 2 { snapshot(sheet.window!, to: dir.appending(path: "export-4-done.png")) }
        }
        sheet.close()
    }

    /// Imports a CSV file into a table through the import sheet.
    private static func importDemo(_ app: AppDelegate, table: String, file: URL, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let tab = try await waitFor("table tab") { workspace.tableTab }
        let data = try await waitFor("table view") { tab.data }
        _ = try await waitFor("rows") { data.cache }
        let before = data.total
        let sheet = try require(workspace.importFile(.csv, into: DatabaseObject(tab.table, kind: .table), file: file), "import sheet")
        _ = try await waitFor("parsed file") { sheet.preview.isEmpty || sheet.columns.isEmpty ? nil : true }
        let names = sheet.columnNames
        print("file: columns \(names), first \(sheet.preview.count) rows previewed")
        print("mapping: \(zip(sheet.columns.map(\.name), sheet.mapping).map { "\($0) ← \($1.map { names[$0] } ?? "-")" })")
        try await Task.sleep(for: .milliseconds(200))
        if let snapshots { snapshot(sheet.window!, to: snapshots.appending(path: "import-1-sheet.png")) }
        var outcome: Result<Int, any Error>?
        sheet.onFinish = { outcome = $0 }
        sheet.startImport()
        let result = try await waitFor("import") { outcome }
        switch result {
        case .success(let n): print("imported \(n) rows")
        case .failure(let error):
            if let snapshots { snapshot(sheet.window!, to: snapshots.appending(path: "import-2-failed.png")) }
            throw error
        }
        let reloaded = try await waitFor("reloaded rows") { tab.data.flatMap { $0.cache != nil && $0.total != before ? $0 : nil } }
        _ = try await waitFor("rows on screen") { reloaded.cache.flatMap { visibleLoaded(reloaded.grid, $0) ? true : nil } }
        window.displayIfNeeded()
        print("\(table): \(before) → \(reloaded.total) rows")
        if let snapshots { snapshot(window, to: snapshots.appending(path: "import-2-table.png")) }
    }

    static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "key event")
    }

    static func visibleLoaded(_ grid: NSTableView, _ cache: RowCache) -> Bool {
        let r = grid.rows(in: grid.visibleRect)
        guard r.length > 0 else { return true }
        return cache.row(at: r.location) != nil && cache.row(at: min(cache.rowCount - 1, r.location + r.length - 1)) != nil
    }

    /// Synthetic events only reach the key window, and a click on another window only makes it key.
    static func makeKey(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        _ = try await waitFor("key window") {
            if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            return window.isKeyWindow ? true : nil
        }
    }

    static func waitFor<T>(_ what: String, seconds: Double = 15, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = probe() { return value }
            guard Date() < deadline else { throw HarnessError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw HarnessError("no \(what)") }
        return value
    }

    /// Renders the window's frame view, toolbar included.
    static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        snapshot(view, to: url)
    }

    static func snapshot(_ view: NSView, to url: URL) {
        guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
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

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Duration {
    fileprivate var ms: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
