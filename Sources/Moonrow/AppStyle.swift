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

/// A connection's colour as a capsule, with its tag written in it when it has one.
final class ConnectionMarkView: NSView {
    private let color: NSColor?
    private let label = NSTextField(labelWithString: "")

    init(_ config: ConnectionConfig) {
        color = config.markColor
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = config.tag?.title.uppercased() ?? ""
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.isHidden = config.tag == nil
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        if config.tag == nil { widthAnchor.constraint(equalToConstant: 18).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.backgroundColor = (color ?? .systemGray).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
