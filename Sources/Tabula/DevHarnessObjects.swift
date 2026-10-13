import AppCore
import AppKit
import DBKit

extension DevHarness {
    /// `TABULA_OBJECTS=<table>`: M10's schema objects through the real controls. It commits:
    /// point it at a copy of a SQLite file or a scratch server database. `table` needs a text
    /// column and at least one row. Steps: a new view from the sidebar's New menu (typed, ⇧⌘P,
    /// ⌘S); editing its definition in the view's Definition side (undo, redo, ⌘S); a trigger
    /// added and deleted in Structure ▸ Triggers; Clone… with rows; on servers a function,
    /// its edit and its deletion, and on Postgres a materialized view refreshed; Search in
    /// Database showing a table's results in a tab; Show Diagram.
    static func objectsDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow?) {
            window?.layoutIfNeeded()
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
        let connection = workspace.connection
        let dialect = connection.dialect
        let isServer = !(dialect is SQLiteDialect)
        func key(_ action: Selector) async throws { try await pressMenu(action, in: window) }
        /// Types `text` over everything in a SQL editor, as the keyboard would.
        func type(_ text: String, into editor: NSTextView) {
            window.makeFirstResponder(editor)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func commit(_ what: String) async throws {
            try await key(#selector(TabulaActions.commitChanges(_:)))
            _ = try await waitFor("\(what) committed") { changes.isEmpty && !workspace.isCommitting ? true : nil }
            print("ok: ⌘S commits \(what)")
        }
        func listed(_ name: String, _ kind: ObjectKind) async throws -> DatabaseObject {
            try await waitFor("\(name) in the sidebar") {
                workspace.environment.catalog.objects.first { $0.ref.name == name && $0.kind == kind }
            }
        }
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let tableObject = try await listed(table, .table)
        let data = try await waitFor("table view") { workspace.tableController }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        let columns = try require(data.browser?.columns, "columns")
        let textColumn = try require(columns.first { c in
            let t = c.typeName.lowercased()
            return c.primaryKeyPosition == nil && (t.contains("char") || t.contains("text"))
        }, "a text column in \(table)")
        let q = dialect.quoteIdentifier
        let value = try require(data.cache?.row(at: 0)?[columns.firstIndex(of: textColumn)!], "a value to search for")
        let term = String(value.displayString.prefix(6))

        // MARK: A new view, from the + menu
        let newMenu = try require(descendant(of: workspace.sidebar.view, NSPopUpButton.self) { $0.toolTip == "New view, function or procedure" },
                                  "New pull-down")
        let viewItem = try require(newMenu.menu?.items.firstIndex { $0.title == "View" }, "New ▸ View")
        newMenu.menu?.performActionForItem(at: viewItem)
        let newTab = try await waitFor("new view tab") { workspace.content.current as? DefinitionTabViewController }
        try check(newTab.newDefinitionID != nil && newTab.editor.editor.string.contains("untitled_view"), "the new view starts from a template")
        let viewName = "m10_view"
        let qualifiedTable = isServer ? dialect.qualified(tableObject.ref) : q(table)
        type("CREATE VIEW \(q(viewName)) AS\nSELECT * FROM \(qualifiedTable);\n", into: newTab.editor.editor)
        _ = try await waitFor("the typed view staged") { changes.definitions.first?.name == viewName ? true : nil }
        try check(newTab.tabItem.title == viewName, "the tab takes the name typed")
        try check(workspace.sidebar.stagedNewDefinitions().map(\.name) == [viewName], "the sidebar lists the new view")
        snap("objects-01-new-view.png", window)
        try await key(#selector(TabulaActions.previewChanges(_:)))
        try await Task.sleep(for: .milliseconds(300))
        snap("objects-02-preview.png", window.attachedSheet)
        try check(try changes.plan(dialect: dialect).preview.contains("CREATE VIEW"), "⇧⌘P shows the CREATE VIEW")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        workspace.previewSheet = nil
        try await commit("the new view")
        let view = try await listed(viewName, .view)
        let viewTab = try await waitFor("the view's tab") { workspace.tableTab.flatMap { $0.table.name == viewName ? $0 : nil } }
        try check(viewTab.mode == .definition, "the new view's tab shows its definition once created")

        // MARK: Editing the view's definition
        let definition = try require(viewTab.definition, "definition side")
        _ = try await waitFor("definition loaded") { definition.loaded.flatMap { $0.isEmpty ? nil : $0 } }
        let loaded = definition.editor.string
        let edited = isServer
            ? loaded.replacingOccurrences(of: ";", with: "\nWHERE 1 = 1;")
            : "CREATE VIEW \(q(viewName)) AS\nSELECT * FROM \(q(table)) WHERE 1 = 1;\n"
        type(edited, into: definition.editor)
        window.makeFirstResponder(workspace.sidebar.view)
        _ = try await waitFor("the edit staged") { changes.mark(for: view) == .edited ? true : nil }
        try check(changes.undoManager.undoActionName == "Edit View", "one undo step “Edit View”")
        snap("objects-03-edit-view.png", window)
        changes.undoManager.undo()
        _ = try await waitFor("undo") { changes.isEmpty && definition.editor.string == loaded ? true : nil }
        print("ok: undo puts the loaded definition back")
        changes.undoManager.redo()
        _ = try await waitFor("redo") { definition.editor.string == edited ? true : nil }
        print("ok: redo brings the edit back")
        try await commit("the view's edit")
        let reread = try await ObjectActions.definitionText(DefinedObject(view)!, on: connection)
        try check(reread.contains("1 = 1"), "the database has the edited view")

        // MARK: Triggers
        workspace.open(tableObject, intent: .regular, mode: .structure)
        let structure = try await waitFor("structure") { workspace.tableTab?.structure }
        let triggersButton = try require(descendant(of: structure.view, NSButton.self) { $0.title == "Triggers" }, "Triggers button")
        triggersButton.performClick(nil)
        let triggers = try await waitFor("triggers popover") { structure.triggers }
        _ = try await waitFor("triggers loaded") { triggers.list.numberOfRows >= 0 && triggers.isViewLoaded ? true : nil }
        let before = triggers.list.numberOfRows
        triggers.addTrigger(nil)
        _ = try await waitFor("new trigger row") { triggers.list.numberOfRows == before + 1 ? true : nil }
        try check(triggers.editor?.editor.string.contains("untitled_trigger") == true, "+ Trigger opens a template")
        snap("objects-04-triggers.png", triggers.view.window)
        try await commit("the new trigger")
        let created = try await connection.triggers(of: tableObject.ref)
        try check(created.contains { $0.name == "untitled_trigger" }, "the trigger exists")
        if structure.triggers == nil { triggersButton.performClick(nil) }
        let again = try await waitFor("triggers popover") { structure.triggers }
        _ = try await waitFor("trigger listed") { again.list.numberOfRows == created.count ? true : nil }
        again.list.selectRowIndexes([0], byExtendingSelection: false)
        again.deleteTrigger(nil)
        try check(changes.definitions.first?.isDropped == true, "Delete marks the trigger")
        try await commit("the trigger's deletion")
        try check(try await connection.triggers(of: tableObject.ref).count == created.count - 1, "the trigger is gone")

        // MARK: Clone
        let cloneName = "\(table)_m10"
        workspace.stageClone(tableObject, as: cloneName, withData: true)
        _ = try await waitFor("clone staged") { changes.clones.first?.name == cloneName ? true : nil }
        try check(workspace.sidebar.stagedClones() == [cloneName], "the sidebar lists the clone")
        snap("objects-05-clone.png", window)
        try await commit("the clone")
        _ = try await listed(cloneName, .table)
        var counts: [String?] = []
        for name in [table, cloneName] {
            counts.append(try await connection.execute(
                "SELECT COUNT(*) FROM \(dialect.qualified(TableRef(schema: tableObject.ref.schema, name)))").rows.first?.first?.displayString)
        }
        try check(counts[0] == counts[1], "the clone has the rows (\(counts))")

        // MARK: Routines (servers)
        if isServer {
            workspace.newDefinition(.function)
            let fnTab = try await waitFor("function tab") { workspace.content.current as? DefinitionTabViewController }
            try check(fnTab.kind == .function, "New ▸ Function opens an editor")
            try await commit("the new function")
            let function = try await listed("untitled_function", .function)
            let opened = try await waitFor("the function's tab") {
                (workspace.content.current as? DefinitionTabViewController).flatMap { $0.object == function ? $0 : nil }
            }
            _ = try await waitFor("function definition") { opened.editor.loaded.flatMap { $0.isEmpty ? nil : $0 } }
            let text = opened.editor.editor.string
            type(dialect is PostgresDialect ? text.replacingOccurrences(of: "SELECT 1;", with: "SELECT 2;")
                 : text.replacingOccurrences(of: "RETURN 1", with: "RETURN 2"), into: opened.editor.editor)
            window.makeFirstResponder(workspace.sidebar.view)
            _ = try await waitFor("function edit staged") { changes.mark(for: function) == .edited ? true : nil }
            snap("objects-06-function.png", window)
            try await commit("the function's edit")
            try check(try await connection.execute("SELECT untitled_function()").rows.first?.first?.displayString == "2",
                      "the function returns the edited value")
            workspace.sidebar.reveal(function)
            window.makeFirstResponder(workspace.sidebar.view)
            workspace.sidebar.deleteRows(nil)
            _ = try await waitFor("function marked") { changes.mark(for: function) == .dropped ? true : nil }
            try await commit("the function's deletion")
            try check(!(try await connection.objects(schema: function.ref.schema).contains(function)), "the function is gone")

            if dialect is PostgresDialect {
                workspace.newDefinition(.materializedView)
                try await commit("a new materialized view")
                let mv = try await listed("untitled_materialized_view", .materializedView)
                try check(workspace.content.current is TableTabViewController, "the materialized view opens like a view")
                _ = try await connection.execute("REFRESH MATERIALIZED VIEW \(dialect.qualified(mv.ref))")
                print("ok: refresh runs")
            }
        }

        // MARK: Search in Database
        workspace.searchInDatabase(nil)
        let search = workspace.leftSidebar.search
        try check(workspace.leftSidebar.pane == .search, "Search in Database shows the Search pane")
        search.choose([tableObject])
        try check(descendant(of: search.view, NSPopUpButton.self) { $0.pullsDown && $0.itemTitle(at: 0) == "1 table" } != nil,
                  "one chosen table reads “1 table”")
        search.choose([])
        search.field.stringValue = term
        search.start(nil)
        _ = try await waitFor("search results") { !search.isSearching && !search.results.isEmpty ? true : nil }
        try check(search.results.contains { $0.object.ref.name == table }, "“\(term)” is found in \(table)")
        try check(!search.results.contains { $0.object.kind != .table }, "All Tables leaves views out")
        try check(workspace.queryLog.entries.contains { $0.sql.hasPrefix("SELECT COUNT(*) FROM") && $0.sql.contains("LIKE") },
                  "the search's statements are in the query log")
        snap("objects-07-search.png", window)
        let hitRow = try require(search.results.firstIndex { $0.object.ref.name == table }, "a hit in \(table)")
        let hit = search.results[hitRow]
        // A click selects the table in the list: its rows open in the preview tab, the focus stays.
        window.makeFirstResponder(search.list)
        search.list.selectRowIndexes([hitRow], byExtendingSelection: false)
        let filtered = try await waitFor("the hit's table") {
            workspace.tableController.flatMap { $0.table.name == table && !$0.filterBar.isHidden ? $0 : nil }
        }
        // The table's regular tab is open already (M8 reuses it); otherwise the preview tab shows it.
        try check(window.firstResponder === search.list, "a click shows the results and leaves the focus in the list")
        try check(filtered.filterBar.checkedConditions == [FilterCondition(.anyColumn, .contains, term)],
                  "the tab is filtered by the search")
        _ = try await waitFor("the matching rows (\(hit.count))") { filtered.total == hit.count ? true : nil }
        print("ok: the tab shows the \(hit.count) rows the list counted")
        _ = try await waitFor("the rows drawn") { filtered.cache.flatMap { visibleLoaded(filtered.grid, $0) ? true : nil } }
        snap("objects-08-hit.png", window)

        // MARK: Diagram
        workspace.showDiagram(nil)
        let diagram = try await waitFor("diagram window") { workspace.diagram }
        let loadedDiagram = try await waitFor("diagram loaded") { diagram.diagram }
        let tables = workspace.environment.catalog.objects.filter { $0.kind == .table }.count
        try check(loadedDiagram.tables.count == min(tables, SchemaDiagram.limit), "the diagram shows every table (\(tables))")
        snap("objects-09-diagram.png", diagram.window)
        diagram.close()
    }
}
