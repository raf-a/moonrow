import AppCore
import AppKit
import DBKit

/// What the right sidebar shows and edits: the data grid's selected rows, or the structure
/// grid's selected columns or indexes.
@MainActor
protocol InspectorSource: AnyObject {
    /// "people · 2 rows"
    var inspectorTitle: String { get }
    var inspectorFields: [InspectorField] { get }
    /// A field was edited: the text typed, or "yes" / "no" from a pop-up. One undo step.
    func inspectorEdit(_ key: InspectorField.Key, text: String)
    /// NULL, Empty String or DEFAULT from a data field's menu. One undo step.
    func inspectorSet(_ key: InspectorField.Key, _ change: CellChange)
}

extension Notification.Name {
    /// Posted by an `InspectorSource` (object: itself) when its selection or values change.
    static let inspectorSourceDidChange = Notification.Name("InspectorSource.didChange")
}

/// The right sidebar: one field per column of the selected rows, or per attribute of the
/// selected columns or indexes. Fields shared by every selected item show the value; others say
/// "Multiple values". Editing a field stages it for the whole selection.
@MainActor
final class InspectorViewController: NSViewController, NSTextFieldDelegate {
    weak var source: InspectorSource? {
        didSet { if source !== oldValue { refresh() } }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "No selection")
    /// The fields on screen, by the tag of their control.
    private var fields: [InspectorField] = []
    /// What each text field showed when it was filled, to tell whether it was edited.
    private var startText: [Int: String] = [:]
    private var refreshQueued = false

