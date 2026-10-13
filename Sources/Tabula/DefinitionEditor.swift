import AppCore
import AppKit
import DBKit
import SQLScript

/// The CREATE statement of a view, materialized view, routine or trigger, editable. What's
/// typed is staged in the workspace's `StagedChanges` a second after typing stops, when the
/// editor loses the focus, and before a preview or commit; the commit runs it as
/// `Dialect.definitionPlan` says. One editing session (until the focus leaves) is one undo step;
/// inside it, ⌘Z undoes typing.
@MainActor
final class DefinitionEditorController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    enum Target: Equatable {
        case existing(DefinedObject)
        case new(UUID)
    }

    let target: Target
    let kind: DefinitionKind
    private let connection: any DatabaseConnection
    private let changes: StagedChanges
    /// Why the text can't be changed (a read-only connection), or nil.
    let readOnlyReason: String?
    /// Shown first in the bottom bar (a table tab's side switch).
    var leadingAccessory: NSView?
    /// After something was staged (tab titles follow the name in the text).
    var onStage: (() -> Void)?
    /// The user typed (a preview tab becomes regular).
    var onUse: (() -> Void)?
    /// Where undo goes back to.
    var place: EditPlace

    let editor = SQLTextView.make()
    private let highlighter: SQLHighlighter
    private var ruler: LineNumberRuler!
    private var highlightedLength = 0
    private let statusLabel = NSTextField(labelWithString: "")
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    /// The definition as the database has it; nil until loaded (always "" for a new object).
    private(set) var loaded: String?
    private var loadTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    /// Typed since the last staging.
    private var isDirty = false
    /// This editing session already has its undo step.
    private var stepOpen = false
    private var isStaging = false

    init(target: Target, kind: DefinitionKind, connection: any DatabaseConnection, changes: StagedChanges,
         readOnlyReason: String?, place: EditPlace) {
        self.target = target
        self.kind = kind
        self.connection = connection
        self.changes = changes
        self.readOnlyReason = readOnlyReason
        self.place = place
        self.highlighter = SQLHighlighter(dialect: connection.dialect.lexer)
        super.init(nibName: nil, bundle: nil)
        if case .new = target { loaded = "" }
        NotificationCenter.default.addObserver(
            self, selector: #selector(stagedChangesChanged), name: StagedChanges.didChange, object: changes)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var object: DefinedObject? {
        if case .existing(let o) = target { return o }
        return nil
    }

    /// What's staged for this editor, if anything.
    var staged: StagedDefinition? {
        switch target {
        case .existing(let o): changes.definition(for: o)
        case .new(let id): changes.definition(id)
        }
    }

    // MARK: - Layout

    override func loadView() {
        editor.delegate = self
        editor.isEditable = readOnlyReason == nil
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        ruler = LineNumberRuler(textView: editor, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        revertButton.bezelStyle = .accessoryBarAction
        revertButton.controlSize = .small
        revertButton.font = .systemFont(ofSize: 11)
        revertButton.target = self
        revertButton.action = #selector(revert(_:))
        revertButton.toolTip = "Put back the definition the database has"
        var views: [NSView] = [statusLabel, revertButton]
        if let leadingAccessory { views.insert(leadingAccessory, at: 0) }
        let bar = NSStackView(views: views)
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let line = NSBox()
        line.boxType = .separator

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        for v in [scroll, line, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            bar.topAnchor.constraint(equalTo: line.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // MARK: - Loading

    func stop() {
        loadTask?.cancel()
        stageTask?.cancel()
    }

    /// Shows what's staged, else reads the definition from the database again.
    func reload() {
        if let staged {
            loaded = staged.original
            return show(staged.text)
        }
        guard case .existing(let object) = target else { return show(loaded ?? "") }
        loadTask?.cancel()
        setStatus("Loading…")
        let connection = connection
        loadTask = Task {
            do {
                let text = try await ObjectActions.definitionText(object, on: connection)
                guard !Task.isCancelled else { return }
                loaded = text
                show(staged?.text ?? text)
            } catch {
                guard !Task.isCancelled else { return }
                setStatus("\(error)", isError: true)
            }
        }
    }

    private func show(_ text: String) {
        isDirty = false
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        highlightedLength = editor.textStorage!.length
        ruler?.textChanged()
        updateStatus()
    }

    // MARK: - Staging

    func textDidChange(_ notification: Notification) {
        let length = editor.textStorage!.length
        highlighter.highlight(editor.textStorage!, delta: length - highlightedLength, edited: editor.takeLastEdit())
        highlightedLength = length
        ruler.textChanged()
        isDirty = true
        onUse?()
        stageTask?.cancel()
        stageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.stageNow()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        stageNow()
        stepOpen = false
    }

    /// Stages what's typed, if it differs from what's staged.
    func stageNow() {
        stageTask?.cancel()
        stageTask = nil
        guard isDirty, readOnlyReason == nil, let loaded else { return }
        isDirty = false
        let text = editor.string
        let lexer = connection.dialect.lexer
        var d: StagedDefinition
        switch target {
        case .new(let id):
            guard var s = changes.definition(id), s.text != text else { return }
            s.setText(text, lexer: lexer)
            d = s
        case .existing(let object):
            if var s = changes.definition(for: object) {
                guard s.text != text else { return }
                s.setText(text, lexer: lexer)
                d = s
            } else {
                guard text != loaded else { return }
                d = StagedDefinition(kind: kind, object: object, schema: object.ref.schema, original: loaded, text: text, lexer: lexer)
            }
        }
        isStaging = true
        defer { isStaging = false }
        if stepOpen {
            changes.setDefinition(d)
        } else {
            changes.perform("Edit \(kind.title.capitalized)", at: place) { changes.setDefinition(d) }
            stepOpen = true
        }
        updateStatus()
        onStage?()
    }

    /// Undo, redo, Discard All or a commit changed what's staged: show it.
    @objc private func stagedChangesChanged() {
        guard isViewLoaded, !isStaging, !isDirty else { return }
        stepOpen = false
        if let staged {
            show(staged.text)
        } else if object != nil, let loaded {
            show(loaded)
        }
        onStage?()
    }

    @objc private func revert(_ sender: Any?) {
        guard let staged, !staged.isNew else { return }
        stageTask?.cancel()
        isDirty = false
        changes.perform("Revert \(kind.title.capitalized)", at: place) { changes.removeDefinition(staged.id) }
    }

    private var statusIsError = false

    private func setStatus(_ text: String, isError: Bool = false) {
        statusIsError = isError
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func updateStatus() {
        guard isViewLoaded else { return }
        let staged = staged
        revertButton.isHidden = staged == nil || staged?.isNew == true
        if let readOnlyReason { return setStatus(readOnlyReason) }
        switch (target, staged) {
        case (.new, _): setStatus("New \(kind.title), not created yet")
        case (_, .some): setStatus("Edited")
        default: setStatus("")
        }
    }

    @objc private func styleChanged() {
        editor.applyStyle()
        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        ruler?.textChanged()
    }

    // MARK: - Commands

    /// ⌘I in the editor: Beautify (the Edit menu's Add Row item, retitled).
    @objc func addRow(_ sender: Any?) { formatSQL(sender) }

    @objc func formatSQL(_ sender: Any?) {
        rewrite { SQLFormatter.format($0, dialect: self.connection.dialect.lexer) }
    }

    @objc func compactSQL(_ sender: Any?) {
        rewrite { SQLFormatter.compact($0, dialect: self.connection.dialect.lexer) }
    }

    @objc func toggleLineComment(_ sender: Any?) { editor.toggleLineComment(sender) }
    @objc func toggleBlockComment(_ sender: Any?) { editor.toggleBlockComment(sender) }

    private func rewrite(_ transform: (String) -> String) {
        guard editor.isEditable else { return NSSound.beep() }
        let text = editor.string as NSString
        var range = editor.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: text.length) }
        let old = text.substring(with: range)
        let new = transform(old)
        guard new != old, editor.shouldChangeText(in: range, replacementString: new) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: new)
        editor.didChangeText()
        view.window?.makeFirstResponder(editor)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(addRow(_:)):
            if item.menu?.title == "Edit" { item.title = "Beautify SQL" }
            return editor.isEditable
        case #selector(formatSQL(_:)), #selector(compactSQL(_:)), #selector(toggleLineComment(_:)),
             #selector(toggleBlockComment(_:)):
            return editor.isEditable
        default:
            return true
        }
    }
}
