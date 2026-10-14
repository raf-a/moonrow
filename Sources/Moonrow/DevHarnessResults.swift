import AppCore
import AppKit
import DBKit

extension DevHarness {
    /// Part of `MOONROW_POWER`: query results. A failing statement is underlined and scrolled
    /// to, the status says how a run ended, a result cut by the row limit is fetched whole,
    /// results sort by a header click, keep their numbers in order, feed the right sidebar, and
    /// the result bar's buttons stay put. It writes nothing.
    static func resultsChecks(_ workspace: WorkspaceWindowController, window: NSWindow, table: String, snapshots: URL?) async throws {
        func snap(_ name: String) {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            if let snapshots { snapshot(window, to: snapshots.appending(path: name)) }
        }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let query = workspace.newQuery()
        let results = query.results
        func run(_ sql: String, all: Bool = true) async throws {
            query.setText(sql)
            window.makeFirstResponder(query.editor)
            if all { query.runAllQueries(nil) } else { query.runCurrentQuery(nil) }
            _ = try await waitFor("run to start") { query.isRunning ? true : nil }
            _ = try await waitFor("run to finish") { query.isRunning ? nil : true }
            window.layoutIfNeeded()
        }
        let isPostgres = workspace.connection.dialect is PostgresDialect

        // A failure far down the script: its token (or, without a position, its statement) is
        // underlined and scrolled into view; the summary counts the statements that ran.
        let failing = "select 1 as a, nope_column as b"
        try await run("select 1 as a;\n" + String(repeating: "\n", count: 120) + failing + ";\nselect 2 as c")
        let text = query.editor.string as NSString
        let marked = try require(query.errorHighlight, "an underlined error")
        let expected = isPostgres ? text.range(of: "nope_column") : text.range(of: failing)
        try check(marked == expected, "the failure underlines “\(text.substring(with: marked))”")
        let glyphs = query.editor.layoutManager!.glyphRange(forCharacterRange: marked, actualCharacterRange: nil)
        var rect = query.editor.layoutManager!.boundingRect(forGlyphRange: glyphs, in: query.editor.textContainer!)
        rect.origin.y += query.editor.textContainerOrigin.y
        try check(query.editor.visibleRect.intersects(rect), "and scrolls it into view")
        try check(results.statusText.hasPrefix("2 of 3 statements ran · statement 2 failed · "), "status “\(results.statusText)”")
        print(results.messagesText)
        let stamp = String(repeating: " ", count: 12)
        try check(results.messagesText.split(separator: "\n").filter { !$0.hasPrefix(" ") }.count == 2,
                  "Messages: only the statements' lines start under the time")
        snap("results-01-error.png")
        if isPostgres {
            // DETAIL and HINT lines line up under the error.
            try await run("select length(1, 2, 3)", all: false)
            try check(results.messagesText.contains("\n" + stamp + "HINT: "), "the hint lines up under the error")
        }

        // One failing statement: its error, in red.
        try await run("select nope_column from (select 1 as a) t", all: false)
        try check(results.statusIsError && !results.statusText.contains("statement"), "one failure shows its error: “\(results.statusText)”")
        // No result set: the rows it changed.
        try await run("update \(table) set id = id where 1 = 0", all: false)
        try check(results.statusText.hasPrefix("0 rows affected · "), "an UPDATE says what it changed: “\(results.statusText)”")

        // Cut by the row limit: Fetch All fills the same result.
        let series = """
            with recursive n(x) as (select 1 union all select x + 1 from n where x < 1000)
            select x, case when x % 7 = 0 then null else x % 10 end as m from n
            """
        try await run(series, all: false)
        let cut = try require(results.shownResult, "result")
        try check(results.statusText.hasPrefix("First 300 rows · ") && results.showsFetchAll, "a cut result says so and offers Fetch All")
        workspace.exportData(nil)
        let export = try await waitFor("export sheet") { window.attachedSheet?.windowController as? ExportSheetController }
        try check(texts(in: export.window!.contentView!).contains { $0.contains("only its first 300 rows") }, "its export says it holds the first 300 rows")
        export.close()
        _ = try await waitFor("export sheet gone") { window.attachedSheet == nil ? true : nil }
        snap("results-02-row-limit.png")
        let bar = try require(results.resultBar, "result bar")
        func frame(_ title: String) -> NSRect? {
            bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }?.frame
        }
        let exportFrame = try require(frame("Export…"), "Export button")
        try check(bar.bounds.maxX - exportFrame.maxX < 12, "Export sits at the trailing edge")
        let chartBefore = try require(frame("Chart"), "Chart button")
        results.fetchAll(nil)
        _ = try await waitFor("all rows") { results.shownResult?.outcome?.truncated == false && !query.isRunning ? true : nil }
        let whole = try require(results.shownResult, "result")
        try check(whole === cut && whole.rows.count == 1_000 && !results.showsFetchAll, "Fetch All fills Result \(whole.number) with 1,000 rows")
        window.layoutIfNeeded()
        try check(frame("Chart") == chartBefore, "the buttons stay put while the status changes")
        snap("results-03-fetched.png")

