import AppCore
import AppKit
import SQLScript

/// Page size and offset for the grid, applied together with Go.
@MainActor
final class PagingController: NSViewController {
    var onGo: ((Paging) -> Void)?
    private let sizeField = NSTextField()
    private let offsetField = NSTextField()
    private let paging: Paging

    init(_ paging: Paging) {
        self.paging = paging
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        sizeField.placeholderString = "All rows"
        sizeField.stringValue = paging.pageSize.map(String.init) ?? ""
        offsetField.stringValue = String(paging.offset)
        for f in [sizeField, offsetField] {
            f.widthAnchor.constraint(equalToConstant: 110).isActive = true
            f.target = self
            f.action = #selector(go(_:))
        }
        let go = NSButton(title: "Go", target: self, action: #selector(go(_:)))
        go.keyEquivalent = "\r"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Page size"), sizeField],
            [NSTextField(labelWithString: "Offset"), offsetField],
            [NSGridCell.emptyContentView, go],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.cell(for: go)?.xPlacement = .trailing
        let root = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        grid.pin(to: root, inset: 12)
        view = root
    }

    @objc private func go(_ sender: Any?) {
        let size = Int(sizeField.stringValue.filter(\.isNumber))
        let offset = Int(offsetField.stringValue.filter(\.isNumber)) ?? 0
        onGo?(Paging(pageSize: size, offset: offset))
    }
}

/// The SQL a commit will run, with Discard and Commit.
@MainActor
final class ChangesPreviewController: NSViewController {
    var onCommit: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onCancel: (() -> Void)?
    private let statements: [String]
    private let note: String?
    private let summary: String?
    private let text = SQLTextView.make()
    private let highlighter: SQLHighlighter

    /// `summary` replaces the "N statements, run in one transaction" line.
    init(statements: [String], note: String?, summary: String? = nil, dialect: LexerDialect) {
        self.statements = statements
        self.note = note
        self.summary = summary
        highlighter = SQLHighlighter(dialect: dialect)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        text.isEditable = false
        text.string = statements.joined(separator: "\n")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let noteLabel = NSTextField(wrappingLabelWithString: note ?? "")
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .systemOrange
        noteLabel.isHidden = note == nil

        let discard = NSButton(title: "Discard All", target: self, action: #selector(discard(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let commit = NSButton(title: "Commit", target: self, action: #selector(commit(_:)))
        commit.keyEquivalent = "\r"
        let count = NSTextField(labelWithString: summary
            ?? "\(statements.count) \(statements.count == 1 ? "statement" : "statements"), run in one transaction")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [count, NSView(), discard, cancel, commit])

        let stack = NSStackView(views: [scroll, noteLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [scroll, buttons, noteLabel] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pin(to: root, inset: 12)
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)
        styleChanged()
    }

    @objc private func styleChanged() {
        text.applyStyle()
        highlighter.highlight(text.textStorage!, delta: 0, full: true)
    }

    @objc private func commit(_ sender: Any?) { onCommit?() }
    @objc private func discard(_ sender: Any?) { onDiscard?() }
    @objc private func cancel(_ sender: Any?) { onCancel?() }
}

/// Edits a value that doesn't fit an inline field (several lines, or long).
@MainActor
final class CellTextEditorController: NSViewController {
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let initial: String
    private var textView: NSTextView!

    init(text: String) {
        initial = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        textView = (scroll.documentView as! NSTextView)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = initial

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        let hint = NSTextField(labelWithString: "⌘↩ saves, Esc cancels")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [hint, NSView(), cancel, save])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        for v in [scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pin(to: root, inset: 10)
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    @objc private func save(_ sender: Any?) { onSave?(textView.string) }
    @objc private func cancel(_ sender: Any?) { onCancel?() }
}
