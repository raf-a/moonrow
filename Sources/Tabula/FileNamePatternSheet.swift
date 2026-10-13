import AppCore
import AppKit

/// A placeholder in the editor's token field. Text between placeholders stays a plain string.
private final class PatternToken: NSObject {
    let token: FileNamePattern.Token

    init(_ token: FileNamePattern.Token) {
        self.token = token
    }
}

/// Edits a file name pattern (Backup, the export sheets): the pattern as placeholder tokens and
/// text, buttons that add placeholders and separators, and the name it gives now.
@MainActor
final class FileNamePatternSheet: NSObject, NSTokenFieldDelegate {
    let sheet: NSWindow
    let field = NSTokenField()
    let previewLabel = NSTextField(labelWithString: "")
    private let defaultPattern: String
    private let preview: (String) -> String
    private let done: (String) -> Void

    /// Separators offered next to the placeholders: what they add and their button's title.
    static let separators: [(String, String)] = [("-", "-"), ("_", "_"), (".", "."), (" ", "Space")]

    /// `preview` renders a pattern as the file name it gives; `done` gets the pattern on OK.
    init(pattern: String, defaultPattern: String, tokens: [FileNamePattern.Token], preview: @escaping (String) -> String,
         done: @escaping (String) -> Void) {
        self.defaultPattern = defaultPattern
        self.preview = preview
        self.done = done
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()

        let title = NSTextField(labelWithString: "File Name")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        field.delegate = self
        // Nothing typed splits text: it's read back into placeholders and text when editing ends.
        field.tokenizingCharacterSet = CharacterSet(charactersIn: "\n")
        field.placeholderString = defaultPattern
        (field.cell as? NSTokenFieldCell)?.wraps = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        field.objectValue = Self.objects(pattern)

        let width: CGFloat = 464
        let buttons = tokens.map { button($0.title, #selector(addToken(_:)), $0.placeholder) }
            + Self.separators.map { button($0.1, #selector(addText(_:)), $0.0) }
        let add = Self.flow(buttons, width: width)

        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.isSelectable = true
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewRow = NSStackView(views: [NSTextField(labelWithString: "Gives:"), previewLabel])
        previewRow.alignment = .firstBaseline

        let reset = NSButton(title: "Use Default", target: self, action: #selector(useDefault(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(confirm(_:)))
        ok.keyEquivalent = "\r"
        let bottom = NSStackView(views: [reset, NSView(), cancel, ok])

        let main = NSStackView(views: [title, Self.caption("Pattern"), field, Self.caption("Add"), add, previewRow, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 8
        main.setCustomSpacing(14, after: field)
        main.setCustomSpacing(14, after: add)
        main.setCustomSpacing(16, after: previewRow)
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for v in [field, add, previewRow, bottom] { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        sheet.contentView = main
        sheet.initialFirstResponder = field
        updatePreview()
    }

    private func button(_ title: String, _ action: Selector, _ value: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.controlSize = .small
        b.identifier = NSUserInterfaceItemIdentifier(value)
        return b
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The buttons in rows as wide as `width`.
    private static func flow(_ views: [NSView], width: CGFloat) -> NSStackView {
        var rows: [[NSView]] = [[]]
        var used: CGFloat = 0
        for v in views {
            let w = v.fittingSize.width
            if used > 0, used + 6 + w > width {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append(v)
            used += (used > 0 ? 6 : 0) + w
        }
        let stack = NSStackView(views: rows.map { row in
            let s = NSStackView(views: row)
            s.spacing = 6
            return s
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    // MARK: - Pattern and tokens

    /// The pattern as the field's objects: placeholders as tokens, text as strings.
    static func objects(_ pattern: String) -> [Any] {
        FileNamePattern(pattern).segments.map {
            switch $0 {
            case .token(let t): PatternToken(t)
            case .text(let s): s
            }
        }
    }

    static func pattern(_ objects: [Any]) -> String {
        objects.map { ($0 as? PatternToken)?.token.placeholder ?? "\($0)" }.joined()
    }

    /// The pattern being edited.
    var pattern: String { Self.pattern((field.objectValue as? [Any]) ?? []) }

    /// Shows the pattern again as placeholders and text (typed `{yyyy}` becomes a token).
    private func normalize() {
        field.objectValue = Self.objects(pattern)
        updatePreview()
    }

    private func updatePreview() {
        let p = pattern
        previewLabel.stringValue = preview(p.isEmpty ? defaultPattern : p)
    }

    @objc private func addToken(_ sender: NSButton) { append(sender.identifier?.rawValue ?? "") }

    @objc private func addText(_ sender: NSButton) { append(sender.identifier?.rawValue ?? "") }

    /// Adds a placeholder or text at the end. For the dev harness too.
    func append(_ text: String) {
        if field.currentEditor() != nil { sheet.makeFirstResponder(nil) }
        field.objectValue = Self.objects(pattern + text)
        updatePreview()
    }

    @objc private func useDefault(_ sender: Any?) {
        if field.currentEditor() != nil { sheet.makeFirstResponder(nil) }
        field.objectValue = Self.objects(defaultPattern)
        updatePreview()
    }

    @objc private func cancel(_ sender: Any?) { sheet.sheetParent?.endSheet(sheet) }

    @objc private func confirm(_ sender: Any?) {
        sheet.makeFirstResponder(nil)
        let p = pattern
        done(p.trimmingCharacters(in: .whitespaces).isEmpty ? defaultPattern : p)
        sheet.sheetParent?.endSheet(sheet)
    }

    // MARK: - Token field

    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    func controlTextDidEndEditing(_ obj: Notification) { normalize() }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        if let t = representedObject as? PatternToken { return t.token.title }
        // Spaces would be invisible between tokens.
        return "\(representedObject)".replacingOccurrences(of: " ", with: "␣")
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        (representedObject as? PatternToken)?.token.placeholder ?? "\(representedObject)"
    }

    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        let objects = Self.objects(editingString)
        return objects.count == 1 ? objects[0] : editingString
    }

    func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        representedObject is PatternToken ? .rounded : .none
    }

    func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
        pboard.clearContents()
        return pboard.setString(Self.pattern(objects), forType: .string)
    }

    func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
        pboard.string(forType: .string).map(Self.objects)
    }
}

/// A file name row: the name the pattern gives now and Customize…, which opens the editor.
@MainActor
final class FileNamePatternRow: NSStackView {
    private(set) var pattern: String
    let defaultPattern: String
    let tokens: [FileNamePattern.Token]
    let nameLabel = NSTextField(labelWithString: "")
    /// The name a pattern gives (with its extension).
    var preview: (String) -> String = { $0 }
    var onChange: (() -> Void)?
    /// The editor while it's open, for the dev harness.
    private(set) var editor: FileNamePatternSheet?

    init(pattern: String, defaultPattern: String, tokens: [FileNamePattern.Token]) {
        self.pattern = pattern.isEmpty ? defaultPattern : pattern
        self.defaultPattern = defaultPattern
        self.tokens = tokens
        super.init(frame: .zero)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.isSelectable = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let customize = NSButton(title: "Customize…", target: self, action: #selector(customize(_:)))
        setViews([nameLabel, customize], in: .leading)
        alignment = .firstBaseline
        spacing = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the name the pattern gives now (after an option that changes it).
    func refresh() {
        nameLabel.stringValue = preview(pattern)
        nameLabel.toolTip = pattern
    }

    func set(pattern new: String, notify: Bool = true) {
        pattern = new.isEmpty ? defaultPattern : new
        refresh()
        if notify { onChange?() }
    }

    @objc private func customize(_ sender: Any?) { openEditor() }

    /// Opens the editor. For the dev harness too.
    func openEditor() {
        guard let window else { return }
        let editor = FileNamePatternSheet(pattern: pattern, defaultPattern: defaultPattern, tokens: tokens, preview: preview) { [weak self] in
            self?.set(pattern: $0)
        }
        self.editor = editor
        window.beginSheet(editor.sheet) { [weak self] _ in self?.editor = nil }
    }
}
