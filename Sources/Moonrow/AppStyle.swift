import AppCore
import AppKit

/// The preferences that change how things look, as AppKit values. The app delegate sets
/// `settings` at launch and after every change; views that care observe `didChange`.
@MainActor
enum AppStyle {
    static let didChange = Notification.Name("AppStyle.didChange")

    static var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            apply()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Fonts and colours derived from `settings`; recomputed on change.
    private(set) static var editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) static var gridFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private(set) static var colors = EditorColors(EditorTheme.standard)

    static func apply() {
        NSApp.appearance = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        editorFont = font(family: settings.editorFontName, size: settings.editorFontSize)
        gridFont = NSFont.monospacedDigitSystemFont(ofSize: settings.gridFontSize, weight: .regular)
        colors = EditorColors(settings.theme)
    }

    /// A family's regular face, or the system's monospaced font for an empty or missing family.
    static func font(family: String, size: Double) -> NSFont {
        let size = CGFloat(size)
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Fixed-pitch font families installed, for the editor font menu.
    static var monospacedFamilies: [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask)
        }
    }
}

/// An editor theme's colours as dynamic `NSColor`s: each follows the light or dark appearance
/// of the view it's drawn in.
struct EditorColors {
    let background, text, keyword, string, number, comment, identifier, parameter: NSColor
    let lineNumber, currentStatement, selection: NSColor

    init(_ theme: EditorTheme) {
        func color(_ pick: KeyPath<EditorTheme.Palette, String>) -> NSColor {
            let light = Self.color(theme.light[keyPath: pick])
            let dark = Self.color(theme.dark[keyPath: pick])
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
        background = color(\.background)
        text = color(\.text)
        keyword = color(\.keyword)
        string = color(\.string)
        number = color(\.number)
        comment = color(\.comment)
        identifier = color(\.identifier)
        parameter = color(\.parameter)
        lineNumber = color(\.lineNumber)
        currentStatement = color(\.currentStatement)
        selection = color(\.selection)
    }

    static func color(_ hex: String) -> NSColor {
        guard let c = EditorTheme.components(hex) else { return .textColor }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

extension ConnectionColor {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

extension ConnectionConfig {
    /// The colour to mark the connection with: its own, else its tag's.
    var markColor: NSColor? { (color ?? tag?.suggestedColor)?.nsColor }
}

/// The connection's tag as a capsule in its colour ("Production"), or a dot in the colour when
/// it has a colour and no tag. Shown after the connection's name in the workspace title. A solid
/// fill rather than glass: tinted glass greys out with its window, and the colour is a warning.
final class ConnectionBadge: NSView {
    init?(_ config: ConnectionConfig) {
        guard let color = config.markColor else { return nil }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let mark: NSView
        if let tag = config.tag {
            let label = NSTextField(labelWithString: tag.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = color.prefersDarkText ? .black : .white
            mark = Fill(color, label: label)
        } else {
            mark = Fill(color, label: nil)
        }
        addSubview(mark)
        mark.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private final class Fill: NSView {
        let color: NSColor

        /// A capsule around `label`, or a dot without one.
        init(_ color: NSColor, label: NSTextField?) {
            self.color = color
            super.init(frame: .zero)
            wantsLayer = true
            if let label {
                addSubview(label)
                label.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                    label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                    label.centerYAnchor.constraint(equalTo: centerYAnchor),
                    heightAnchor.constraint(equalToConstant: 17),
                ])
            } else {
                NSLayoutConstraint.activate([
                    widthAnchor.constraint(equalToConstant: 9),
                    heightAnchor.constraint(equalToConstant: 9),
                ])
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.cornerRadius = bounds.height / 2
            layer?.backgroundColor = color.cgColor
        }

        override func layout() {
            super.layout()
            needsDisplay = true
        }
    }
}

extension NSColor {
    /// Text on this colour reads better in black than in white (yellow, light greys).
    var prefersDarkText: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65
    }
}

/// A capsule behind `content`: Liquid Glass on macOS 26 and later (tinted when `tint` is set);
/// before, the tint as a solid fill, or the popover material without one.
final class GlassCapsule: NSView {
    let content: NSView
    private let backdrop: NSView
    private let tint: NSColor?

    init(_ content: NSView, tint: NSColor? = nil, padding: CGFloat = 8) {
        self.content = content
        self.tint = tint
        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -padding),
            content.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: holder.topAnchor),
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.tintColor = tint
            glass.contentView = holder
            // Pinned, so the capsule takes its size from the content.
            holder.pin(to: glass)
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            // A tinted capsule is a solid fill there, so the effect view stays hidden under it.
            effect.isHidden = tint != nil
            backdrop = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(backdrop)
        backdrop.pin(to: self)
        if holder.superview == nil {
            addSubview(holder)
            holder.pin(to: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if #available(macOS 26.0, *) { return }
        // Filled here so the colour follows the appearance.
        layer?.backgroundColor = tint?.cgColor
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            layer?.cornerRadius = radius
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = radius
            backdrop.layer?.masksToBounds = true
        }
    }
}

/// A search field for the sidebars, quieter than the system's: no bezel, a light grey rounded
/// fill, as in Xcode's navigators.
final class SidebarSearchField: NSSearchField {
    static let radius: CGFloat = 7

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 26)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        // Resolved here so the colour follows the appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
    }

    /// Without a bezel the system lays the field out from the top; this centres the magnifier,
    /// the text and the clear button.
    private final class Cell: NSSearchFieldCell {
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            NSRect(x: rect.minX + 6, y: rect.midY - 8, width: 16, height: 16)
        }

        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
            NSRect(x: rect.maxX - 22, y: rect.midY - 8, width: 16, height: 16)
        }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let height = ceil(font.ascender - font.descender + font.leading)
            return NSRect(x: rect.minX + 26, y: (rect.midY - height / 2).rounded(.down),
                          width: max(0, rect.width - 26 - 24), height: height)
        }

        override func drawingRect(forBounds rect: NSRect) -> NSRect { searchTextRect(forBounds: rect) }

        /// The focus ring follows the fill's rounded corners instead of the bounds.
        override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
            NSBezierPath(roundedRect: cellFrame, xRadius: SidebarSearchField.radius,
                         yRadius: SidebarSearchField.radius).fill()
        }

        override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
            cellFrame
        }

        override func titleRect(forBounds rect: NSRect) -> NSRect { searchTextRect(forBounds: rect) }

        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                           delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                       delegate: delegate, event: event)
        }

        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                             delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                         delegate: delegate, start: selStart, length: selLength)
        }
    }
}
