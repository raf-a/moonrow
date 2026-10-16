import AppKit
import SQLScript

/// The connection form's bootstrap commands: SQL every session runs after connecting.
@MainActor
final class BootstrapCommandsController: NSViewController, NSTextViewDelegate {
    /// The text as typed, on every change.
    var onChange: ((String) -> Void)?
    let editor = SQLTextView.make()
    private let highlighter: SQLHighlighter
    private let initial: String
    private var highlightedLength = 0

    init(text: String, dialect: LexerDialect) {
        initial = text
        highlighter = SQLHighlighter(dialect: dialect)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Bootstrap Commands")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "SQL run after every connect and reconnect, before anything else. A failing statement fails the connect.")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor

        editor.string = initial
        editor.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let stack = NSStackView(views: [title, detail, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [detail, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 250))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pin(to: root, inset: 14)
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)
        styleChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(editor)
    }

    @objc private func styleChanged() {
        editor.applyStyle()
        highlighter.highlight(editor.textStorage!, delta: 0, full: true)
        highlightedLength = (editor.string as NSString).length
    }

    func textDidChange(_ notification: Notification) {
        let length = (editor.string as NSString).length
        highlighter.highlight(editor.textStorage!, delta: length - highlightedLength, edited: editor.takeLastEdit())
        highlightedLength = length
        onChange?(editor.string)
    }
}
