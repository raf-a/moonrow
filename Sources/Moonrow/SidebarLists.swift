import AppKit

// What the sidebar's lists (items, saved queries, search results) have in common: rows drawn
// alike, a grey selection, and selection from code that opens nothing.

/// A list row whose selection is grey whether or not the list has the focus, so coloured names
/// stay as they are on a selected row.
final class GreySelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Selection made from code, which a list's selection handler ignores: a list that opens what's
/// selected follows the selected tab without opening anything.
@MainActor
final class QuietSelection {
    /// True while selecting from code.
    private(set) var isActive = false

    /// Selects these rows of `list` (scrolling to the first unless `scroll` is false), or nothing.
    func select(_ rows: IndexSet, in list: NSTableView, scroll: Bool = true) {
        isActive = true
        defer { isActive = false }
        list.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { list.scrollRowToVisible(first) }
    }

    /// Selects a row of `list`, or nothing for nil.
    func select(_ row: Int?, in list: NSTableView) {
        select(row.map { IndexSet(integer: $0) } ?? [], in: list)
    }
}

/// A row of a sidebar list: an icon, the name, then a detail (a count) and the staged-change
/// letter at the end. The name isn't the cell's `textField`: a source list sets the font of that
/// field, which drops the name's colour and strikethrough and makes the selected row semibold.
/// So the list needs its own type-select string.
final class SidebarCell: NSTableCellView {
    /// The name; renaming in the row edits it.
    let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let detail = NSTextField(labelWithString: "")
    /// A, M or D, when the Mac differentiates without colour.
    private let letter = StagedState.makeLetterLabel()
    private var state: StagedState?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // One line, cut in the middle so names sharing a prefix still differ at the end.
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Hidden views take no room.
        let end = NSStackView(views: [detail, letter])
        end.spacing = 6
        for v in [icon, label, end] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: end.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            end.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            end.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a row. A staged `state` colours the name (struck out when dropped) and, when the
    /// Mac differentiates without colour, adds its letter.
    func show(_ name: String, symbol: String, tint: NSColor, accessibilityDescription: String? = nil,
              font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), state: StagedState? = nil, detail text: String? = nil) {
        // The string's paragraph style wins over the field's line break mode, and without one
        // the name wraps.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if let state { attributes[.foregroundColor] = state.color }
        if state == .dropped { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        // The field's own colour too: with the label colour it draws vibrant in the sidebar,
        // which washes out the string's colour.
        label.textColor = state?.color ?? .labelColor
        label.font = font
        label.attributedStringValue = NSAttributedString(string: name, attributes: attributes)
        self.state = state
        StagedState.show(state, in: letter, size: font.pointSize)
        detail.stringValue = text ?? ""
        detail.isHidden = text == nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        icon.contentTintColor = tint
    }

    /// The name, then the staged change and the detail.
    override func accessibilityLabel() -> String? {
        [label.stringValue, state?.spoken, detail.isHidden ? nil : detail.stringValue].compactMap { $0 }.joined(separator: ", ")
    }
}
