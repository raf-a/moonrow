import AppKit
import SQLScript

/// The autocomplete list: a small borderless panel under the word being typed. It never takes
/// focus; the text view forwards ↑ ↓ Return Tab Esc to it.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((SQLCompletion.Item) -> Void)?
    private(set) var items: [SQLCompletion.Item] = []
    private let panel: NSPanel
    private let table = NSTableView()
    private static let rowHeight: CGFloat = 20
    private static let maxRows = 10

    var isVisible: Bool { panel.isVisible }
    var selectedItem: SQLCompletion.Item? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let content = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 10
            glass.contentView = content
            content.pin(to: glass)
            panel.contentView = glass
        } else {
            let effect = Background()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 6
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.addSubview(content)
            content.pin(to: effect)
            panel.contentView = effect
        }
    }

    /// The popover material with a hairline border in the separator colour of the appearance.
    private final class Background: NSVisualEffectView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            // A CGColor is resolved once, so it's set again for each appearance.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
        }
    }

    /// Shows `items` below `anchor` (screen coordinates), keeping the selection on the same
    /// name when it's still listed.
    func show(_ items: [SQLCompletion.Item], below anchor: NSRect, in parent: NSWindow) {
        let previous = selectedItem
        self.items = items
        table.reloadData()
        let row = previous.flatMap { p in items.firstIndex { $0.text == p.text && $0.kind == p.kind } } ?? 0
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)

        let widest = items.prefix(200).map { CompletionCell.width(for: $0) }.max() ?? 200
        let width = min(460, max(220, widest + 16))
        let height = CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 6
        var frame = NSRect(x: anchor.minX - 22, y: anchor.minY - height - 2, width: width, height: height)
        // Flip above the line when there's no room below.
        if let screen = parent.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 2 }
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        table.reloadData()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @discardableResult
    func acceptSelected() -> Bool {
        guard let item = selectedItem else { return false }
        hide()
        onAccept?(item)
        return true
    }

    @objc private func doubleClicked() { acceptSelected() }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.show(items[row])
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("Completion")
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let detailFont = NSFont.systemFont(ofSize: 11)
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Self.font
        name.lineBreakMode = .byTruncatingTail
        detail.font = Self.detailFont
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        for v in [icon, name, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: SQLCompletion.Item) {
        name.stringValue = item.text
        let (symbol, color, kind) = Self.style(item.kind)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind)
        icon.contentTintColor = color
        detail.stringValue = item.detail ?? kind
    }

    static func width(for item: SQLCompletion.Item) -> CGFloat {
        let n = (item.text as NSString).size(withAttributes: [.font: font]).width
        let d = ((item.detail ?? style(item.kind).2) as NSString).size(withAttributes: [.font: detailFont]).width
        return 6 + 14 + 6 + n + 10 + d + 8
    }

    private static func style(_ kind: SQLCompletion.Kind) -> (String, NSColor, String) {
        switch kind {
        case .column: ("c.square", .systemOrange, "column")
        case .alias: ("a.square", .systemTeal, "alias")
        case .commonTable: ("tablecells.badge.ellipsis", .systemTeal, "CTE")
        case .table: ("tablecells", .systemBlue, "table")
        case .view: ("eye", .systemPurple, "view")
        case .function: ("function", .systemGreen, "function")
        case .keyword: ("textformat", .secondaryLabelColor, "keyword")
        }
    }
}
