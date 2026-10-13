import AppKit

/// A row of tabs: click to select, × (or a middle click) to close, optional + at the end.
/// Used for workspace tabs and for query result tabs.
@MainActor
final class TabStrip: NSView {
    struct Item: Equatable {
        var title: String
        var symbol: String?
        var closable = true
        var toolTip: String?
        /// Drawn in the accent colour, e.g. a tab whose query failed.
        var tint: NSColor?
        /// A preview tab: the title is in italics.
        var italic = false
    }

    var items: [Item] = [] {
        didSet { if items != oldValue { rebuild() } }
    }
    var selectedIndex: Int? {
        didSet { if selectedIndex != oldValue { updateSelection() } }
    }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// A double-click on a tab (keeps a preview tab).
    var onDoubleClick: ((Int) -> Void)?
    /// False for the tabs of a pane that isn't the active one: the selected tab's line is grey.
    var isActive = true {
        didSet { if isActive != oldValue { for v in tabViews { v.isActive = isActive } } }
    }
    /// Shows a + button when set.
    var onAdd: (() -> Void)? {
        didSet { addButton.isHidden = onAdd == nil }
    }
    var addToolTip: String? {
        get { addButton.toolTip }
        set { addButton.toolTip = newValue }
    }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addButton = NSButton()
    private var tabViews: [TabView] = []
    static let height: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.isHidden = true
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, addButton, line] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            addButton.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 4),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        // The strip is as wide as its tabs, up to the space available.
        let fit = scroll.widthAnchor.constraint(equalTo: document.widthAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        scroll.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        // Reuse views so hover and click state survive title changes.
        while tabViews.count > items.count { tabViews.removeLast().removeFromSuperview() }
        while tabViews.count < items.count {
            let v = TabView()
            v.onClick = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return }
                self.onSelect?(i)
            }
            v.onClose = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return }
                self.onClose?(i)
            }
            v.onDoubleClick = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return }
                self.onDoubleClick?(i)
            }
            v.isActive = isActive
            tabViews.append(v)
            stack.addArrangedSubview(v)
        }
        for (v, item) in zip(tabViews, items) { v.item = item }
        updateSelection()
    }

    private func updateSelection() {
        for (i, v) in tabViews.enumerated() { v.isSelected = i == selectedIndex }
        if let i = selectedIndex, i < tabViews.count {
            layoutSubtreeIfNeeded()
            tabViews[i].scrollToVisible(tabViews[i].bounds)
        }
    }

    @objc private func addClicked() { onAdd?() }

    /// The tab's view, for anchoring popovers and tests.
    func tabView(at index: Int) -> NSView? { index < tabViews.count ? tabViews[index] : nil }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TabView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var item = TabStrip.Item(title: "") { didSet { update() } }
    var isSelected = false { didSet { if isSelected != oldValue { update() } } }
    var isActive = true { didSet { if isActive != oldValue { update() } } }
    private var isHovered = false { didSet { if isHovered != oldValue { update() } } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.isBordered = false
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close tab"
        let row = NSStackView(views: [close, icon, label])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: TabStrip.height - 1),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            close.widthAnchor.constraint(equalToConstant: 14),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        label.stringValue = item.title
        let size: CGFloat = 12
        label.font = item.italic
            ? NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
            : .systemFont(ofSize: size)
        toolTip = item.toolTip ?? item.title
        icon.image = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        icon.contentTintColor = item.tint ?? (isSelected ? .controlAccentColor : .secondaryLabelColor)
        label.textColor = item.tint ?? (isSelected ? .labelColor : .secondaryLabelColor)
        // The × keeps its space so titles don't shift on hover.
        close.isHidden = !item.closable
        close.alphaValue = isSelected || isHovered ? 1 : 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Filled here rather than as a layer colour: a CGColor is resolved once, against whatever
        // appearance is current at the time, and doesn't follow the window into dark mode.
        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
        } else if isHovered {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            bounds.fill(using: .sourceOver)
        }
        // A hairline between tabs, and an accent line under the selected one.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 5, width: 1, height: bounds.height - 10).fill()
        if isSelected {
            (isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSRect(x: 0, y: 0, width: bounds.width - 1, height: 2).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, item.closable { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }
}
