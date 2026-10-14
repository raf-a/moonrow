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

    /// A dot in the colour, for menus. It's drawn when shown, so it follows light and dark.
    func dot(diameter: CGFloat = 10) -> NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

/// A connection's tag after its name, in the connection list and the workspace title: small
/// regular text in the tag's colour on a faint fill of the same colour, slightly rounded. The text
/// is darkened (light mode) or lightened (dark mode) as far as it takes to read at
/// `minimumContrast` on that fill. On a selected row it turns to the selection's text colour.
final class TagCapsule: NSView {
    /// WCAG's minimum for small text.
    static let minimumContrast: CGFloat = 4.5
    private static let fillAlpha: CGFloat = 0.15
    private let label = NSTextField(labelWithString: "")
    private var color = NSColor.secondaryLabelColor
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { restyle() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 10, weight: .regular)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tag: ConnectionTag?) {
        isHidden = tag == nil
        label.stringValue = tag?.name ?? ""
        color = tag?.color.nsColor ?? .secondaryLabelColor
        restyle()
    }

    private func restyle() {
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// Runs again when the appearance changes, so the text's contrast follows light and dark.
    override func updateLayer() {
        layer?.cornerRadius = 4
        if isEmphasized {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            label.textColor = .alternateSelectedControlTextColor
            return
        }
        layer?.backgroundColor = color.withAlphaComponent(Self.fillAlpha).cgColor
        guard let text = color.usingColorSpace(.sRGB),
              let page = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else {
            label.textColor = color
            return
        }
        let fill = page.blended(withFraction: Self.fillAlpha, of: text) ?? page
        let dark = fill.luminance < 0.5
        var readable = text
        var step: CGFloat = 0
        while readable.contrast(with: fill) < Self.minimumContrast, step < 1 {
            step += 0.05
            readable = text.blended(withFraction: step, of: dark ? .white : .black) ?? readable
        }
        label.textColor = readable
    }
}

extension NSColor {
    /// Relative luminance (WCAG) of an sRGB colour.
    var luminance: CGFloat {
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(redComponent) + 0.7152 * channel(greenComponent) + 0.0722 * channel(blueComponent)
    }

    /// The contrast ratio (WCAG) between two sRGB colours, from 1 to 21.
    func contrast(with other: NSColor) -> CGFloat {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
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

/// Names of objects with staged changes. In light mode, darker than the system colours: 3.5:1
/// or better on a list, and with Increase Contrast 4.5:1 or better on its grey selection too.
/// In dark mode, lighter, at 4.5:1 or better on the selection either way.
extension NSColor {
    static let stagedNew = staged(light: 0x28963F, lightHighContrast: 0x1B6E30, dark: 0x4CD964)
    static let stagedEdited = staged(light: 0xCF5A00, lightHighContrast: 0x9A4400, dark: 0xFFA347)
    static let stagedDropped = staged(light: 0xE5262E, lightHighContrast: 0xC4001A, dark: 0xFF9F99)

    private static func staged(light: Int, lightHighContrast: Int, dark: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let (light, lightHighContrast, dark) = (rgb(light), rgb(lightHighContrast), rgb(dark))
        return NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua, .accessibilityHighContrastDarkAqua: dark
            case .accessibilityHighContrastAqua: lightHighContrast
            // Settings ▸ Appearance ▸ Light sets the plain appearance; the setting still counts.
            default: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? lightHighContrast : light
            }
        }
    }
}

/// A staged change as a list shows it: the name in its colour and, when the Mac is set to
/// differentiate without colour, a letter after it too (A, M, D, as source control marks files).
enum StagedState {
    case new, edited, dropped

    var color: NSColor {
        switch self {
        case .new: .stagedNew
        case .edited: .stagedEdited
        case .dropped: .stagedDropped
        }
    }

    var letter: String {
        switch self {
        case .new: "A"
        case .edited: "M"
        case .dropped: "D"
        }
    }

    /// What VoiceOver reads after the name.
    var spoken: String {
        switch self {
        case .new: "new"
        case .edited: "modified"
        case .dropped: "deleted"
        }
    }

    /// System Settings ▸ Accessibility ▸ Display ▸ Differentiate without colour, or
    /// `MOONROW_LETTERS` for checking the letters without changing the setting.
    @MainActor static var showsLetters: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
            || ProcessInfo.processInfo.environment["MOONROW_LETTERS"] != nil
    }

    /// The label the letter goes in, hidden until `show(_:in:)` gives it a state.
    @MainActor static func makeLetterLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.isHidden = true
        label.setAccessibilityElement(false)  // the row's label says the state
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    /// Shows `state`'s letter in `label`, or hides it.
    @MainActor static func show(_ state: StagedState?, in label: NSTextField, size: CGFloat) {
        label.isHidden = state == nil || !showsLetters
        guard let state else { return }
        label.stringValue = state.letter
        label.font = .systemFont(ofSize: size)
        label.textColor = state.color
    }
}