        // Sorting by a header click: NULLs first, stable; again: reversed; a third time: as sent.
        let grid = whole.grid
        let m = grid.tableColumns[1]
        whole.tableView(grid, didClick: m)
        let up = (0..<grid.numberOfRows).map { whole.shownRow($0) }
        try check(up.prefix(142).allSatisfy { $0[1] == .null } && up[142][1] == .integer(0), "ascending puts the 142 NULLs first")
        try check(up.prefix(142).map { $0[0] } == up.prefix(142).map { $0[0] }.sorted { ResultSort.compare($0, $1) == .orderedAscending },
                  "equal values keep the server's order")
        whole.tableView(grid, didClick: m)
        try check(whole.shownRow(0)[1] == .integer(9) && whole.shownRow(999)[1] == .null, "a second click reverses")
        grid.selectRowIndexes([0], byExtendingSelection: false)
        whole.copy(nil)
        try check(NSPasteboard.general.string(forType: .string) == "9\t9", "Copy follows the shown order")
        try check(whole.exportSubject.rowsShown.first == [.integer(9), .integer(9)], "and so does Export")
        snap("results-04-sorted.png")
        whole.tableView(grid, didClick: m)
        try check(whole.shownRow(0)[0] == .integer(1), "a third click shows the server's order")
        let fitted = whole.tableView(grid, sizeToFitWidthOfColumn: 0)
        try check(fitted >= GridCell.width(of: "1000", header: false), "fitting a column measures its values (\(fitted))")

        // The right sidebar shows the selected row, read-only.
        grid.selectRowIndexes([4], byExtendingSelection: false)
        try check(workspace.inspector.source === results, "the right sidebar follows the result")
        let fields = results.inspectorFields
        try check(fields.map(\.label) == ["x", "m"] && fields.first?.value == .value(.integer(5)) && !fields.contains { $0.isEditable },
                  "its fields hold row 5, read-only")

        // Return opens the cell viewer; ⌘↩ still runs the query.
        window.makeFirstResponder(grid)
        grid.keyDown(with: try key("\r", code: 36))
        let viewer = try await waitFor("cell viewer") { whole.shownCellViewer }
        if let sheet = viewer.window { window.endSheet(sheet) }
        _ = try await waitFor("cell viewer gone") { window.attachedSheet == nil ? true : nil }
        print("ok: Return opens the cell viewer")
        window.makeFirstResponder(grid)
        try await pressMenu(#selector(MoonrowActions.runCurrentQuery(_:)), in: window)
        _ = try await waitFor("⌘↩ runs") { results.shownResult !== whole ? true : nil }
        _ = try await waitFor("run to finish") { query.isRunning ? nil : true }
        try check(window.attachedSheet == nil, "⌘↩ in the result runs the query")

        // Numbers only grow while results are pinned; a pinned result's status leaves out the run's summary.
        results.togglePin(nil)
        let pinned = try require(results.shownResult, "pinned result")
        try await run("select 1 as a; select 2 as b")
        let numbers = results.results.map(\.number)
        try check(numbers == numbers.sorted() && Set(numbers).count == numbers.count && numbers.first == pinned.number,
                  "result tabs read in order: \(numbers)")
        try check(results.statusText.contains("2 statements"), "the run's result shows its summary")
        results.select(pinned)
        try check(!results.statusText.contains("statements"), "the pinned one doesn't: “\(results.statusText)”")
        snap("results-05-pinned.png")
        results.togglePin(nil)
        // The query was never saved: closing asks, and Delete closes it.
        workspace.closeTab(nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        _ = try await waitFor("query tab closed") { workspace.panes.pane(of: query) == nil ? true : nil }
    }

    /// Every label's text under `view`.
    private static func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
    }
}

extension ExportSubject {
    /// For the dev harness: a result's rows.
    var rowsShown: [[DBValue]] {
        if case .result(_, _, let rows, _) = self { rows } else { [] }
    }
}
