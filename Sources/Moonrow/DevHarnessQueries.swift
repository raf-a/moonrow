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

        // The Queries pane: search looks in the SQL, Return opens, renaming happens in the row,
        // the Trash and folders, each undoable while the pane has the focus.
        let window = try require(workspace.window, "workspace window")
        let queriesPane = workspace.leftSidebar.queries
        workspace.leftSidebar.show(.queries)
        queriesPane.view.layoutSubtreeIfNeeded()
        // Each step is one undo group, as one event is in the app.
        let undo = queriesPane.paneUndoManager
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        func step(_ body: () throws -> Void) rethrows {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            try body()
        }
        func runMenu(_ title: String) throws {
            let menu = NSMenu()
            queriesPane.menuNeedsUpdate(menu)
            let item = try require(menu.items.first { $0.title == title }, "menu item \(title)")
            NSApp.sendAction(try require(item.action, "action"), to: item.target, from: item)
        }
        queriesPane.search.stringValue = "select 3"
        queriesPane.reloadList()
        try check(queriesPane.shownRows == ["other"], "search finds a query by its SQL \(queriesPane.shownRows)")
        queriesPane.search.stringValue = ""
        queriesPane.reloadList()

        // A click opens a query in the pane's preview tab and the next click replaces it. A query
        // already open is selected; typing or opening it again keeps the preview.
        let extra = try moved.save("select 4;", as: "extra", in: "")
        queriesPane.reloadList()
        let previewPane = workspace.content
        let before = previewPane.tabs.count
        try check(queriesPane.clickRow("other"), "a click on other")
        let preview = try require(workspace.queryController, "preview tab")
        try check(preview.savedQuery?.name == "other" && preview.isPreview && previewPane.tabs.count == before + 1,
                  "a click opens the query in a preview tab")
        try check(preview.tabItem.italic, "the preview tab's title is in italics")
        try check(queriesPane.clickRow("extra"), "a click on extra")
        let replaced = try require(workspace.queryController, "replaced preview")
        try check(replaced !== preview && replaced.savedQuery?.name == "extra" && replaced.isPreview && previewPane.tabs.count == before + 1,
                  "the next click replaces the preview")
        try check(queriesPane.clickRow("Reports/report") && workspace.queryController === editor && previewPane.tabs.count == before + 1,
                  "a click on an open query selects its tab")
        try check(queriesPane.clickRow("extra") && workspace.queryController === replaced, "a click goes back to the preview")
        previewPane.select(try require(previewPane.index(of: editor), "report's tab"))
        try check(queriesPane.selectedQueryPath == "Reports/report" && previewPane.tabs.count == before + 1,
                  "selecting a query's tab selects the query in the list \(queriesPane.selectedQueryPath ?? "nothing")")
        previewPane.select(try require(previewPane.index(of: replaced), "extra's tab"))
        try check(queriesPane.selectedQueryPath == "extra" && replaced.isPreview, "and the preview's query, which stays a preview")
        replaced.editor.insertText("-- kept\n", replacementRange: NSRange(location: 0, length: 0))
        try check(!replaced.isPreview, "typing keeps the preview tab")
        try check(queriesPane.clickRow("other") && workspace.queryController?.isPreview == true && previewPane.tabs.count == before + 2,
                  "the next click opens another preview")
        workspace.openSavedQuery(try require(moved.query(named: "other"), "other"))
        let kept = try require(workspace.queryController, "kept tab")
        try check(!kept.isPreview && kept.savedQuery?.name == "other" && previewPane.tabs.count == before + 2, "opening it again keeps it")
        for tab in [replaced, kept] { previewPane.close(try require(previewPane.index(of: tab), "tab to close")) }
        try check(previewPane.tabs.count == before, "the two tabs close")
        try FileManager.default.removeItem(at: extra.url)
        moved.reload()
        queriesPane.reloadList()

        try check(queriesPane.selectRow("other"), "the query is selectable")
        window.makeFirstResponder(queriesPane.outline)
        try check(window.undoManager === undo, "the pane has its own undo while it has the focus")
        queriesPane.outline.onReturn?()
        try check(workspace.queryController?.savedQuery?.name == "other", "Return opens the selected query")
        let opened = try require(workspace.queryController, "opened query")
        workspace.leftSidebar.show(.queries)
        _ = queriesPane.selectRow("other")
        window.makeFirstResponder(queriesPane.outline)
        try runMenu("Rename")
        let field = try require(queriesPane.renamingField, "the row's name being edited")
        field.stringValue = "other renamed"
        step { window.makeFirstResponder(queriesPane.outline) }
        try check(moved.query(named: "other renamed") != nil && opened.tabItem.title == "other renamed",
                  "renaming in the row renames the query and its tab")
        undo.undo()
        try check(moved.query(named: "other") != nil && opened.savedQuery?.name == "other", "undo renames it back")
        _ = queriesPane.selectRow("other")
        step { queriesPane.deleteRows(nil) }
        try check(moved.query(named: "other") == nil && opened.savedQuery == nil && opened.tabItem.title == "other",
                  "Delete moves the query to the Trash at once; its tab keeps the name")
        try check(undo.undoActionName == "Move to Trash", "the step is named \(undo.undoActionName)")
        undo.undo()
        try check(moved.query(named: "other") != nil, "undo puts it back")
        workspace.closeTab(nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        try step { try runMenu("New Folder") }
        let folderField = try require(queriesPane.renamingField, "the new folder's name being edited")
        try check(folderField.stringValue == "New Folder", "a new folder is named New Folder")
        folderField.stringValue = "Archive"
        step { window.makeFirstResponder(queriesPane.outline) }
        try check(moved.folders.contains("Archive"), "its name is edited in the row \(moved.folders)")
        try step { queriesPane.move(try require(moved.query(named: "other"), "other"), to: "Archive") }
        try check(moved.query(path: "Archive/other") != nil, "a query files into it")
        _ = queriesPane.selectRow("[Archive]")
        step { queriesPane.deleteRows(nil) }
        try check(!moved.folders.contains("Archive") && moved.query(named: "other") == nil, "a folder goes to the Trash with its queries")
        undo.undo()
        undo.undo()
        try check(moved.query(named: "other") != nil && moved.folders.contains("Archive"),
                  "undo brings the folder back, then takes the query out of it")
        if let snapshots {
            window.displayIfNeeded()
            snapshot(window, to: snapshots.appending(path: "queries-2-pane.png"))
        }
        let validator = QueriesFolderValidator(store: moved)
        try check((try? validator.panel(NSSavePanel(), validate: moved.directory.appending(path: "Reports/deep/x.sql"))) == nil
                  && (try? validator.panel(NSSavePanel(), validate: moved.directory.appending(path: "Reports/x.sql"))) != nil,
                  "the save panel refuses a query two folders down")

        try FileManager.default.removeItem(at: try require(editor.savedQuery, "saved query").url)
        _ = try await waitFor("tab detached") { editor.savedQuery == nil ? true : nil }
        try check(editor.editor.string == "select 2;" && editor.tabItem.title == "report",
                  "a query deleted on disk leaves its tab as an unsaved query, under its name")
        if let snapshots, let window = workspace.window {
            window.displayIfNeeded()
            snapshot(window, to: snapshots.appending(path: "queries-3-workspace.png"))
        }

        // Closing a query that isn't saved anywhere offers to save it.
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
        var ask = try await question("close question", with: "Delete")
        if let snapshots { snapshot(ask, to: snapshots.appending(path: "queries-4-close.png")) }
        let asked = ask.contentView.map(texts(in:)) ?? []
        let title = editor.tabItem.title
        try check(asked.contains("Do you want to keep the query “\(title)”?"), "closing asks whether to keep it \(asked)")
        try click("Cancel", in: ask)
        try await sheetGone()
        try check(isOpen(editor), "Cancel keeps the tab")

        workspace.closeTab(nil)
        try click("Save…", in: try await question("close question", with: "Delete"))
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
        try check(scratch.runMenuTitles.contains("Save…") && scratch.runMenuTitles.contains("Save As…")
                  && !blank.runMenuTitles.contains("Save…") && blank.runMenuTitles.contains("Save As…"),
                  "the Run menu offers Save… only for unsaved text \(scratch.runMenuTitles)")
        try check(scratch.tabItem.isEdited && !blank.tabItem.isEdited && window.isDocumentEdited,
                  "a query with unsaved text shows a dot in its tab, and the window's close button too")
        let scratchTab = try require(pane.strip.tabView(at: try require(pane.index(of: scratch), "index")), "tab view")
        try check(scratchTab.accessibilityRole() == .radioButton && scratchTab.accessibilityLabel() == scratch.tabItem.title + ", edited"
                  && pane.strip.accessibilityRole() == .tabGroup, "VoiceOver reads the tabs as a tab group")
        if let snapshots {
            window.displayIfNeeded()
            snapshot(pane.strip, to: snapshots.appending(path: "queries-4-tabs.png"))
        }
        pane.close(try require(pane.index(of: scratch), "scratch tab"))
        ask = try await question("close question", with: "Delete")
        try check(workspace.queryController === scratch, "closing a tab in the background selects it before asking")
        try click("Delete", in: ask)
        _ = try await waitFor("tab closed") { isOpen(scratch) ? nil : true }
        try check(moved.queries.count == count, "Delete closes the tab, saving nothing")

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
        try check(!edited.tabItem.isEdited, "a file tab matching its file shows no dot")
        edited.setText("select 7;")
        try check(edited.tabItem.isEdited, "a file tab with changes shows a dot")
        try check(edited.runMenuTitles.contains("Save"), "and its Run menu offers Save")
        workspace.closeTab(nil)
        ask = try await question("close question", with: "Don’t Save")
        let fileAsked = ask.contentView.map(texts(in:)) ?? []
        try check(fileAsked.contains("Do you want to save the changes made to “\(file.lastPathComponent)”?"),
                  "a file tab asks to save its changes \(fileAsked)")
        try click("Save", in: ask)
        _ = try await waitFor("tab closed") { isOpen(edited) ? nil : true }
        try check(try String(contentsOf: file, encoding: .utf8) == "select 7;", "Save writes a file tab's changes to its file, then the tab closes")
        let report2 = workspace.newQuery(text: "select 8;")
        try check(report2.save(to: moved.directory.appending(path: "Reports/report 2.sql")) && report2.savedQuery?.path == "Reports/report 2"
                  && report2.fileURL == nil, "a file in a folder of the queries folder makes a saved query")
        try check(!report2.runMenuTitles.contains("Save") && report2.runMenuTitles.contains("Save As…"),
                  "a saved query's Run menu has Save As… but no Save \(report2.runMenuTitles)")

        // Quitting asks about unsaved queries when workspaces don't reopen; Cancel keeps it all.
        let first = workspace.newQuery(text: "select 9;")
        let second = workspace.newQuery(text: "select 10;")
        try app.settings.update { $0.reopenWorkspaces = false }
        try check(app.applicationShouldTerminate(NSApp) == .terminateCancel, "quitting waits for the question")
        ask = try await question("quit question", with: "Discard Changes")
        let quitAsked = ask.contentView.map(texts(in:)) ?? []
        try check(quitAsked.contains { $0.hasPrefix("Do you want to review the 2 queries with unsaved changes before quitting?") },
                  "quitting asks about the 2 unsaved queries \(quitAsked)")
        try click("Cancel", in: ask)
        try await sheetGone()
        try app.settings.update { $0.reopenWorkspaces = true }
        try check(app.applicationShouldTerminate(NSApp) == .terminateNow, "with workspaces reopening, quitting keeps them for the session")

        // Closing the window with several asks once, then about each one in turn on Review Changes….
        workspace.content.select(try require(workspace.content.index(of: report2), "saved query tab"))
        window.performClose(nil)
        ask = try await question("window question", with: "Review Changes…")
        if let snapshots { snapshot(ask, to: snapshots.appending(path: "queries-5-review.png")) }
        try click("Cancel", in: ask)
        try await sheetGone()
        try check(window.isVisible && isOpen(first) && isOpen(second), "Cancel keeps the window and its tabs")
        window.performClose(nil)
        try click("Review Changes…", in: try await question("window question", with: "Review Changes…"))
        ask = try await question("first question", with: "Delete")
        try check(workspace.queryController === first, "Review Changes… selects the first unsaved query and asks")
        try click("Delete", in: ask)
        _ = try await waitFor("second question") {
            workspace.queryController === second && window.attachedSheet.map { s in buttons(in: s.contentView).contains { $0.title == "Delete" } } == true ? true : nil
        }
        try check(true, "then it asks about the next one")
        try click("Delete", in: try require(window.attachedSheet, "question"))
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
