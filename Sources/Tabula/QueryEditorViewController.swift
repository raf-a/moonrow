import AppCore
import AppKit
import DBKit
import SQLScript

/// What every query tab of a workspace shares.
@MainActor
final class QueryEnvironment {
    let connection: any DatabaseConnection
    let catalog: SchemaCatalog
    let history: QueryHistory
    let savedQueries: SavedQueries
    /// Asks before statements go out, as the connection's safe mode says.
    let safety: SafetyGate
    /// Accepted completions, most recent first; ranks them higher next time.
    var recentCompletions: [String] = []
    /// A statement created, dropped or altered something.
    var onSchemaChange: (() -> Void)?

    init(connection: any DatabaseConnection, history: QueryHistory, savedQueries: SavedQueries, safety: SafetyGate) {
        self.connection = connection
        self.catalog = SchemaCatalog(connection: connection)
        self.history = history
        self.savedQueries = savedQueries
        self.safety = safety
    }

    func noteCompletion(_ text: String) {
        recentCompletions.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recentCompletions.insert(text, at: 0)
        if recentCompletions.count > 100 { recentCompletions.removeLast() }
    }
}

/// A SQL editor over its results. ⌘↩ runs the statement at the cursor (or the selection),
/// ⇧⌘↩ runs everything, ⌘. stops.
@MainActor
final class QueryEditorViewController: NSViewController, NSTextViewDelegate,
    NSMenuItemValidation, SQLTextViewCompletionDelegate, NSSplitViewDelegate, WorkspaceTab
{
    let environment: QueryEnvironment
    let editor = SQLTextView.make()
    let results = ResultsViewController()
    private let number: Int
    private(set) var savedQuery: SavedQueries.Query?
    private var dialect: LexerDialect { environment.connection.dialect.lexer }

    private let highlighter: SQLHighlighter
    private var ruler: LineNumberRuler!
    private let completion = CompletionPopup()
    private var completionContext: SQLCompletion.Context?
    private var isInsertingCompletion = false

    private let split = NSSplitView()
    private let runCurrentButton = NSButton(title: "Run Current", target: nil, action: nil)
    private let runAllButton = NSButton(title: "Run All", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let runMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let limitPopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let positionLabel = NSTextField(labelWithString: "")

    private var runTask: Task<Void, Never>?
    private(set) var isRunning = false
    /// Safe mode is asking about the statements to run.
    private var isAwaitingApproval = false
    private var autosaveTask: Task<Void, Never>?
    private var isDirty = false
    /// Text length when last highlighted; each change's length delta follows from it.
    private var highlightedLength = 0
    private var statementHighlight: NSRange?

    static let rowLimits = [100, 300, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000]
    /// Same as the grid's default page size.
    static let defaultRowLimit = 300
    /// Nil: every row.
    var rowLimit: Int? {
        let tag = limitPopup.selectedTag()
        return tag > 0 ? tag : nil
    }

    var onTabItemChange: (() -> Void)?

    init(environment: QueryEnvironment, number: Int, text: String = "", savedQuery: SavedQueries.Query? = nil) {
        self.environment = environment
        self.number = number
        self.savedQuery = savedQuery
        self.highlighter = SQLHighlighter(dialect: environment.connection.dialect.lexer)
        super.init(nibName: nil, bundle: nil)
        editor.string = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func loadView() {
        editor.delegate = self
        editor.completionDelegate = self
        completion.onAccept = { [weak self] item in self?.insertCompletion(item) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(catalogChanged), name: SchemaCatalog.didChange, object: environment.catalog)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)

        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        ruler = LineNumberRuler(textView: editor, scrollView: editorScroll)
        editorScroll.verticalRulerView = ruler
        editorScroll.hasVerticalRuler = true
        editorScroll.rulersVisible = true

        let top = NSView()
        let bar = makeActionBar()
        let line = NSBox()
        line.boxType = .separator
        for v in [editorScroll, line, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(v)
        }
        NSLayoutConstraint.activate([
            editorScroll.topAnchor.constraint(equalTo: top.topAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            line.topAnchor.constraint(equalTo: editorScroll.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            bar.topAnchor.constraint(equalTo: line.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        addChild(results)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(top)
        split.addArrangedSubview(results.view)
        split.autosaveName = "QueryEditorSplit"
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        view = split
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        highlightedLength = editor.textStorage!.length
        ruler.textChanged()
        updatePosition()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // First appearance without a saved divider: editor gets 45 %.
        if split.subviews[0].frame.height < 1 || UserDefaults.standard.object(forKey: "NSSplitView Subview Frames QueryEditorSplit") == nil {
            split.setPosition(split.bounds.height * 0.45, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(proposed, 100)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(proposed, splitView.bounds.height - 80)
    }

    private func makeActionBar() -> NSView {
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor

        limitPopup.controlSize = .small
        limitPopup.font = .systemFont(ofSize: 11)
        limitPopup.addItem(withTitle: "No limit")
        limitPopup.lastItem?.tag = 0
        for n in Self.rowLimits {
            limitPopup.addItem(withTitle: "\(n.formatted()) rows")
            limitPopup.lastItem?.tag = n
        }
        limitPopup.selectItem(withTag: Self.defaultRowLimit)
        limitPopup.toolTip = "Most rows to keep per result"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        runCurrentButton.target = self
        runCurrentButton.action = #selector(runCurrentQuery(_:))
        runCurrentButton.toolTip = "Run the statement at the cursor, or the selected text (⌘↩)"
        runCurrentButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        runCurrentButton.imagePosition = .imageLeading
        runAllButton.target = self
        runAllButton.action = #selector(runAllQueries(_:))
        runAllButton.toolTip = "Run every statement (⇧⌘↩)"
        stopButton.target = self
        stopButton.action = #selector(cancelQuery(_:))
        stopButton.toolTip = "Stop the running query (⌘.)"
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.imagePosition = .imageLeading
        stopButton.isHidden = true
        runMenuButton.pullsDown = true
        runMenuButton.isBordered = false
        runMenuButton.toolTip = "More run and save commands"
        let menu = runMenuButton.menu!
        // A pull-down shows its first item, so that item carries the button's image.
        let titleItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More")
        (runMenuButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        runMenuButton.imagePosition = .imageOnly
        runMenuButton.controlSize = .small
        for (title, action, key, mods) in [
            ("Run All", #selector(runAllQueries(_:)), "\r", NSEvent.ModifierFlags([.command, .shift])),
            ("Run Current", #selector(runCurrentQuery(_:)), "\r", .command),
            ("Add to Queries…", #selector(addToQueries(_:)), "", .command),
            ("Save SQL As…", #selector(saveSQLAs(_:)), "S", [.command, .shift]),
        ] {
            if title == "Add to Queries…" { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        for b in [runCurrentButton, runAllButton, stopButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [positionLabel, spacer, spinner, limitPopup, stopButton, runAllButton, runCurrentButton, runMenuButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return bar
    }

    // MARK: - WorkspaceTab

    var tabItem: TabStrip.Item {
        TabStrip.Item(title: savedQuery?.name ?? "Query \(number)", symbol: "terminal",
                      toolTip: savedQuery.map { "Saved query “\($0.name)”" } ?? "Unsaved query")
    }

    var preferredResponder: NSView { editor }

    func prepareToClose(then proceed: @escaping () -> Void) { proceed() }

    func tabDidClose() {
        runTask?.cancel()
        completion.hide()
        saveIfDirty()
    }

    // MARK: - Running

    @objc func runCurrentQuery(_ sender: Any?) {
        run(ScriptSelection.current(in: editor.string, selection: selection, dialect: dialect))
    }

    @objc func runAllQueries(_ sender: Any?) {
        run(ScriptSelection.all(in: editor.string, selection: selection, dialect: dialect))
    }

    @objc func cancelQuery(_ sender: Any?) {
        guard let runTask else { return NSSound.beep() }
        runTask.cancel()
    }

    private var selection: Range<Int> {
        let r = editor.selectedRange()
        return r.location..<NSMaxRange(r)
    }

    /// Runs `statements` (UTF-16 ranges into the editor text) and shows their results, once safe
    /// mode allows it.
    func run(_ statements: [SQLStatementRange]) {
        guard !isRunning, !isAwaitingApproval else { return NSSound.beep() }
        guard !statements.isEmpty else { return NSSound.beep() }
        completion.hide()
        guard environment.safety.requirement(for: statements.map(\.text)) != .none else { return start(statements) }
        isAwaitingApproval = true
        Task {
            let approved = await environment.safety.approve(statements.map(\.text))
            isAwaitingApproval = false
            if approved { start(statements) }
        }
    }

    private func start(_ statements: [SQLStatementRange]) {
        clearErrorHighlight()
        let textAtStart = editor.string
        let options = ScriptRunner.Options(rowLimit: rowLimit, stopOnError: true)
        let events = ScriptRunner.run(statements, on: environment.connection, options: options)
        results.beginRun(statements)
        setRunning(true)
        runTask = Task { [weak self] in
            var current: Int?
            var changedSchema = false
            for await event in events {
                guard let self else { return }
                self.results.handle(event)
                switch event {
                case .started(let i):
                    current = i
                case .finished(let i, let outcome):
                    current = nil
                    self.environment.history.add(.init(sql: statements[i].text, ms: outcome.duration.milliseconds))
                    changedSchema = changedSchema || Self.changesSchema(statements[i].text, self.dialect)
                case .failed(let i, _, let duration):
                    current = nil
                    self.environment.history.add(.init(sql: statements[i].text, ms: duration.milliseconds, ok: false))
                    if self.editor.string == textAtStart { self.highlightError(statements[i].range) }
                default:
                    break
                }
            }
            guard let self else { return }
            if Task.isCancelled { self.results.cancelled(atStatement: current) }
            self.runTask = nil
            self.setRunning(false)
            if changedSchema { self.environment.onSchemaChange?() }
        }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        stopButton.isHidden = !running
        runCurrentButton.isEnabled = !running
        runAllButton.isEnabled = !running
        limitPopup.isEnabled = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    static func changesSchema(_ sql: String, _ dialect: LexerDialect) -> Bool {
        let first = SQLLexer(sql, dialect: dialect).tokens().first { !$0.kind.isTrivia }
        guard let first else { return false }
        let word = (sql as NSString).substring(with: NSRange(location: first.range.lowerBound, length: first.range.count)).uppercased()
        return ["CREATE", "DROP", "ALTER"].contains(word)
    }

    // MARK: - Highlights

    private func highlightError(_ range: Range<Int>) {
        guard let layout = editor.layoutManager, range.upperBound <= (editor.string as NSString).length else { return }
        let r = NSRange(location: range.lowerBound, length: range.count)
        layout.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.systemRed,
        ], forCharacterRange: r)
    }

    private func clearErrorHighlight() {
        guard let layout = editor.layoutManager else { return }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
    }

    /// Tints the statement ⌘↩ would run.
    private func updateStatementHighlight() {
        guard let layout = editor.layoutManager else { return }
        let length = (editor.string as NSString).length
        if let old = statementHighlight, NSMaxRange(old) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        statementHighlight = nil
        let sel = editor.selectedRange()
        // Skipped for very long scripts, where re-splitting on every caret move would show.
        guard sel.length == 0, length < 400_000,
              let statement = SQLSplitter.statement(at: sel.location, in: editor.string, dialect: dialect) else { return }
        // Only worth showing when there's more than one statement.
        guard statement.range.count < length - 1 || editor.string.contains(";") else { return }
        let r = NSRange(location: statement.range.lowerBound, length: statement.range.count)
        layout.addTemporaryAttribute(.backgroundColor, value: AppStyle.colors.currentStatement, forCharacterRange: r)
        statementHighlight = r
    }

    // MARK: - Text changes

    func textDidChange(_ notification: Notification) {
        let length = editor.textStorage!.length
        highlighter.highlight(editor.textStorage!, delta: length - highlightedLength)
        highlightedLength = length
        ruler.textChanged()
        clearErrorHighlight()
        updatePosition()
        updateStatementHighlight()
        if savedQuery != nil { scheduleAutosave() }
    }

    /// The theme or font changed in the preferences.
    @objc private func styleChanged() {
        editor.applyStyle()
        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        ruler.textChanged()
        updateStatementHighlight()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updatePosition()
        updateStatementHighlight()
        ruler.needsDisplay = true
    }

    private func updatePosition() {
        let caret = editor.selectedRange().location
        let line = ruler.line(at: caret)
        let column = caret - ruler.lineStart(line) + 1
        let sel = editor.selectedRange().length
        positionLabel.stringValue = "Line \(line), Column \(column)" + (sel > 0 ? " — \(sel) selected" : "")
    }

    /// Replaces the editor's text as one undoable change.
    func setText(_ text: String) {
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.insertText(text, replacementRange: all)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Inserts at the cursor on a line of its own.
    func insertStatement(_ sql: String) {
        let text = editor.string as NSString
        var insertion = sql
        let at = editor.selectedRange()
        if at.location > 0, text.character(at: at.location - 1) != 10 { insertion = "\n" + insertion }
        editor.insertText(insertion, replacementRange: at)
        view.window?.makeFirstResponder(editor)
    }

    // MARK: - Saving

    // ⌘S commits the workspace's staged changes, as everywhere. Saving
    // the text is Add to Queries (the sidebar's Queries) or Save SQL As… (a file).

    /// Saves the text to the connection's saved queries: a tab opened from one writes it back,
    /// any other asks for a name.
    @objc func addToQueries(_ sender: Any?) {
        if let savedQuery { return write(to: savedQuery.name, overwrite: true) }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add to Queries"
        alert.informativeText = "Saved queries are listed under Queries in the sidebar."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Name"
        field.stringValue = savedQuery?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue
            if let existing = self.environment.savedQueries.query(named: name), existing != self.savedQuery {
                self.confirmReplace(existing.name) { self.write(to: name, overwrite: true) }
            } else {
                self.write(to: name, overwrite: self.environment.savedQueries.query(named: name) != nil)
            }
        }
    }

    /// ⇧⌘S: writes the editor's text to a `.sql` file.
    @objc func saveSQLAs(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = (savedQuery?.name ?? tabItem.title) + ".sql"
        let text = editor.string
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                self?.presentError(error, title: "Couldn't save the SQL")
            }
        }
    }

    private func confirmReplace(_ name: String, then proceed: @escaping () -> Void) {
        guard let window = view.window else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Replace “\(name)”?"
            alert.informativeText = "A saved query with that name already exists."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { proceed() } }
        }
    }

    private func write(to name: String, overwrite: Bool) {
        do {
            savedQuery = try environment.savedQueries.save(editor.string, as: name, overwrite: overwrite)
            isDirty = false
            autosaveTask?.cancel()
            onTabItemChange?()
        } catch {
            presentError(error, title: "Couldn't save the query")
        }
    }

    /// A saved query's tab writes changes back a second after typing stops.
    private func scheduleAutosave() {
        isDirty = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveIfDirty()
        }
    }

    func saveIfDirty() {
        guard isDirty, let savedQuery else { return }
        isDirty = false
        do {
            try environment.savedQueries.save(editor.string, as: savedQuery.name, overwrite: true)
        } catch {
            presentError(error, title: "Couldn't save “\(savedQuery.name)”")
        }
    }

    /// The saved query was renamed or deleted from the sidebar.
    func savedQueryChanged(to query: SavedQueries.Query?) {
        savedQuery = query
        onTabItemChange?()
    }

    private func presentError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Menus

    @objc func toggleLineComment(_ sender: Any?) { editor.toggleLineComment(sender) }

    /// ⌘F: tables filter, query tabs find.
    @objc func toggleFilters(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.window?.makeFirstResponder(editor)
        editor.performFindPanelAction(item)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(runCurrentQuery(_:)), #selector(runAllQueries(_:)):
            return !isRunning && !isAwaitingApproval
        case #selector(cancelQuery(_:)):
            return isRunning
        case #selector(toggleFilters(_:)):
            item.title = "Find…"
            return true
        default:
            return true
        }
    }

    // MARK: - Completion

    var isCompletionVisible: Bool { completion.isVisible }

    func textViewNeedsCompletion(_ textView: SQLTextView, manual: Bool) {
        guard !isInsertingCompletion else { return }
        let caret = editor.selectedRange()
        guard caret.length == 0,
              let context = SQLCompletion.context(in: editor.string, at: caret.location, dialect: dialect) else {
            return textViewDismissCompletion()
        }
        // Typing opens the list once there's a letter, or right after a dot.
        if !manual, !completion.isVisible, context.prefix.isEmpty, context.expects != .column {
            return textViewDismissCompletion()
        }
        completionContext = context
        var wanted = context.tables.map(\.name)
        if let q = context.qualifier {
            wanted.append(context.tables.first { $0.alias?.caseInsensitiveCompare(q) == .orderedSame }?.name ?? q)
        }
        environment.catalog.loadColumns(of: wanted)
        showCompletions(manual: manual)
    }

    private func showCompletions(manual: Bool) {
        guard let context = completionContext, let window = view.window else { return }
        let items = SQLCompletion.candidates(
            for: context, catalog: environment.catalog.completionCatalog,
            keywords: dialect.keywords,
            recent: environment.recentCompletions)
        // Nothing to offer, or the word is already complete.
        if items.isEmpty || (!manual && items.count == 1 && items[0].text.caseInsensitiveCompare(context.prefix) == .orderedSame) {
            return completion.hide()
        }
        let r = NSRange(location: context.replaceRange.lowerBound, length: context.replaceRange.count)
        var anchor = editor.firstRect(forCharacterRange: r, actualRange: nil)
        if anchor.width == 0 { anchor.size.width = 1 }
        completion.show(items, below: anchor, in: window)
    }

    /// Columns arrived: refresh the list, or show it if it was waiting for them, as long as the
    /// cursor is still where completion was asked for.
    @objc private func catalogChanged() {
        guard let context = completionContext, view.window?.firstResponder === editor,
              editor.selectedRange() == NSRange(location: context.replaceRange.upperBound, length: 0) else { return }
        showCompletions(manual: completion.isVisible)
    }

    func textViewMoveCompletion(by delta: Int) { completion.moveSelection(by: delta) }

    func textViewAcceptCompletion() -> Bool { completion.acceptSelected() }

    func textViewDismissCompletion() {
        completion.hide()
        completionContext = nil
    }

    private func insertCompletion(_ item: SQLCompletion.Item) {
        guard let context = completionContext else { return }
        let r = NSRange(location: context.replaceRange.lowerBound, length: context.replaceRange.count)
        guard NSMaxRange(r) <= (editor.string as NSString).length else { return }
        isInsertingCompletion = true
        editor.insertText(SQLCompletion.insertion(for: item, dialect: dialect), replacementRange: r)
        isInsertingCompletion = false
        environment.noteCompletion(item.text)
        completionContext = nil
    }

    /// For the dev harness: the items the list is showing.
    var completionItems: [SQLCompletion.Item] { completion.items }
}

extension Duration {
    var milliseconds: Int {
        Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