    /// Longest text a field holds; longer values are shown cut and read-only.
    private static let maxText = 20_000

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        let document = FlippedView()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        for v in [titleLabel, scroll, placeholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(sourceChanged(_:)), name: .inspectorSourceDidChange, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    @objc private func sourceChanged(_ notification: Notification) {
        if notification.object as AnyObject? === source { refresh() }
    }

    /// Rebuilds the form on the next pass of the run loop (several changes arrive together, and
    /// a field that's ending its edit shouldn't be torn down under itself).
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.rebuild()
        }
    }

    /// True while one of the fields is being edited.
    private var isEditingField: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: stack)
    }

    private func rebuild() {
        // Hidden (collapsed) or mid-edit: nothing to do now; showing it or ending the edit refreshes.
        guard isViewLoaded, view.window != nil, view.frame.width > 1, !isEditingField else { return }
        let fields = source?.inspectorFields ?? []
        titleLabel.stringValue = source?.inspectorTitle ?? ""
        placeholder.isHidden = !fields.isEmpty
        placeholder.stringValue = source == nil ? "Select rows in a table" : "No selection"
        guard fields != self.fields || stack.arrangedSubviews.isEmpty != fields.isEmpty else { return }
        self.fields = fields
        startText = [:]
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        for (i, field) in fields.enumerated() {
            let row = makeRow(field, tag: i)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
    }

    // MARK: - Fields

    private func makeRow(_ field: InspectorField, tag: Int) -> NSView {
        let label = NSTextField(labelWithString: field.label)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: field.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var header: [NSView] = [label, detail, NSView()]
        if case .cell = field.key, field.isEditable { header.append(setValueButton(tag: tag)) }
        let top = NSStackView(views: header)
        top.spacing = 6

        let control: NSView = switch field.kind {
        case .text: textField(field, tag: tag)
        case .flag: flagPopup(field, tag: tag)
        case .blob: blobLabel(field)
        }
        let row = NSStackView(views: [top, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        for v in row.arrangedSubviews { v.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        return row
    }

    private func textField(_ field: InspectorField, tag: Int) -> NSTextField {
        let f = GrowingTextField()
        f.tag = tag
        f.font = AppStyle.gridFont
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byCharWrapping
        f.maximumNumberOfLines = 12
        f.delegate = self
        var text = ""
        switch field.value {
        case nil: f.placeholderString = "Multiple values"
        case .pending?: f.placeholderString = "Loading…"
        case .defaultValue?: f.placeholderString = "DEFAULT"
        case .value(let v)?:
            if v.isNull { f.placeholderString = "NULL" } else { text = CellInput.editingText(v) }
        }
        let cut = text.count > Self.maxText
        if cut { text = String(text.prefix(Self.maxText)) + "…" }
        f.stringValue = text
        startText[tag] = text
        f.isEditable = field.isEditable && !cut
        f.isSelectable = true
        f.textColor = f.isEditable ? .labelColor : .secondaryLabelColor
        if field.isStaged {
            f.drawsBackground = true
            f.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.28)
        }
        f.toolTip = cut ? "Too long to edit here; use the grid's editor." : nil
        return f
    }

    private func flagPopup(_ field: InspectorField, tag: Int) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItems(withTitles: ["YES", "NO"])
        if case .value(.bool(let b))? = field.value {
            popup.selectItem(at: b ? 0 : 1)
        } else {
            popup.insertItem(withTitle: "Multiple values", at: 0)
            popup.selectItem(at: 0)
        }
        popup.tag = tag
        popup.target = self
        popup.action = #selector(flagChosen(_:))
        popup.isEnabled = field.isEditable
        if field.isStaged { popup.contentTintColor = .systemOrange }
        return popup
    }

    private func blobLabel(_ field: InspectorField) -> NSTextField {
        let text: String = switch field.value {
        case .value(.blob(let data))?: "Binary data, \(data.count.formatted()) bytes"
        case .value(.null)?: "NULL"
        default: "Multiple values"
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        return label
    }

    private func setValueButton(tag: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Set value")!,
                              target: self, action: #selector(showSetValueMenu(_:)))
        button.isBordered = false
        button.tag = tag
        button.toolTip = "Set NULL, an empty string or DEFAULT"
        return button
    }

    @objc private func showSetValueMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, i) in [("NULL", 0), ("Empty String", 1), ("DEFAULT", 2)] {
            let item = menu.addItem(withTitle: title, action: #selector(setValueChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = sender.tag * 4 + i
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func setValueChosen(_ sender: NSMenuItem) {
        guard let field = fields[safe: sender.tag / 4] else { return }
        let change: CellChange = switch sender.tag % 4 {
        case 0: .value(.null)
        case 1: .value(.text(""))
        default: .defaultValue
        }
        source?.inspectorSet(field.key, change)
    }

    @objc private func flagChosen(_ sender: NSPopUpButton) {
        guard let field = fields[safe: sender.tag], let title = sender.titleOfSelectedItem, title != "Multiple values" else { return }
        source?.inspectorEdit(field.key, text: title == "YES" ? "yes" : "no")
    }

    func controlTextDidChange(_ notification: Notification) {
        (notification.object as? NSTextField)?.invalidateIntrinsicContentSize()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let f = notification.object as? NSTextField, let field = fields[safe: f.tag],
              f.stringValue != startText[f.tag] else { return }
        startText[f.tag] = f.stringValue
        source?.inspectorEdit(field.key, text: f.stringValue)
        refresh()
    }

    /// Return ends the edit; ⌥Return and ⌃Return insert a line break; Esc puts the value back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let f = control as? NSTextField { f.stringValue = startText[f.tag] ?? "" }
            view.window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }
}

/// A wrapping text field whose height follows its text, up to `maximumNumberOfLines`.
private final class GrowingTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard let cell, frame.width > 0 else { return super.intrinsicContentSize }
        var bounds = self.bounds
        bounds.size.height = .greatestFiniteMagnitude
        let lineHeight = ceil((font ?? .systemFont(ofSize: 12)).boundingRectForFont.height)
        let height = min(cell.cellSize(forBounds: bounds).height, lineHeight * CGFloat(max(1, maximumNumberOfLines)) + 6)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(22, height))
    }

    private var laidOutWidth: CGFloat = 0

    /// The height depends on the width, so it's measured again when the width changes.
    override func layout() {
        super.layout()
        if frame.width != laidOutWidth {
            laidOutWidth = frame.width
            invalidateIntrinsicContentSize()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
