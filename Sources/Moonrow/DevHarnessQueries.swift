import AppCore
import AppKit

// Saved queries in a connection's queries folder: a change on disk reaches the open tab, the
// connection form moves the folder's queries (and the tab follows them), and a file deleted on
// disk leaves its tab as an unsaved query. No mouse or key events, so it runs hidden.

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
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }

    private static func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
    }
}
