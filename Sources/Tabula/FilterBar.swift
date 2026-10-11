import AppKit
import DBKit

/// Filter rows above the grid. Each row is one condition; Return in a row applies that row on
/// its own, Apply All combines the checked rows with AND or OR.
@MainActor
final class FilterBar: NSView {
    /// Called with the filter to apply. Nil means no filter.
    var onApply: ((Filter?) -> Void)?
    /// Escape pressed in a row.
    var onExit: (() -> Void)?

    private(set) var columns: [String] = []
    private var rows: [FilterRow] = []
    private let rowStack = NSStackView()
    private let matchPopup = NSPopUpButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2

        matchPopup.addItems(withTitles: ["Match all (AND)", "Match any (OR)"])
        matchPopup.controlSize = .small
        matchPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let applyAll = NSButton(title: "Apply All", target: self, action: #selector(applyAllClicked(_:)))
        applyAll.controlSize = .small
        applyAll.keyEquivalent = "\r"
        applyAll.keyEquivalentModifierMask = .command
        applyAll.toolTip = "Apply every checked filter (⌘↩; ⇧⌘↩ to match any)"
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearClicked(_:)))
        clear.controlSize = .small
        // Hidden button so ⇧⌘↩ applies with OR.
        let applyAny = NSButton(title: "", target: self, action: #selector(applyAnyClicked(_:)))
        applyAny.keyEquivalent = "\r"
        applyAny.keyEquivalentModifierMask = [.command, .shift]
        applyAny.isTransparent = true
        applyAny.setFrameSize(.zero)
        let footer = NSStackView(views: [NSView(), matchPopup, clear, applyAll, applyAny])
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        let outer = NSStackView(views: [rowStack, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            footer.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
        addRow(after: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// New column list (another table); rows pointing at missing columns fall back to any column.
    func setColumns(_ columns: [String]) {
        self.columns = columns
        for row in rows { row.setColumns(columns) }
    }

    func focus() {
        rows.first?.focusValue()
    }

    /// Puts `condition` in the first row and applies it on its own (a quick filter).
    func apply(_ condition: FilterCondition) {
        guard let row = rows.first else { return }
        row.set(condition)
        row.onApply?()
    }

    /// Unchecked rows and rows without a usable condition are skipped.
    var checkedConditions: [FilterCondition] {
        rows.filter(\.isChecked).compactMap(\.condition)
    }

    // MARK: - Rows

    private func addRow(after row: FilterRow?) {
        let new = FilterRow(columns: columns)
        new.onApply = { [weak self, weak new] in
            guard let self, let new else { return }
            new.isChecked = true
            self.onApply?(new.condition.map { Filter([$0]) })
        }
        new.onAdd = { [weak self, weak new] in self?.addRow(after: new) }
        new.onRemove = { [weak self, weak new] in if let new { self?.remove(new) } }
        new.onExit = { [weak self] in self?.onExit?() }
        let index = row.flatMap { rows.firstIndex(of: $0) }.map { $0 + 1 } ?? rows.count
        rows.insert(new, at: index)
        rowStack.insertArrangedSubview(new, at: index)
        new.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        if row != nil { new.focusValue() }
    }

    private func remove(_ row: FilterRow) {
        guard rows.count > 1 else {
            row.reset()
            onApply?(nil)
            return
        }
        rows.removeAll { $0 === row }
        row.removeFromSuperview()
        apply(matchAll: matchPopup.indexOfSelectedItem == 0)
    }

    private func apply(matchAll: Bool) {
        let conditions = checkedConditions
        onApply?(conditions.isEmpty ? nil : Filter(conditions, matchAll: matchAll))
    }

    @objc private func applyAllClicked(_ sender: Any?) { apply(matchAll: matchPopup.indexOfSelectedItem == 0) }

    @objc private func applyAnyClicked(_ sender: Any?) {
        matchPopup.selectItem(at: 1)
        apply(matchAll: false)
    }

    @objc private func clearClicked(_ sender: Any?) {
        for row in rows.dropFirst() { row.removeFromSuperview() }
        rows = Array(rows.prefix(1))
        rows.first?.reset()
        onApply?(nil)
    }
}

/// One condition: checkbox, column, operator, value(s), and Apply / − / + buttons.
@MainActor
private final class FilterRow: NSStackView, NSTextFieldDelegate {
    var onApply: (() -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: (() -> Void)?
    var onExit: (() -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let columnPopup = NSPopUpButton()
    private let operatorPopup = NSPopUpButton()
    private let valueField = NSTextField()
    private let andLabel = NSTextField(labelWithString: "and")
    private let secondField = NSTextField()
    private var columns: [String] = []

    private static let anyColumnTag = -1
    private static let rawSQLTag = -2
    private static let operators = FilterOperator.allCases.filter { $0 != .raw }

    init(columns: [String]) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        checkbox.state = .on
        for popup in [columnPopup, operatorPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.target = self
            popup.action = #selector(popupChanged(_:))
        }
        operatorPopup.addItems(withTitles: Self.operators.map(\.rawValue))
        operatorPopup.selectItem(withTitle: FilterOperator.contains.rawValue)
        for field in [valueField, secondField] {
            field.controlSize = .small
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }
        andLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        andLabel.textColor = .secondaryLabelColor
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let apply = Self.button(title: "Apply", #selector(applyClicked(_:)), target: self)
        let remove = Self.button(symbol: "minus", #selector(removeClicked(_:)), target: self)
        let add = Self.button(symbol: "plus", #selector(addClicked(_:)), target: self)
        for v in [checkbox, columnPopup, operatorPopup, valueField, andLabel, secondField, apply, remove, add] {
            addArrangedSubview(v)
        }
        setColumns(columns)
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isChecked: Bool {
        get { checkbox.state == .on }
        set { checkbox.state = newValue ? .on : .off }
    }

    var condition: FilterCondition? {
        let tag = columnPopup.selectedTag()
        if tag == Self.rawSQLTag {
            let sql = valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return sql.isEmpty ? nil : FilterCondition(.anyColumn, .raw, sql)
        }
        let target: FilterTarget = tag >= 0 && tag < columns.count ? .column(columns[tag]) : .anyColumn
        let op = Self.operators[max(0, operatorPopup.indexOfSelectedItem)]
        return FilterCondition(target, op, valueField.stringValue, secondField.stringValue)
    }

    func setColumns(_ columns: [String]) {
        let selected = columnPopup.selectedTag() >= 0 ? columnPopup.titleOfSelectedItem : nil
        let tag = columnPopup.selectedTag()
        self.columns = columns
        let menu = NSMenu()
        menu.addItem(Self.item("Any column", tag: Self.anyColumnTag))
        menu.addItem(.separator())
        for (i, name) in columns.enumerated() { menu.addItem(Self.item(name, tag: i)) }
        menu.addItem(.separator())
        menu.addItem(Self.item("Raw SQL", tag: Self.rawSQLTag))
        columnPopup.menu = menu
        if let selected, let i = columns.firstIndex(of: selected) {
            columnPopup.selectItem(withTag: i)
        } else {
            columnPopup.selectItem(withTag: tag == Self.rawSQLTag ? Self.rawSQLTag : Self.anyColumnTag)
        }
        updateVisibility()
    }

    func set(_ c: FilterCondition) {
        switch (c.op, c.target) {
        case (.raw, _): columnPopup.selectItem(withTag: Self.rawSQLTag)
        case (_, .column(let name)): columnPopup.selectItem(withTag: columns.firstIndex(of: name) ?? Self.anyColumnTag)
        case (_, .anyColumn): columnPopup.selectItem(withTag: Self.anyColumnTag)
        }
        if c.op != .raw { operatorPopup.selectItem(withTitle: c.op.rawValue) }
        valueField.stringValue = c.value
        secondField.stringValue = c.secondValue
        isChecked = true
        updateVisibility()
    }

    func focusValue() {
        window?.makeFirstResponder(valueField)
    }

    func reset() {
        columnPopup.selectItem(withTag: Self.anyColumnTag)
        operatorPopup.selectItem(withTitle: FilterOperator.contains.rawValue)
        valueField.stringValue = ""
        secondField.stringValue = ""
        isChecked = true
        updateVisibility()
    }

    private func updateVisibility() {
        let raw = columnPopup.selectedTag() == Self.rawSQLTag
        let op = Self.operators[max(0, operatorPopup.indexOfSelectedItem)]
        operatorPopup.isHidden = raw
        valueField.isHidden = !raw && !op.takesValue
        andLabel.isHidden = raw || !op.takesSecondValue
        secondField.isHidden = andLabel.isHidden
        valueField.placeholderString = raw ? "SQL condition" : op == .in || op == .notIn ? "Values, comma-separated" : "Value"
    }

    @objc private func popupChanged(_ sender: Any?) {
        updateVisibility()
        // Operators without a value take effect right away.
        if let op = condition?.op, !op.takesValue { onApply?() }
    }

    @objc private func applyClicked(_ sender: Any?) { onApply?() }
    @objc private func addClicked(_ sender: Any?) { onAdd?() }
    @objc private func removeClicked(_ sender: Any?) { onRemove?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onApply?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onExit?()
            return true
        default:
            return false
        }
    }

    private static func item(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        return item
    }

    private static func button(title: String = "", symbol: String? = nil, _ action: Selector, target: AnyObject) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) }
        b.controlSize = .small
        b.bezelStyle = .rounded
        return b
    }
}
