import AppKit

/// A row of tabs: click to select, × (or a middle click) to close, optional + at the end.
/// Used for workspace tabs and for query result tabs. The row has a colour of its own; the
/// selected tab has the content's colour and no line under it, so it runs into what it shows.
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
        /// The colour of what the tab shows, which the selected tab is filled with so it runs into
        /// it. Nil: the grid's.
        var background: NSColor?
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
    /// False for the tabs of a pane that isn't the active one: the selected tab's icon is grey.
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
    /// The row's colour: lighter than the sidebar (about #F2F2F2 in light, lighter than the content
    /// in dark), and in light a step darker than the content.
    static let barColor = NSColor(name: nil) { appearance in
        Shade(appearance).dark
            ? NSColor(srgbRed: 0.184, green: 0.184, blue: 0.196, alpha: 1)
            : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1)
    }
    /// The hairlines under the row, around the selected tab and between the others: over the row
    /// they come out as the window's separator above it does (about #DEDEDE in light, #3E3E40 in
    /// dark), and stronger with Increase Contrast.
    static let lineColor = NSColor(name: nil) { appearance in
        let shade = Shade(appearance)
        return shade.dark
            ? NSColor.white.withAlphaComponent(shade.highContrast ? 0.35 : 0.07)
            : NSColor.black.withAlphaComponent(shade.highContrast ? 0.3 : 0.1)
    }

    /// One device pixel, like the window's own separators.
    static func hairline(in view: NSView) -> CGFloat { 1 / (view.window?.backingScaleFactor ?? 2) }

    private struct Shade {
        let dark, highContrast: Bool

        init(_ appearance: NSAppearance) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            highContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        }
    }

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

        // The line under the row has a gap at the selected tab, which follows the tabs as they scroll.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tabsMoved),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for v in [scroll, addButton] { addSubview(v) }
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
            v.onLayout = { [weak self] in self?.needsDisplay = true }
            tabViews.append(v)
            stack.addArrangedSubview(v)
        }
        for (v, item) in zip(tabViews, items) { v.item = item }
        updateSelection()
    }

    private func updateSelection() {
        for (i, v) in tabViews.enumerated() {
            v.isSelected = i == selectedIndex
            v.isFirst = i == 0
            // The selected tab has edges of its own; no divider beside it.
            v.showsDivider = i != selectedIndex && i + 1 != selectedIndex
        }
        if let i = selectedIndex, i < tabViews.count {
            layoutSubtreeIfNeeded()
            tabViews[i].scrollToVisible(tabViews[i].bounds)
        }
        needsDisplay = true
    }

    @objc private func tabsMoved() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn rather than set as layer colours, so they follow the appearance.
        Self.barColor.setFill()
        bounds.fill()
        let hairline = Self.hairline(in: self)
        let line = NSRect(x: 0, y: 0, width: bounds.width, height: hairline)
        Self.lineColor.setFill()
        guard let i = selectedIndex, i < tabViews.count else {
            line.fill(using: .sourceOver)
            return
        }
        // Under the selected tab, inside its edges, the line is the tab's colour, joining it to the
        // content.
        let tab = tabViews[i]
        var gap = convert(tab.bounds, from: tab)
        gap.origin.x += tab.leftEdge
        gap.size.width -= tab.leftEdge + hairline
        gap = gap.intersection(scroll.frame)
        guard !gap.isEmpty else {
            line.fill(using: .sourceOver)
            return
        }
        // The line either side of the tab, and the tab's edges carried down to it.
        NSRect(x: 0, y: 0, width: gap.minX, height: hairline).fill(using: .sourceOver)
        NSRect(x: gap.maxX, y: 0, width: bounds.width - gap.maxX, height: hairline).fill(using: .sourceOver)
        NSRect(x: gap.minX - tab.leftEdge, y: hairline, width: tab.leftEdge, height: 1 - hairline).fill(using: .sourceOver)
        NSRect(x: gap.maxX, y: hairline, width: hairline, height: 1 - hairline).fill(using: .sourceOver)
        (tab.item.background ?? .controlBackgroundColor).setFill()
        NSRect(x: gap.minX, y: 0, width: gap.width, height: 1).fill()
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
    var showsDivider = true { didSet { if showsDivider != oldValue { needsDisplay = true } } }
    /// The first tab, which has no left edge: the strip's own edge is there.
    var isFirst = false { didSet { if isFirst != oldValue { needsDisplay = true } } }
    /// The width of the selected tab's left edge.
    var leftEdge: CGFloat { isFirst ? 0 : TabStrip.hairline(in: self) }
    private var isHovered = false { didSet { if isHovered != oldValue { update() } } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    /// Called when the tab's size changes, so the strip moves the gap in its line along.
    var onLayout: (() -> Void)?

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
        // The active pane's selected tab is told apart by its icon.
        let accent = isSelected && isActive
        icon.contentTintColor = item.tint ?? (accent ? .controlAccentColor : .secondaryLabelColor)
        label.textColor = item.tint ?? (isSelected ? .labelColor : .secondaryLabelColor)
        // The × keeps its space so titles don't shift on hover.
        close.isHidden = !item.closable
        close.alphaValue = isSelected || isHovered ? 1 : 0
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Filled here rather than as a layer colour: a CGColor is resolved once, against whatever
        // appearance is current at the time, and doesn't follow the window into dark mode.
        if isSelected {
            // The content's colour between two edges that meet the line under the row.
            (item.background ?? .controlBackgroundColor).setFill()
            let hairline = TabStrip.hairline(in: self)
            NSRect(x: leftEdge, y: 0, width: bounds.width - leftEdge - hairline, height: bounds.height).fill()
            TabStrip.lineColor.setFill()
            NSRect(x: 0, y: 0, width: leftEdge, height: bounds.height).fill(using: .sourceOver)
            NSRect(x: bounds.maxX - hairline, y: 0, width: hairline, height: bounds.height).fill(using: .sourceOver)
            return
        }
        if isHovered {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            bounds.fill(using: .sourceOver)
        }
        // A short divider between tabs.
        if showsDivider {
            TabStrip.lineColor.setFill()
            let hairline = TabStrip.hairline(in: self)
            NSRect(x: bounds.maxX - hairline, y: 7, width: hairline, height: bounds.height - 14).fill(using: .sourceOver)
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
