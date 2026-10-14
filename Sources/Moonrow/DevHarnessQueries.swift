import AppCore
import AppKit

// Saved queries in a connection's queries folder: a change on disk reaches the open tab, the
// connection form moves the folder's queries (and the tab follows them), a file deleted on
// disk leaves its tab as an unsaved query, and closing that tab offers to save it (Cancel,
// Save… through the save panel, Don't Save), while blank and history tabs close at once. A
// file outside the queries folder makes a file tab; one inside makes a saved query. Closing the
// window asks about each unsaved query in turn. No mouse or key events, so it runs hidden.

extension DevHarness {
    static func queriesFolderDemo(_ app: AppDelegate, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        // The command line's connection, saved, so the form can edit it.
        var config = workspace.config
        config.queriesFolder = SavedQueries.defaultFolder(for: config)
        try app.store.save(config)
        let store = workspace.environment.savedQueries
        try check(SavedQueries.sameDirectory(store.directory, SavedQueries.directory(root: app.dataRoot, for: config)),
                  "the workspace uses the folder named after the connection")
        let report = try store.save("select 1;", as: "report", in: "Reports")
        workspace.openSavedQuery(report)
        let editor = try require(workspace.queryController, "query tab")
        try check(editor.savedQuery?.path == "Reports/report", "the tab edits Reports/report")

        try Data("select 2;".utf8).write(to: report.url, options: .atomic)
        _ = try await waitFor("text from disk") { editor.editor.string == "select 2;" ? true : nil }
        try check(true, "a change on disk reaches the tab")
        try Data("select 3;".utf8).write(to: store.directory.appending(path: "other.sql"))
        _ = try await waitFor("new query") { store.query(named: "other") }
        try check(true, "a file added on disk is listed")

        app.editConnection(config, isNew: false)
        let form = try await waitFor("form") { app.forms.first }
        try check(form.queriesField.stringValue == config.queriesFolder, "the form shows the queries folder")
        form.queriesField.stringValue = "Harness B"
        if let snapshots, let window = form.window {
            window.displayIfNeeded()
            snapshot(window, to: snapshots.appending(path: "queries-0-form.png"))
        }
        form.saveClicked(nil)
        let sheet = try await waitFor("question") { form.window?.attachedSheet }
        if let snapshots { snapshot(sheet, to: snapshots.appending(path: "queries-1-move.png")) }
        let text = sheet.contentView.map(texts(in:)) ?? []
        try check(text.contains { $0.hasPrefix("Move the 2 queries in “\(config.queriesFolder)” to “Harness B”") },
                  "it asks to move the 2 queries \(text)")
        let move = try require(buttons(in: sheet.contentView).first { $0.title == "Move Queries" }, "Move Queries")
        move.performClick(nil)
        _ = try await waitFor("form closed") { app.forms.isEmpty ? true : nil }

        let moved = workspace.environment.savedQueries
        try check(app.store.connection(id: config.id)?.queriesFolder == "Harness B", "the connection keeps the new folder")
        try check(moved.directory.lastPathComponent == "Harness B" && workspace.leftSidebar.queries.store === moved,
                  "the workspace and its Queries pane use the new folder")
        try check(moved.queries.map(\.path) == ["other", "Reports/report"], "the queries moved \(moved.queries.map(\.path))")
        try check(!FileManager.default.fileExists(atPath: store.directory.path), "the emptied folder is gone")
        try check(editor.savedQuery?.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Harness B",
                  "the tab follows its query")

        try FileManager.default.removeItem(at: try require(editor.savedQuery, "saved query").url)
        _ = try await waitFor("tab detached") { editor.savedQuery == nil ? true : nil }
        try check(editor.editor.string == "select 2;", "a query deleted on disk leaves its tab as an unsaved query")
        if let snapshots, let window = workspace.window {
            window.displayIfNeeded()
            snapshot(window, to: snapshots.appending(path: "queries-2-workspace.png"))
        }

        // Closing a query that isn't saved anywhere offers to save it.
        let window = try require(workspace.window, "workspace window")
        func isOpen(_ tab: QueryEditorViewController) -> Bool { workspace.panes.pane(of: tab) != nil }
        func question(_ what: String, with button: String) async throws -> NSWindow {
            try await waitFor(what) { window.attachedSheet.flatMap { s in buttons(in: s.contentView).contains { $0.title == button } ? s : nil } }
        }
        func click(_ title: String, in sheet: NSWindow) throws {
            try require(buttons(in: sheet.contentView).first { $0.title == title }, title).performClick(nil)
        }
        func sheetGone() async throws { _ = try await waitFor("sheet gone") { window.attachedSheet == nil ? true : nil } }
        try check(workspace.queryController === editor, "the unsaved query is the selected tab")
        workspace.closeTab(nil)
        var ask = try await question("close question", with: "Don't Save")
        if let snapshots { snapshot(ask, to: snapshots.appending(path: "queries-3-close.png")) }
        let asked = ask.contentView.map(texts(in:)) ?? []
        let title = editor.tabItem.title
        try check(asked.contains("Save “\(title)”?"), "closing asks to save it \(asked)")
        try click("Cancel", in: ask)
        try await sheetGone()
        try check(isOpen(editor), "Cancel keeps the tab")

        workspace.closeTab(nil)
        try click("Save…", in: try await question("close question", with: "Don't Save"))
        let panel = try await waitFor("save panel") { window.attachedSheet as? NSSavePanel }
        let start = try require(panel.directoryURL, "panel folder")
        try check(moved.location(of: start.appending(path: "x.sql")) != nil && panel.nameFieldStringValue == "\(title).sql",
                  "Save… opens the save panel in the queries folder, named after the tab (\(start.path), \(panel.nameFieldStringValue))")
        // The panel runs out of process: names set on it now don't reach it, so take its own.
        let saved = try require(panel.url, "panel file")
        window.endSheet(panel, returnCode: .OK)
        _ = try await waitFor("tab closed") { isOpen(editor) ? nil : true }
        let place = try require(moved.location(of: saved), "a place in the queries folder")
        try check(try moved.query(named: place.name, in: place.folder).map(moved.text(of:)) == "select 2;",
                  "Save… saves it as a query, then the tab closes")

        let count = moved.queries.count
        let scratch = workspace.newQuery(text: "select 4;")
        let blank = workspace.newQuery()
        let pane = try require(workspace.panes.pane(of: scratch), "pane")
        pane.close(try require(pane.index(of: scratch), "scratch tab"))
        ask = try await question("close question", with: "Don't Save")
        try check(workspace.queryController === scratch, "closing a tab in the background selects it before asking")
        try click("Don't Save", in: ask)
        _ = try await waitFor("tab closed") { isOpen(scratch) ? nil : true }
        try check(moved.queries.count == count, "Don't Save closes the tab, saving nothing")

        try check(workspace.queryController === blank, "the blank query is selected")
        workspace.closeTab(nil)
        try check(!isOpen(blank) && window.attachedSheet == nil, "a blank query closes without asking")
        let fromHistory = workspace.newQuery(text: "select 5;", kept: true)
        workspace.closeTab(nil)
        try check(!isOpen(fromHistory) && window.attachedSheet == nil, "a query opened from history closes without asking")

        // Saved outside the queries folder, the tab shows a file; Save writes it back.
        let file = FileManager.default.temporaryDirectory.appending(path: "moonrow-harness-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        let other = workspace.newQuery(text: "select 6;")
        try check(other.save(to: file) && other.fileURL == file && other.savedQuery == nil && other.tabItem.title == file.lastPathComponent,
                  "a file outside the queries folder makes a file tab")
        workspace.closeTab(nil)
        try check(!isOpen(other) && window.attachedSheet == nil, "a file tab matching its file closes without asking")
        let edited = workspace.newQuery(text: "select 6;", file: file)
        edited.setText("select 7;")
        workspace.closeTab(nil)
        try click("Save", in: try await question("close question", with: "Don't Save"))
        _ = try await waitFor("tab closed") { isOpen(edited) ? nil : true }
        try check(try String(contentsOf: file, encoding: .utf8) == "select 7;", "Save writes a file tab's changes to its file, then the tab closes")
        let report2 = workspace.newQuery(text: "select 8;")
        try check(report2.save(to: moved.directory.appending(path: "Reports/report 2.sql")) && report2.savedQuery?.path == "Reports/report 2"
                  && report2.fileURL == nil, "a file in a folder of the queries folder makes a saved query")

        // Closing the window asks about each unsaved query, selecting it; Cancel keeps it all.
        let first = workspace.newQuery(text: "select 9;")
        let second = workspace.newQuery(text: "select 10;")
        workspace.content.select(try require(workspace.content.index(of: report2), "saved query tab"))
        window.performClose(nil)
        ask = try await question("window question", with: "Don't Save")
        try check(workspace.queryController === first, "closing the window selects the first unsaved query")
        try click("Cancel", in: ask)
        try await sheetGone()
        try check(window.isVisible && isOpen(first) && isOpen(second), "Cancel keeps the window and its tabs")
        window.performClose(nil)
        try click("Don't Save", in: try await question("window question", with: "Don't Save"))
        _ = try await waitFor("second question") { workspace.queryController === second && window.attachedSheet != nil ? true : nil }
        try check(true, "then it asks about the next one")
        try click("Don't Save", in: try require(window.attachedSheet, "question"))
        _ = try await waitFor("window closed") { window.isVisible ? nil : true }
        try check(moved.queries.count == count + 1, "the window closes, saving nothing more")
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }

    private static func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
    }
}
