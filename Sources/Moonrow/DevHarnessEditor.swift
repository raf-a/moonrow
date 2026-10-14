import AppCore
import AppKit
import SQLScript

extension DevHarness {
    /// The query editor's finer points, after the query demo: Return after a complete word,
    /// keyword case, completion undo steps, the list closing when the text scrolls, Beautify
    /// keeping the caret, the Run button's titles and slot, the row limit new tabs start with,
    /// Edit ▸ Complete and Go to Line, Show Filters in a query tab, and indentation after `(`.
    /// `table` is a table with another table whose name starts with it (`users`, `users_archive`)
    /// when there is one. It only reads the database.
    static func editorChecks(_ workspace: WorkspaceWindowController, table: String, snap: (String, NSWindow?) -> Void) async throws {
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        let window = try require(workspace.window, "workspace window")
        workspace.newQueryTab(nil)
        let query = try require(workspace.queryController, "query tab")
        let editor = query.editor
        window.makeFirstResponder(editor)
        // Each key press is an undo group of its own, as with events from the keyboard (the
        // harness's steps would otherwise share the run loop pass's group).
        let undo = try require(editor.undoManager, "undo manager")
        undo.groupsByEvent = false
        func event(_ body: () throws -> Void) rethrows {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            try body()
        }
        func type(_ text: String) {
            for ch in text {
                event {
                    if ch == "\n" { editor.insertNewline(nil) } else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
                }
            }
        }
        func press(_ characters: String, code: UInt16) throws {
            try event { editor.keyDown(with: try key(characters, code: code)) }
        }
        func reset(_ text: String = "") {
            query.textViewDismissCompletion()
            event { query.setText(text) }
        }

        // Return after a keyword typed in full ends the line; the list opened by itself.
        type("select 1 where 1 = 1 and")
        _ = try await waitFor("completion list after `and`") { query.isCompletionVisible ? true : nil }
        print("list after `and`: \(query.completionItems.prefix(4).map(\.text))")
        try press("\r", code: 36)
        try check(editor.string.hasSuffix("and\n") && !query.isCompletionVisible, "Return after `and` starts a new line")
        // Return after a partial word accepts, in the case typed.
        type("ord")
        _ = try await waitFor("completion list after `ord`") { query.isCompletionVisible ? true : nil }
        try press("\r", code: 36)
        try check(editor.string.hasSuffix("\norder"), "Return after `ord` inserts `order` (got \(editor.string.suffix(8).debugDescription))")
        // Its own undo step, though typing before it coalesces.
        undo.undo()
        try check(editor.string.hasSuffix("\nord"), "undo goes back to `ord` (got \(editor.string.suffix(8).debugDescription))")
        undo.groupsByEvent = true
        reset()
        type("SEL")
        _ = try await waitFor("completion list after `SEL`") { query.isCompletionVisible ? true : nil }
        try press("\t", code: 48)
        try check(editor.string == "SELECT", "Tab after `SEL` inserts `SELECT`")

        // A table name typed in full, with a longer one listed: Return ends the line.
        let catalog = workspace.environment.catalog.completionCatalog
        if let longer = catalog.tables.first(where: { $0 != table && $0.lowercased().hasPrefix(table.lowercased()) }) {
            reset()
            type("select * from \(table)")
            _ = try await waitFor("completion list after `\(table)`") { query.isCompletionVisible ? true : nil }
            print("list after `\(table)`: \(query.completionItems.prefix(4).map(\.text)) (\(longer) listed)")
            try press("\r", code: 36)
            try check(editor.string == "select * from \(table)\n", "Return after `\(table)` starts a new line")
            // Moving the selection makes Return accept.
            reset()
            type("select * from \(table)")
            _ = try await waitFor("completion list") { query.isCompletionVisible ? true : nil }
            try press("\u{F701}", code: 125)
            try press("\u{F700}", code: 126)
            try press("\r", code: 36)
            try check(editor.string == "select * from \(table)", "after ↓↑, Return accepts `\(table)`")
        } else {
            print("skipped: no table starting with `\(table)`")
        }

        // The list closes when the editor scrolls under it, and uses the editor's font.
        reset(Array(repeating: "select 1;", count: 80).joined(separator: "\n") + "\n")
        window.layoutIfNeeded()
        editor.scrollRangeToVisible(editor.selectedRange())
        type("sel")
        _ = try await waitFor("completion list") { query.isCompletionVisible ? true : nil }
        let popup = NSApp.windows.first { $0 is NSPanel && $0.isVisible }
        snap("e1-completion-font.png", popup)
        let clip = try require(editor.enclosingScrollView?.contentView, "clip view")
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 120)))
        try check(!query.isCompletionVisible, "scrolling closes the list")

        // Edit ▸ Complete asks for the list.
        let complete = try require(menuItem(NSApp.mainMenu, action: #selector(NSTextView.complete(_:))), "Edit ▸ Complete")
        print("Edit ▸ \(complete.title): \(KeyBinding(complete.keyEquivalent, .init(complete.keyEquivalentModifierMask)).display)")
        reset("select * from ")
        editor.setSelectedRange(NSRange(location: 14, length: 0))
        editor.complete(nil)
        _ = try await waitFor("completion list from Complete") { query.isCompletionVisible ? true : nil }
        try check(query.completionItems.contains { $0.text == table }, "Complete lists the tables")
        query.textViewDismissCompletion()

        // Beautify keeps the caret on its token and the line where it was on screen.
        let script = (1...40).map { "select id, \($0) as n from \(table) where id > \($0)" }.joined(separator: ";\n") + ";\n"
        reset(script)
        let target = (script as NSString).range(of: "as n from \(table) where id > 30").location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        window.displayIfNeeded()
        let before = (editor.lineTop(at: target) ?? 0) - editor.visibleRect.minY
        query.formatSQL(nil)
        let caret = editor.selectedRange().location
        let after = (editor.lineTop(at: caret) ?? 0) - editor.visibleRect.minY
        let at = (editor.string as NSString).substring(with: NSRange(location: caret, length: 4))
        let line = (editor.string as NSString).substring(to: caret).components(separatedBy: "\n").count
        try check(at == "AS n" && editor.string.components(separatedBy: "\n")[line - 1].contains("30"),
                  "Beautify keeps the caret at `as n` of statement 30 (at \(at.debugDescription), line \(line))")
        try check(abs(before - after) < 1, "and its line where it was (\(before) → \(after))")
        snap("e2-beautified.png", window)
        query.compactSQL(nil)
        let compactAround = (editor.string as NSString).substring(with: NSRange(location: editor.selectedRange().location, length: 4))
        try check(compactAround == "AS n", "Compact too (at \(compactAround.debugDescription))")

        // Run button: selection, slot, menu.
        reset("select 1;\nselect 2;")
        try check(query.runButtonTitle == "Run Current", "Run Current without a selection")
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        try check(query.runButtonTitle == "Run Selection", "Run Selection with one")
        window.displayIfNeeded()
        snap("e3-run-selection.png", window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let menu = try require(query.view.descendantMenus().first { $0.items.contains { $0.title == "Run All Statements" } }, "Run button menu")
        print("Run button menu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title })")

        // Stop takes the Run button's place.
        reset("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        query.runCurrentQuery(nil)
        _ = try await waitFor("running") { query.isRunning ? true : nil }
        try await Task.sleep(for: .milliseconds(150))
        window.displayIfNeeded()
        snap("e4-running.png", window)
        query.cancelQuery(nil)
        _ = try await waitFor("stopped") { query.isRunning ? nil : true }
        window.displayIfNeeded()
        snap("e5-stopped.png", window)

        // The row limit a new tab starts with is the last one chosen.
        let previous = query.rowLimit
        query.chooseRowLimit(1_000)
        workspace.newQueryTab(nil)
        let next = try require(workspace.queryController, "another query tab")
        _ = next.view
        try check(next.rowLimit == 1_000, "a new tab starts with 1,000 rows")
        next.chooseRowLimit(previous ?? 0)

        // Show Filters doesn't repeat Find… in a query tab.
        let showFilters = try require(menuItem(NSApp.mainMenu, action: #selector(MoonrowActions.toggleFilters(_:))), "Show Filters")
        let edit = try require(showFilters.menu, "Edit menu")
        edit.delegate?.menuNeedsUpdate?(edit)
        _ = next.validateMenuItem(showFilters)
        try check(showFilters.isHidden, "Show Filters is hidden in a query tab")
        edit.delegate?.menuNeedsUpdate?(edit)
        try check(!showFilters.isHidden, "and shows again when the menu updates")
        // ⌘F reaches the item while it's hidden. The window isn't key in the background, so the
        // item is aimed at the tab, as the responder chain would.
        window.makeFirstResponder(next.editor)
        showFilters.target = next
        showFilters.isHidden = true
        defer { showFilters.target = nil }
        let commandF = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3), "⌘F")
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: commandF) ?? false
        try await Task.sleep(for: .milliseconds(200))
        print("⌘F: handled \(handled), hidden \(showFilters.isHidden)")
        try check(next.editor.enclosingScrollView?.isFindBarVisible == true, "⌘F shows the find bar")

        // Go to Line, and Return after `(` indents one level more.
        next.setText("select\n  (\n1\n)\nfrom t")
        next.goTo(line: 3)
        try check(next.editor.selectedRange().location == 11, "Go to Line 3 puts the caret at its start")
        let goTo = try require(menuItem(NSApp.mainMenu, action: #selector(MoonrowActions.goToLine(_:))), "Go to Line…")
        print("Edit ▸ \(goTo.title): \(KeyBinding(goTo.keyEquivalent, .init(goTo.keyEquivalentModifierMask)).display)")
        next.setText("select count(")
        window.makeFirstResponder(next.editor)
        next.editor.insertNewline(nil)
        try check(next.editor.string == "select count(\n    ", "Return after `(` indents (got \(next.editor.string.debugDescription))")

        // The parameters sheet: Tab goes through fields, pop-ups and buttons.
        let sheet = QueryParametersSheet(keys: ["id", "name"], remembered: [:])
        let sheetWindow = try require(sheet.window, "parameters sheet")
        sheetWindow.layoutIfNeeded()
        sheetWindow.recalculateKeyViewLoop()
        var loop: [String] = []
        var view = sheetWindow.initialFirstResponder
        var steps = 0
        while let v = view, steps < 60 {
            steps += 1
            if let field = v as? NSTextField, field.isEditable {
                loop.append("field")
            } else if let control = v as? NSButton, Swift.type(of: v) == NSPopUpButton.self || Swift.type(of: v) == NSButton.self {
                loop.append(control is NSPopUpButton ? "pop-up" : control.title)
            }
            view = v.nextKeyView
            if view === sheetWindow.initialFirstResponder { break }
        }
        print("parameters sheet key loop: \(loop.joined(separator: " → "))")
        try check(loop == ["field", "pop-up", "field", "pop-up", "Cancel", "Run"], "Tab reaches the pop-ups and buttons")
        snap("e6-parameters.png", sheetWindow)    }
}
