import AppCore
import AppKit
import DBKit

extension DevHarness {
    /// `MOONROW_POWER=<table>`: M9's grid and query features through the real controls, with the
    /// shortcuts sent as key events (so the menu bar's shared-shortcut routing is exercised).
    /// Every edit it stages is discarded; it never commits. Use a table with at least three
    /// rows, an integer `id` key and a text column.
    static func powerDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
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
        func pasteboard() -> String { NSPasteboard.general.string(forType: .string) ?? "" }
        func setPasteboard(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        try await makeKey(window)
        let changes = workspace.changes
        func key(_ action: Selector) async throws { try await pressMenu(action, in: window) }

        // MARK: Grid
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.tableController }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        let grid = data.grid
        let columnCount = grid.numberOfColumns
        try check(columnCount >= 3, "at least three columns")
        window.makeFirstResponder(grid)
        grid.selectRowIndexes([0, 1], byExtendingSelection: false)
        grid.focusedColumn = grid.tableColumns[1].identifier
        grid.keyDown(with: try shifted("\u{F703}", code: 124))  // ⇧→
        try check(grid.selectedColumnSpan == 1...2, "⇧→ stretches the cursor over two columns")
        snap("power-01-cells.png", window)

        try await key(#selector(MoonrowActions.copySelectedCells(_:)))
        let copied = pasteboard().components(separatedBy: "\n")
        try check(copied.count == 2 && copied.allSatisfy { $0.components(separatedBy: "\t").count == 2 }, "⇧⌘C copies 2 × 2 cells: \(copied)")

        // Paste into the selected cells: one value fills all four, as one undo step.
        setPasteboard("pasted")
        try await key(#selector(MoonrowActions.pasteIntoSelectedCells(_:)))
        try check(changes.edits(for: data.table)?.updatedRowCount == 2, "⇧⌘V stages two rows")
        try check(changes.undoManager.undoActionName == "Paste", "undo step “Paste”")
        snap("power-02-pasted.png", window)
        changes.undoManager.undo()
        try check(changes.edits(for: data.table)?.isEmpty ?? true, "undo takes the paste back")

        // ⌘V adds the pasted lines as new rows.
        let rowsBefore = grid.numberOfRows
        setPasteboard(copied.joined(separator: "\n"))
        window.makeFirstResponder(grid)
        try await key(#selector(NSText.paste(_:)))
        try check(grid.numberOfRows == rowsBefore + 2, "⌘V adds two rows")
        changes.undoManager.undo()
        try check(grid.numberOfRows == rowsBefore, "undo removes them")

        // Copy as HTML, column values.
        grid.selectRowIndexes([0], byExtendingSelection: false)
        let html = try require(CopyFormat.allCases.firstIndex(of: .html), "HTML format")
        let htmlItem = NSMenuItem()
        htmlItem.tag = html
        data.copyRowsAs(htmlItem)
        _ = try await waitFor("HTML on the pasteboard") { pasteboard().hasPrefix("<table>") ? true : nil }
        print("ok: Copy Rows As ▸ HTML")
        data.copyColumnValues(nil)
        _ = try await waitFor("column values") { pasteboard().components(separatedBy: "\n").count == data.total || pasteboard().components(separatedBy: "\n").count == grid.numberOfRows ? true : nil }
        print("ok: Copy Column Values (\(pasteboard().components(separatedBy: "\n").count) lines)")

        // Quick Filter on the first row's key: = value.
        grid.selectRowIndexes([0], byExtendingSelection: false)
        grid.focusedColumn = grid.tableColumns[0].identifier
        let menu = try require(grid.menu, "grid menu")
        menu.delegate?.menuNeedsUpdate?(menu)
        let quick = try require(menu.items.first { $0.title == "Quick Filter" }?.submenu, "Quick Filter menu")
        print("quick filter items: \(quick.items.map(\.title))")
        let equal = try require(quick.items.first, "= item")
        let before = data.cache.map(ObjectIdentifier.init)
        _ = equal.target?.perform(equal.action, with: equal)
        _ = try await waitFor("filtered page") { data.cache.map(ObjectIdentifier.init) != before ? true : nil }
        _ = try await waitFor("filtered rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }
        try check(data.query.filter != nil && data.total == 1, "Quick Filter “\(equal.title)” leaves one row")
        snap("power-03-quick-filter.png", window)
        let unfiltered = data.cache.map(ObjectIdentifier.init)
        data.filterBar.apply(FilterCondition(.anyColumn, .contains, ""))
        data.toggleFilters(nil)
        _ = try await waitFor("unfiltered page") { data.cache.map(ObjectIdentifier.init) != unfiltered ? true : nil }
        _ = try await waitFor("rows") { data.cache.flatMap { visibleLoaded(data.grid, $0) ? true : nil } }

        // Columns: hide one, move another, and both survive reopening the table.
        data.showColumns(nil)
        let popover = try await waitFor("columns popover") {
            (NSApp.windows.filter(\.isVisible).compactMap { $0.contentViewController as? ColumnsPopoverController }.first)
        }
        let hidden = grid.tableColumns[1].title
        let last = grid.tableColumns.last!.title
        try check(popover.setHidden(true, hidden), "hide \(hidden)")
        popover.move(last, to: 0)
        try check(grid.numberOfColumns == columnCount - 1 && grid.tableColumns[0].title == last, "\(hidden) hidden, \(last) first")
        snap("power-04-columns.png", window)
        popover.view.window?.close()
        workspace.closeTab(nil)
        _ = try await waitFor("sidebar item \(table) again") { workspace.sidebar.select(named: table) ? true : nil }
        let reopened = try await waitFor("table view again") { workspace.tableController }
        _ = try await waitFor("rows") { reopened.cache.flatMap { visibleLoaded(reopened.grid, $0) ? true : nil } }
        try check(reopened.grid.tableColumns.map(\.title).first == last && !reopened.grid.tableColumns.contains { $0.title == hidden },
                  "the layout is remembered")
        // Back to the table's own layout.
        reopened.showColumns(nil)
        let popover2 = try await waitFor("columns popover") {
            (NSApp.windows.filter(\.isVisible).compactMap { $0.contentViewController as? ColumnsPopoverController }.first)
        }
        _ = popover2.setHidden(false, hidden)
        popover2.move(last, to: columnCount - 1)
        popover2.view.window?.close()
        try check(reopened.grid.numberOfColumns == columnCount, "Show All restores the columns")

        // ⌘↩ on a cell opens the cell editor (Run Current's shortcut, answered by the grid).
        window.makeFirstResponder(reopened.grid)
        reopened.grid.selectRowIndexes([0], byExtendingSelection: false)
        let textColumn = try require(reopened.browser?.columns.firstIndex { $0.typeName.uppercased().contains("TEXT") || $0.typeName.uppercased().contains("CHAR") },
                                     "a text column")
        reopened.grid.focusedColumn = NSUserInterfaceItemIdentifier(String(textColumn))
        try await key(#selector(MoonrowActions.runCurrentQuery(_:)))
        let editor = try await waitFor("cell editor") { reopened.shownCellEditor }
        print("cell editor modes: \(editor.modeTitles), text: \(editor.shownText.prefix(40))")
        editor.type(#"{"b": [1, 2], "a": "x"}"#)
        snap("power-05-cell-editor.png", editor.window)
        editor.save()
        try check(changes.edits(for: reopened.table)?.updatedRowCount == 1, "Save in the cell editor stages the value")
        try check(changes.undoManager.undoActionName == "Edit Cell", "one undo step")
        // Opened again, the JSON shows laid out.
        try await key(#selector(MoonrowActions.runCurrentQuery(_:)))
        let again = try await waitFor("cell editor again") { reopened.shownCellEditor }
        again.select(mode: "JSON")
        try check(again.shownText.contains("\n  \"b\": ["), "JSON mode lays the value out")
        snap("power-06-cell-json.png", again.window)
        if let sheet = again.window { window.endSheet(sheet) }
        _ = try await waitFor("cell editor gone") { window.attachedSheet == nil ? true : nil }
        changes.undoManager.undo()

        // Export Current Page goes through the export sheet.
        reopened.exportCurrentPage(nil)
        let export = try await waitFor("export sheet") { window.attachedSheet?.windowController as? ExportSheetController }
        snap("power-07-export-page.png", export.window)
        export.close()
        _ = try await waitFor("export sheet gone") { window.attachedSheet == nil ? true : nil }

        // MARK: Query editor
        // A query tab must leave the main menu's shortcuts alone (AppKit keeps one item per shortcut).
        let query = workspace.newQuery(text: "select   id ,  count(*) from \(table) where id = :id group by id")
        for action in [#selector(MoonrowActions.addRow(_:)), #selector(MoonrowActions.runCurrentQuery(_:)), #selector(MoonrowActions.runAllQueries(_:)),
                       #selector(MoonrowActions.deleteRows(_:)), #selector(MoonrowActions.truncateTable(_:)), #selector(MoonrowActions.saveSQLAs(_:))] {
            try check(menuItem(NSApp.mainMenu, action: action)?.keyEquivalent.isEmpty == false, "\(action) keeps its shortcut")
        }
        window.makeFirstResponder(query.editor)
        _ = try await waitFor("editor focused") { window.firstResponder === query.editor ? true : nil }
        try await key(#selector(MoonrowActions.addRow(_:)))
        try check(query.editor.string.contains("\nFROM\n") && query.editor.string.hasPrefix("SELECT"), "⌘I beautifies (Add Row's shortcut, answered by the editor)")
        let addRowItem = try require(menuItem(NSApp.mainMenu, action: #selector(MoonrowActions.addRow(_:))), "Add Row item")
        addRowItem.menu?.update()
        try check(addRowItem.title == "Beautify SQL", "Edit ▸ Add Row reads Beautify SQL in a query tab")
        print(query.editor.string)
        try await key(#selector(MoonrowActions.compactSQL(_:)))
        try check(!query.editor.string.contains("\n"), "⇧⌘I compacts")
        query.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await key(#selector(MoonrowActions.toggleBlockComment(_:)))
        try check(query.editor.string.hasPrefix("/* SELECT") && query.editor.string.hasSuffix(" */"), "⌥⌘/ comments the line out")
        try await key(#selector(MoonrowActions.toggleBlockComment(_:)))
        try check(query.editor.string.hasPrefix("SELECT"), "and back in")
        try await key(#selector(MoonrowActions.addRow(_:)))
        snap("power-08-beautified.png", window)

        // Parameters: :id asks for a value.
        window.makeFirstResponder(query.editor)
        try await key(#selector(MoonrowActions.runCurrentQuery(_:)))
        let params = try await waitFor("parameters sheet") { query.parameterSheet }
        params.fill(":id", "1")
        snap("power-09-parameters.png", params.window)
        params.confirm()
        _ = try await waitFor("result") { query.results.shownResult?.outcome }
        _ = try await waitFor("parameters sheet gone") { window.attachedSheet == nil ? true : nil }
        _ = try await waitFor("run over") { query.isRunning ? nil : true }
        try check(query.results.shownResult?.rows.count == 1, "the query ran with id = 1")
        try check(workspace.environment.history.entries.first?.sql.contains("id = 1") == true, "history has the value written in")

        // Pin it; the next run keeps it and adds its own.
        query.results.togglePin(nil)
        query.setText("select id from \(table) order by id")
        window.makeFirstResponder(query.editor)
        try await key(#selector(MoonrowActions.runCurrentQuery(_:)))
        _ = try await waitFor("second run") { query.results.results.count == 2 && query.results.results.last?.outcome != nil ? true : nil }
        try check(query.results.results.first?.isPinned == true, "the pinned result stays")
        query.results.toggleChart(nil)
        let chart = try require(query.results.shownResult?.chart, "chart")
        try check(!chart.chart.points.isEmpty, "the chart has \(chart.chart.points.count) points")
        snap("power-10-chart.png", window)
        chart.select(kind: .line)
        snap("power-11-line.png", window)
        query.results.toggleChart(nil)

        // Run button default.
        let runAllItem = try require(query.view.descendantMenus().flatMap(\.items).first { $0.title == "Run All" && $0.action == NSSelectorFromString("setRunDefault:") },
                                     "Default ▸ Run All")
        _ = runAllItem.target?.perform(runAllItem.action, with: runAllItem)
        _ = try await waitFor("Run All button") { query.runButtonTitle == "Run All" ? true : nil }
        print("ok: the Run button runs all")
        let runCurrentItem = try require(runAllItem.menu?.items.first { $0.title == "Run Current" }, "Default ▸ Run Current")
        _ = runCurrentItem.target?.perform(runCurrentItem.action, with: runCurrentItem)

        // The query log (⌃⌘C) has every statement, the grid's too.
        try await key(#selector(MoonrowActions.toggleQueryLog(_:)))
        try check(workspace.center.isLogVisible, "⌃⌘C shows the query log")
        _ = try await waitFor("logged statements") { workspace.center.log.shownText.contains("order by id") ? true : nil }
        try check(workspace.queryLog.entries.contains { $0.sql.uppercased().hasPrefix("SELECT") && $0.sql.contains("LIMIT") }, "grid paging is logged")
        try await Task.sleep(for: .milliseconds(600))
        print("log frame: \(workspace.center.log.view.frame), center: \(workspace.center.view.frame)")
        snap("power-12-query-log.png", window)
        try await key(#selector(MoonrowActions.toggleQueryLog(_:)))
        try check(!workspace.center.isLogVisible, "and hides it")

        // Dragging its divider to the bottom closes it, like a sidebar; it reopens at its old height.
        try await key(#selector(MoonrowActions.toggleQueryLog(_:)))
        window.layoutIfNeeded()
        let center: WorkspaceCenterController = workspace.center
        let logHeight = center.log.view.frame.height
        let split = center.split
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try require(NSEvent.mouseEvent(
                with: type, location: split.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "mouse event")
        }
        let divider = NSPoint(x: split.bounds.midX, y: center.panes.view.frame.maxY + split.dividerThickness / 2)
        // The split view's tracking loop takes the drags and the mouse-up from the queue.
        for y in stride(from: divider.y + 20, through: split.bounds.maxY - 1, by: 20) + [split.bounds.maxY - 1] {
            NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: divider.x, y: y)), atStart: false)
        }
        NSApp.postEvent(try mouse(.leftMouseUp, NSPoint(x: divider.x, y: split.bounds.maxY - 1)), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, divider))
        try await Task.sleep(for: .milliseconds(100))
        try check(!center.isLogVisible && !UserDefaults.standard.bool(forKey: WorkspaceCenterController.logVisibleKey),
                  "dragging the divider to the bottom closes the query log")
        try await key(#selector(MoonrowActions.toggleQueryLog(_:)))
        window.layoutIfNeeded()
        try check(center.isLogVisible && abs(center.log.view.frame.height - logHeight) < 2,
                  "⌃⌘C reopens it at its height from before the drag (\(center.log.view.frame.height) vs \(logHeight))")
        try await key(#selector(MoonrowActions.toggleQueryLog(_:)))

        // MARK: Sidebar
        let store = workspace.environment.savedQueries
        try store.addFolder("Reports")
        let saved = try store.save("select 1", as: "Daily")
        workspace.leftSidebar.show(.queries)
        let queries = workspace.leftSidebar.queries
        queries.move(saved, to: "Reports")
        try check(queries.shownRows == ["[Reports]", "  Daily"], "the query is filed in Reports: \(queries.shownRows)")
        snap("power-13-folders.png", window)
        workspace.leftSidebar.show(.history)
        let history = workspace.leftSidebar.history
        try check(history.shownRows.first == "[Today]", "history is grouped by day: \(history.shownRows.prefix(3))")
        history.search.stringValue = "order by"
        history.search.sendAction(history.search.action, to: history.search.target)
        try check(history.shownRows.count == 2 && history.shownRows[1].contains("order by"), "the search filters history")
        snap("power-14-history.png", window)
        history.search.stringValue = ""
        history.search.sendAction(history.search.action, to: history.search.target)

        // MARK: Running Queries (servers only)
        if ServerSessions.isSupported(workspace.connection) {
            workspace.showRunningQueries(nil)
            let sheet = try await waitFor("Running Queries") { workspace.runningQueries?.window?.isSheet == true ? workspace.runningQueries : nil }
            _ = try await waitFor("sessions") { sheet.isLoaded ? true : nil }
            print("sessions: \(sheet.sessions.map { "\($0.id) \($0.state)" })")
            snap("power-15-running-queries.png", sheet.window)
            sheet.refresh(nil)
            if let w = sheet.window { window.endSheet(w) }
        }

        try await resultsChecks(workspace, window: window, table: table, snapshots: snapshots)

        changes.discardAll()
        print("power demo done")
    }

    private static func shifted(_ characters: String, code: UInt16) throws -> NSEvent {
        try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "key event")
    }
}

extension NSView {
    /// Menus of pop-up buttons under this view (the Run button's menu).
    func descendantMenus() -> [NSMenu] {
        var out: [NSMenu] = []
        if let popup = self as? NSPopUpButton, let menu = popup.menu {
            out.append(menu)
            out += menu.items.compactMap(\.submenu)
        }
        for v in subviews { out += v.descendantMenus() }
        return out
    }
}
