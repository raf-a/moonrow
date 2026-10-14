import AppCore
import AppKit
import DBKit
import UniformTypeIdentifiers

/// The cell editor (⌘↩ on a cell): one value in a sheet, big enough
/// for long text. Text shows as typed or, when it's JSON, laid out; bytes show as a hex dump or
/// as the image they hold. A file can be loaded into the value or the value saved to a file.
/// Save stages the change; read-only grids show the value without editing.
@MainActor
final class CellEditorController: NSWindowController, NSWindowDelegate {
    enum Mode: Int { case text, json, hex, image }

    /// The edited value, staged by the grid as one undo step.
    var onSave: ((CellChange) -> Void)?

    private let typeName: String
    private let isEditable: Bool
    private var value: CellContent
    private var changed = false
    private let modes = NSSegmentedControl()
    private var available: [Mode] = []
    private let textView = NSTextView.scrollableTextView()
    private var text: NSTextView { textView.documentView as! NSTextView }
    private let imageView = NSImageView()
    private let info = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let loadButton = NSButton(title: "Load from File…", target: nil, action: nil)
    private let exportButton = NSButton(title: "Save to File…", target: nil, action: nil)
    private let fileName: String

    init(title: String, value: CellContent, typeName: String, isEditable: Bool, fileName: String) {
        self.value = value
        self.typeName = typeName
        self.isEditable = isEditable
        self.fileName = fileName
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.title = title
        window.minSize = NSSize(width: 420, height: 260)
        super.init(window: window)
        window.delegate = self
        build()
        show(value, keepMode: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        modes.segmentStyle = .rounded
        modes.trackingMode = .selectOne
        modes.target = self
        modes.action = #selector(modeChanged(_:))
        modes.controlSize = .small

        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.allowsUndo = true
        text.textContainerInset = NSSize(width: 6, height: 6)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true
        // The image fits the area; it never sizes it.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentHuggingPriority(.init(1), for: axis)
            imageView.setContentCompressionResistancePriority(.init(1), for: axis)
        }

        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: isEditable ? "Cancel" : "Close", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1B}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))
        // Return types a line break; ⌘↩ saves.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "Stage the value"
        saveButton.isHidden = !isEditable
        loadButton.target = self
        loadButton.action = #selector(loadClicked(_:))
        loadButton.isHidden = !isEditable
        exportButton.target = self
        exportButton.action = #selector(exportClicked(_:))

        let top = NSStackView(views: [modes, info])
        top.spacing = 10
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [loadButton, exportButton, spacer, cancel, saveButton])
        bottom.spacing = 8

        // The text and the image share the middle; one of them shows.
        let body = NSView()
        for v in [textView, imageView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
            v.pin(to: body)
        }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        body.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let root = NSStackView(views: [top, body, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
        for v in [body, bottom] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
        }
        window?.contentView = root
        window?.initialFirstResponder = text
    }

    /// Fills the views for `value`; `keepMode` stays in the current mode when it still applies.
    private func show(_ value: CellContent, keepMode: Bool) {
        let previous = keepMode ? currentMode : nil
        available = []
        var size = ""
        switch value {
        case .value(.blob(let data)):
            available = [.hex]
            if NSImage(data: data) != nil { available.insert(.image, at: 0) }
            size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
        case .value(let v):
            available = [.text]
            if !v.isNull, CellViewer.prettyJSON(CellInput.editingText(v)) != nil { available.append(.json) }
            if case .text(let s) = v { size = "\(s.count.formatted()) characters" }
        case .defaultValue, .pending:
            available = [.text]
        }
        modes.segmentCount = available.count
        for (i, mode) in available.enumerated() {
            modes.setLabel(["Text", "JSON", "Hex", "Image"][mode.rawValue], forSegment: i)
            modes.setWidth(0, forSegment: i)
        }
        modes.isHidden = available.count < 2
        var parts = [typeName.isEmpty ? nil : typeName, size.isEmpty ? nil : size].compactMap { $0 }
        if case .value(.null) = value { parts.append("NULL") }
        if case .defaultValue = value { parts.append("DEFAULT") }
        info.stringValue = parts.joined(separator: " · ")
        let mode = previous.flatMap { available.contains($0) ? $0 : nil } ?? available[0]
        modes.selectedSegment = available.firstIndex(of: mode) ?? 0
        display(mode)
    }

    private var currentMode: Mode {
        available.indices.contains(modes.selectedSegment) ? available[modes.selectedSegment] : .text
    }

    private func display(_ mode: Mode) {
        let textEditable = isEditable && (mode == .text || mode == .json)
        textView.isHidden = mode == .image
        imageView.isHidden = mode != .image
        text.isEditable = textEditable
        switch (mode, value) {
        case (.image, .value(.blob(let data))):
            imageView.image = NSImage(data: data)
        case (.hex, .value(.blob(let data))):
            text.string = CellViewer.hexDump(data)
        case (.json, .value(let v)):
            let source = typedText ?? CellInput.editingText(v)
            text.string = CellViewer.prettyJSON(source) ?? source
        case (_, .value(let v)):
            text.string = typedText ?? CellInput.editingText(v)
        default:
            text.string = typedText ?? ""
        }
        typedText = nil
    }

    /// Text typed before switching between Text and JSON, carried to the other one.
    private var typedText: String?

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if text.isEditable, textChanged { typedText = text.string }
        display(currentMode)
    }

    private var textChanged: Bool {
        guard case .value(let v) = value else { return !text.string.isEmpty }
        let original = CellInput.editingText(v)
        return text.string != original && text.string != (CellViewer.prettyJSON(original) ?? original)
    }

    // MARK: - Buttons

    func begin(on window: NSWindow) {
        guard let sheet = self.window else { return }
        window.beginSheet(sheet) { _ in _ = self }
    }

    @objc private func cancelClicked(_ sender: Any?) { end() }

    @objc private func saveClicked(_ sender: Any?) {
        if changed {
            if case .value(let v) = value { onSave?(.value(v)) }
        } else if text.isEditable, textChanged {
            // Text is stored as shown, JSON layout included.
            onSave?(.value(.text(text.string)))
        }
        end()
    }

    private func end() {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Set Value ▸ From File…, inside the editor: replaces the value, staged on Save.
    @objc private func loadClicked(_ sender: Any?) {
        guard let sheet = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            switch Self.load(url, typeName: self.typeName) {
            case .success(let v):
                self.value = .value(v)
                self.changed = true
                self.show(self.value, keepMode: false)
            case .failure(let error):
                self.info.stringValue = error.message
            }
        }
    }

    @objc private func exportClicked(_ sender: Any?) {
        guard let sheet = window else { return }
        let data: Data
        switch value {
        case .value(.blob(let d)): data = d
        case .value(let v): data = Data((text.isEditable ? text.string : CellInput.editingText(v)).utf8)
        default: data = Data(text.string.utf8)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.beginSheetModal(for: sheet) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSSound.beep() }
        }
    }

    /// Reads a file as a column's value; the grid's Set Value ▸ From File… uses it too.
    static func load(_ url: URL, typeName: String) -> Result<DBValue, DatabaseError> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CellViewer.fileLimit else {
            return .failure(DatabaseError("The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(CellViewer.fileLimit), countStyle: .file))."))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(DatabaseError("The file couldn’t be read.")) }
        guard let v = CellViewer.value(fromFile: data, typeName: typeName) else {
            return .failure(DatabaseError("The file isn’t UTF-8 text, and the column doesn’t hold bytes."))
        }
        return .success(v)
    }

    // MARK: - For the dev harness

    var shownText: String { text.string }
    var modeTitles: [String] { (0..<modes.segmentCount).map { modes.label(forSegment: $0) ?? "" } }
    func select(mode title: String) {
        guard let i = modeTitles.firstIndex(of: title) else { return }
        modes.selectedSegment = i
        modeChanged(modes)
    }
    func type(_ s: String) { text.string = s }
    func save() { saveClicked(nil) }
}
