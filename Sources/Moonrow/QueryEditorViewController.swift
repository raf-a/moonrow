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
    /// The connection's queries folder; replaced when that folder changes.
    var savedQueries: SavedQueries
    /// Asks before statements go out, as the connection's safe mode says.
    let safety: SafetyGate
    /// Accepted completions, most recent first; ranks them higher next time.
    var recentCompletions: [String] = []
    /// A statement created, dropped or altered something.
    var onSchemaChange: (() -> Void)?
    /// Which columns the table grids show (shared by the workspace's table tabs).
    var columnLayouts: ColumnLayouts?
    /// The folder selected in the sidebar's Queries pane; the save panel starts there.
    var selectedQueriesFolder: (() -> String?)?
    /// The last value typed for each query parameter.
    var parameterInputs: [String: QueryParametersSheet.Input] = [:]

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
    /// Runs the current statement or all of them, as Settings' Run button default says.
    private let runButton = NSButton(title: "Run Current", target: nil, action: nil)
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
    let tabID = UUID()
    /// After the text changes (the workspace saves its session).
    var onEdit: (() -> Void)?

    /// The SQL file outside the queries folder that the tab was opened from (File ▸ Open…) or
    /// saved to. It names the tab; Save and Save As… write it.
    private(set) var fileURL: URL? {
        didSet { onTabItemChange?() }
    }

    /// The text the tab opened with, when a copy is kept elsewhere (a history entry, say);
    /// closing the tab with it unchanged loses nothing.
    private let keptText: String?

    init(environment: QueryEnvironment, number: Int, text: String = "", savedQuery: SavedQueries.Query? = nil,
         file: URL? = nil, kept: Bool = false) {
        self.environment = environment
        self.number = number
        self.savedQuery = savedQuery
        self.fileURL = file
        self.keptText = kept ? text : nil
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

        runButton.target = self
        runButton.action = #selector(runDefault(_:))
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        runButton.imagePosition = .imageLeading
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
        // No shortcuts here: AppKit would take them off the main menu's items (it gives each
        // shortcut to one item).
        for (title, action) in [
            ("Run All", #selector(runAllQueries(_:))),
            ("Run Current", #selector(runCurrentQuery(_:))),
            ("-", nil),
            ("Beautify SQL", #selector(formatSQL(_:))),
            ("Compact SQL", #selector(compactSQL(_:))),
            ("-", nil),
            ("Save", #selector(saveQuery(_:))),
            ("Save As…", #selector(saveQueryAs(_:))),
        ] as [(String, Selector?)] {
            if title == "-" { menu.addItem(.separator()); continue }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let defaults = menu.addItem(withTitle: "Default", action: nil, keyEquivalent: "")
        defaults.submenu = NSMenu(title: "Default")
        for (title, all) in [("Run Current", false), ("Run All", true)] {
            let item = defaults.submenu!.addItem(withTitle: title, action: #selector(setRunDefault(_:)), keyEquivalent: "")
            item.target = self
            item.tag = all ? 1 : 0
        }
        for b in [runButton, stopButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        updateRunButton()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [positionLabel, spacer, spinner, limitPopup, stopButton, runButton, runMenuButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return bar
    }

    // MARK: - WorkspaceTab

    var tabItem: TabStrip.Item {
        if savedQuery == nil, let fileURL {
            return TabStrip.Item(title: fileURL.lastPathComponent, symbol: "doc.text",
                                 toolTip: (fileURL.path as NSString).abbreviatingWithTildeInPath,
                                 background: AppStyle.colors.background)
        }
        return TabStrip.Item(title: savedQuery?.name ?? "Query \(number)", symbol: "terminal",
                             toolTip: savedQuery.map { "Saved query “\($0.name)”" } ?? "Unsaved query",
                             background: AppStyle.colors.background)
    }

    var preferredResponder: NSView { editor }

    /// A query that isn't saved anywhere: closing offers to save it.
    var asksBeforeClosing: Bool {
        guard savedQuery == nil else { return false }
        let fileText = fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return SavedQueries.offersToSave(editor.string, keptAs: [keptText, fileText])
    }

    func prepareToClose(then proceed: @escaping () -> Void) {
        guard asksBeforeClosing, let window = view.window else { return proceed() }
        let alert = NSAlert()
        alert.messageText = "Save “\(tabItem.title)”?"
        // A file tab saves to its file; any other asks where.
        alert.informativeText = fileURL == nil ? "Closing the tab drops its text." : "Closing the tab drops its changes."
        alert.addButton(withTitle: fileURL == nil ? "Save…" : "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            // The save panel follows this sheet once it's gone.
            case .alertFirstButtonReturn: DispatchQueue.main.async { self?.save(then: proceed) }
            case .alertSecondButtonReturn: proceed()
            default: break
            }
        }
    }

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

    /// The Run button: the current statement or all, as chosen in its menu's Default ▸.
    @objc func runDefault(_ sender: Any?) {
        AppStyle.settings.runButtonRunsAll ? runAllQueries(sender) : runCurrentQuery(sender)
    }

    @objc private func setRunDefault(_ sender: NSMenuItem) {
        let all = sender.tag == 1
        guard let store = (NSApp.delegate as? AppDelegate)?.settings else { return }
        try? store.update { $0.runButtonRunsAll = all }
    }

    private func updateRunButton() {
        let all = AppStyle.settings.runButtonRunsAll
        runButton.title = all ? "Run All" : "Run Current"
        runButton.toolTip = all ? "Run every statement, or the selected text (⇧⌘↩)"
            : "Run the statement at the cursor, or the selected text (⌘↩)"
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
        withParameters(statements) { [weak self] in self?.approve($0) }
    }

    /// Fills in the statements' parameters, asking for their values, when there are any and
    /// Settings ▸ General asks for them. The statements keep their ranges in the editor.
    private func withParameters(_ statements: [SQLStatementRange], then proceed: @escaping ([SQLStatementRange]) -> Void) {
        let dialect = environment.connection.dialect
        guard AppStyle.settings.queryParameters, let window = view.window else { return proceed(statements) }
        let found = QueryParameters.find(in: statements.map(\.text), dialect: dialect.lexer, styles: QueryParameters.styles(for: dialect))
        guard !found.keys.isEmpty else { return proceed(statements) }
        isAwaitingApproval = true
        let sheet = QueryParametersSheet(keys: found.keys, remembered: environment.parameterInputs)
        parameterSheet = sheet
        sheet.begin(on: window) { [weak self] inputs in
            guard let self else { return }
            self.isAwaitingApproval = false
            self.parameterSheet = nil
            guard let inputs else { return }
            self.environment.parameterInputs.merge(inputs) { $1 }
            let values = inputs.mapValues { QueryParameters.sql(for: $0.text, kind: $0.kind, dialect: dialect) }
            let texts = QueryParameters.substitute(statements.map(\.text), found.occurrences, values: values)
            proceed(zip(statements, texts).map { statement, text in
                var s = statement
                s.text = text
                return s
            })
        }
    }

    /// For the dev harness: the parameters sheet while it's asking.
    private(set) var parameterSheet: QueryParametersSheet?

    private func approve(_ statements: [SQLStatementRange]) {
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
        runButton.isEnabled = !running
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
        highlighter.highlight(editor.textStorage!, delta: length - highlightedLength, edited: editor.takeLastEdit())
        highlightedLength = length
        ruler.textChanged()
        clearErrorHighlight()
        updatePosition()
        updateStatementHighlight()
        if savedQuery != nil { scheduleAutosave() }
        onEdit?()
    }

    /// The theme or font changed in the preferences.
    @objc private func styleChanged() {
        updateRunButton()
        editor.applyStyle()
        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        ruler.textChanged()
        updateStatementHighlight()
        // The tab is filled with the editor's background.
        onTabItemChange?()
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

    // ⌘S commits the workspace's staged changes, as everywhere. Save and Save As… write the
    // text to a `.sql` file; one in the connection's queries folder is a saved query.

    /// Writes the text back to the tab's saved query or file; a tab with neither asks where.
    @objc func saveQuery(_ sender: Any?) { save(then: nil) }

    /// ⇧⌘S: asks where to save, in the queries folder unless the tab has a query or file
    /// elsewhere.
    @objc func saveQueryAs(_ sender: Any?) { saveAs(then: nil) }

    /// `saved` runs once the text is saved (not after Cancel or an error).
    private func save(then saved: (() -> Void)?) {
        let url = savedQuery?.url ?? fileURL
        guard let url else { return saveAs(then: saved) }
        if save(to: url) { saved?() }
    }

    private func saveAs(then saved: (() -> Void)?) {
        guard let window = view.window else { return }
        let store = environment.savedQueries
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.canCreateDirectories = true
        if let current = savedQuery?.url ?? fileURL {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        } else {
            // The folder selected in the sidebar's Queries pane, as a new query goes there.
            let folder = environment.selectedQueriesFolder?().flatMap { store.folders.contains($0) ? $0 : nil }
            panel.directoryURL = folder.map { store.directory.appending(path: $0, directoryHint: .isDirectory) } ?? store.directory
            panel.nameFieldStringValue = tabItem.title + ".sql"
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if self.save(to: url) { saved?() }
        }
    }

    /// Writes the text to `url` (the save panel replaced a file there already). In the queries
    /// folder or one of its folders it's a saved query, anywhere else a file; the tab edits it
    /// from now on.
    @discardableResult
    func save(to url: URL) -> Bool {
        // The query being left keeps what was typed into it.
        if savedQuery?.url != url { saveIfDirty() }
        do {
            if let place = environment.savedQueries.location(of: url) {
                savedQuery = try environment.savedQueries.save(editor.string, as: place.name, in: place.folder, overwrite: true)
                fileURL = nil
            } else {
                try Data(editor.string.utf8).write(to: url, options: .atomic)
                savedQuery = nil
                fileURL = url
            }
            isDirty = false
            autosaveTask?.cancel()
            onTabItemChange?()
            return true
        } catch {
            presentError(error, title: "Couldn't save “\(url.deletingPathExtension().lastPathComponent)”")
            return false
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
            try environment.savedQueries.save(editor.string, as: savedQuery.name, in: savedQuery.folder, overwrite: true)
        } catch {
            presentError(error, title: "Couldn't save “\(savedQuery.name)”")
        }
    }

    /// The saved query was renamed or deleted from the sidebar, or moved to another folder.
    func savedQueryChanged(to query: SavedQueries.Query?) {
        savedQuery = query
        onTabItemChange?()
    }

    /// The saved query's file changed outside the app. Without edits of its own, the tab shows
    /// the file's text, as one undoable change.
    func savedQueryChangedOnDisk(_ query: SavedQueries.Query) {
        savedQuery = query
        guard !isDirty, let text = try? environment.savedQueries.text(of: query), text != editor.string else { return }
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        let selection = editor.selectedRange()
        guard editor.shouldChangeText(in: all, replacementString: text) else { return }
        editor.textStorage?.replaceCharacters(in: all, with: text)
        editor.didChangeText()
        // The text is the file's: nothing to write back.
        autosaveTask?.cancel()
        isDirty = false
        let length = (text as NSString).length
        editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    private func presentError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Menus

    /// Edit ▸ Add Row's ⌘I, in a query tab: Beautify.
    @objc func addRow(_ sender: Any?) { formatSQL(sender) }

    /// ⌘I: lays out the selected statements, or the whole script, as one undoable change.
    @objc func formatSQL(_ sender: Any?) {
        rewrite { SQLFormatter.format($0, dialect: self.dialect) }
    }

    /// ⇧⌘I: the selection, or the whole script, on as few lines as possible.
    @objc func compactSQL(_ sender: Any?) {
        rewrite { SQLFormatter.compact($0, dialect: self.dialect) }
    }

    private func rewrite(_ transform: (String) -> String) {
        let text = editor.string as NSString
        var range = editor.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: text.length) }
        let old = text.substring(with: range)
        let new = transform(old)
        guard new != old else { return }
        guard editor.shouldChangeText(in: range, replacementString: new) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: new)
        editor.didChangeText()
        editor.setSelectedRange(range.location == 0 && range.length == text.length
            ? NSRange(location: 0, length: 0) : NSRange(location: range.location, length: (new as NSString).length))
        view.window?.makeFirstResponder(editor)
    }

    @objc func toggleLineComment(_ sender: Any?) { editor.toggleLineComment(sender) }
    @objc func toggleBlockComment(_ sender: Any?) { editor.toggleBlockComment(sender) }

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
            if item.action == #selector(runCurrentQuery(_:)), item.menu?.title == "Connection" { item.title = "Run Current Statement" }
            return !isRunning && !isAwaitingApproval
        case #selector(addRow(_:)):
            if item.menu?.title == "Edit" { item.title = "Beautify SQL" }
            return !isRunning
        case #selector(cancelQuery(_:)):
            return isRunning
        case #selector(setRunDefault(_:)):
            item.state = (item.tag == 1) == AppStyle.settings.runButtonRunsAll ? .on : .off
            return true
        case #selector(formatSQL(_:)), #selector(compactSQL(_:)):
            return !isRunning
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

    /// For the dev harness: what the Run button runs.
    var runButtonTitle: String { runButton.title }

    /// For the dev harness: the items the list is showing.
    var completionItems: [SQLCompletion.Item] { completion.items }
}

extension Duration {
    var milliseconds: Int {
        Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
