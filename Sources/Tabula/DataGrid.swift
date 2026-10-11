import AppCore
import AppKit
import DBKit

/// The table view behind the data grid. Rows are selected as usual; one column is the cell
/// cursor ("focused column"), so keyboard edits know which cell of the selected rows to touch.
@MainActor
final class DataGrid: NSTableView {
    /// Identifier of the column holding the cell cursor.
    var focusedColumn: NSUserInterfaceItemIdentifier? {
        didSet { if focusedColumn != oldValue { onFocusChange?(oldValue) } }
    }
    var onFocusChange: ((_ previous: NSUserInterfaceItemIdentifier?) -> Void)?
    /// Return or Enter on a selected row.
    var onEdit: (() -> Void)?
    /// ⌥Return: the menu to pop up at the cursor.
    var setValueMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Row height and row backgrounds follow the preferences. Applied once the grid is in a
    // window, after its controller has configured it, and again whenever they change.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyStyle() }
    }

    @objc private func styleChanged() {
        applyStyle()
        reloadData()
    }

    private func applyStyle() {
        rowHeight = GridCell.rowHeight
        usesAlternatingRowBackgroundColors = AppStyle.settings.alternatingRows
    }

    var focusedColumnIndex: Int? {
        guard let id = focusedColumn else { return nil }
        let i = column(withIdentifier: id)
        return i >= 0 ? i : nil
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (36, []), (76, []):  // Return, Enter
            onEdit?()
        case (36, .option):
            popUpSetValueMenu()
        case (123, []):  // ←
            moveFocus(by: -1)
        case (124, []):  // →
            moveFocus(by: 1)
        case (51, []), (117, []):  // Delete, Forward Delete
            NSApp.sendAction(#selector(TabulaActions.deleteRows(_:)), to: nil, from: self)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let c = column(at: convert(event.locationInWindow, from: nil))
        if c >= 0 { focusedColumn = tableColumns[c].identifier }
        super.mouseDown(with: event)
    }

    /// Right-click moves the cursor too, and selects the clicked row unless it's part of the
    /// selection already.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point), c = column(at: point)
        if c >= 0 { focusedColumn = tableColumns[c].identifier }
        if r >= 0, !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return super.menu(for: event)
    }

    func moveFocus(by delta: Int) {
        guard numberOfColumns > 0 else { return }
        let current = focusedColumnIndex ?? (delta > 0 ? -1 : numberOfColumns)
        let next = min(max(current + delta, 0), numberOfColumns - 1)
        focusedColumn = tableColumns[next].identifier
        scrollColumnToVisible(next)
    }

    private func popUpSetValueMenu() {
        guard let menu = setValueMenu?(), let c = focusedColumnIndex, selectedRow >= 0 else { return NSSound.beep() }
        let cell = frameOfCell(atColumn: c, row: selectedRow)
        menu.popUp(positioning: nil, at: NSPoint(x: cell.minX, y: cell.maxY), in: self)
    }
}

/// Tints a whole row: inserted rows green, rows marked for deletion red.
final class GridRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("GridRow")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var state: StagedEdits.RowState = .unchanged {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let tint: NSColor? = switch state {
        case .inserted: .systemGreen.withAlphaComponent(0.16)
        case .deleted: .systemRed.withAlphaComponent(0.18)
        case .edited, .unchanged: nil
        }
        if let tint {
            tint.setFill()
            bounds.fill()
        }
    }
}

/// What a grid cell shows.
enum CellContent {
    case value(DBValue)
    /// An inserted row's cell that will take the column default.
    case defaultValue
    /// The row hasn't loaded yet.
    case pending
}

/// One grid cell. Frame-based layout: cells are created and reused constantly while scrolling.
final class GridCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    /// The grid font from the preferences.
    static var font: NSFont { AppStyle.gridFont }
    private static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    private static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    /// 22 pt at the default 12 pt font, taller for bigger fonts.
    static var rowHeight: CGFloat { max(22, lineHeight + 7) }
    private static let padding: CGFloat = 5
    private static let editedColor = NSColor.systemYellow.withAlphaComponent(0.28)

    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.focusRingType = .none
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: Self.padding, y: floor((bounds.height - Self.lineHeight) / 2),
            width: max(0, bounds.width - 2 * Self.padding), height: Self.lineHeight)
    }

    func show(_ content: CellContent, edited: Bool = false, focused: Bool = false, struckOut: Bool = false) {
        if label.font !== Self.font {
            label.font = Self.font
            needsLayout = true
        }
        label.isEditable = false
        label.isSelectable = false
        var text: String
        var color = NSColor.labelColor
        switch content {
        case .value(let value):
            if let display = CellText.display(value) {
                text = display
            } else {
                text = "NULL"
                color = .tertiaryLabelColor
            }
        case .defaultValue:
            text = "DEFAULT"
            color = .tertiaryLabelColor
        case .pending:
            text = ""
        }
        if struckOut { color = .secondaryLabelColor }
        if struckOut, !text.isEmpty {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: Self.font, .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ])
        } else {
            label.stringValue = text
            label.textColor = color
        }
        // Most cells are plain; leave their layer alone so scrolling stays cheap.
        if edited != isEdited {
            isEdited = edited
            layer?.backgroundColor = edited ? Self.editedColor.cgColor : nil
        }
        if focused != isFocused {
            isFocused = focused
            layer?.borderWidth = focused ? 1.5 : 0
            layer?.borderColor = focused ? NSColor.keyboardFocusIndicatorColor.cgColor : nil
        }
    }

    private var isEdited = false
    private var isFocused = false

    /// Turns the label into an editor holding the full value.
    func prepareForEditing(_ text: String, delegate: any NSTextFieldDelegate) {
        label.textColor = .labelColor
        label.stringValue = text
        label.isEditable = true
        label.isSelectable = true
        label.delegate = delegate
        isFocused = false
        layer?.borderWidth = 0
    }

    /// Width a column needs to show `text` without truncating.
    static func width(of text: String, header: Bool) -> CGFloat {
        let font = header ? headerFont : font
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * padding + (header ? 14 : 4)
    }
}
