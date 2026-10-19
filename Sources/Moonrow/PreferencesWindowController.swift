import AppCore
import AppKit
import MCPServer
import Sparkle
import SQLScript

/// Settings (⌘,): General, Fonts & Colors, Keymap, MCP. Every change is saved and applied at once.
@MainActor
final class PreferencesWindowController: NSWindowController {
    let tabs = PreferencesTabs()
    let general: GeneralPreferences
    let fonts: FontsPreferences
    let keymap: KeymapPreferences
    let mcp: MCPPreferences
    static let mcpPane = 3

    init(settings: SettingsStore, updater: SPUUpdater, store: ConnectionStore, mcp: @escaping () -> MCPService) {
        general = GeneralPreferences(settings: settings, updater: updater)
        fonts = FontsPreferences(settings: settings)
        keymap = KeymapPreferences(settings: settings)
        self.mcp = MCPPreferences(settings: settings, store: store, service: mcp)
        tabs.tabStyle = .toolbar
        for (controller, title, symbol) in [
            (general as NSViewController, "General", "gearshape"),
            (fonts, "Fonts & Colors", "textformat"),
            (keymap, "Keymap", "keyboard"),
            (self.mcp, "MCP", "point.3.connected.trianglepath.dotted"),
        ] {
            // The window is titled after the pane showing.
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        // Only workspace windows merge into native tabs.
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        super.init(window: window)
        if let pane = tabs.tabViewItems.first?.viewController?.view { window.fit(to: pane) }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane index: Int) {
        tabs.selectedTabViewItemIndex = index
    }
}

/// Panes of different heights: the window takes the selected pane's own size, keeping its top
/// edge in place. (Left to itself, the tab view controller keeps a size that can clip a pane.)
@MainActor
final class PreferencesTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let pane = item?.viewController?.view { view.window?.fit(to: pane, animate: true) }
    }
}

/// Saves a change and reports a failure in the window.
@MainActor
private func save(_ settings: SettingsStore, in view: NSView, _ change: (inout AppSettings) -> Void) {
    do {
        try settings.update(change)
    } catch {
        present(error, title: "Couldn't save the setting", in: view.window)
    }
}

@MainActor
private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
    let grid = NSGridView(views: rows.map { [$0.0.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: $0.0), $0.1] })
    grid.rowSpacing = 10
    grid.columnSpacing = 10
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    return grid
}

/// Pins to the top and sides with room below, so a short pane doesn't stretch its rows when the
/// window is sized for a taller one.
@MainActor
private func pinTop(_ grid: NSGridView, in root: NSView) {
    grid.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
        grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
    ])
}

@MainActor
private func hint(_ text: String) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    f.textColor = .secondaryLabelColor
    f.preferredMaxLayoutWidth = 360
    return f
}

// MARK: - General

@MainActor
final class GeneralPreferences: NSViewController {
    private let settings: SettingsStore
    let appearancePopup = NSPopUpButton()
    let safeModePopup = NSPopUpButton()
    private let safeModeHint = hint("")
    let reopenCheckbox = NSButton(checkboxWithTitle: "Reopen workspaces at launch", target: nil, action: nil)
    let parametersCheckbox = NSButton(checkboxWithTitle: "Ask for query parameters before running", target: nil, action: nil)
    let timeoutField = NSTextField().singleLine()
    let keepAliveCheckbox = NSButton(checkboxWithTitle: "Keep connections alive", target: nil, action: nil)
    let touchIDCheckbox = NSButton(checkboxWithTitle: "Use Touch ID instead of the password", target: nil, action: nil)
    private let touchIDHint = hint("")
    private let updater: SPUUpdater
    let updatesCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let lastCheckHint = hint("")

    init(settings: SettingsStore, updater: SPUUpdater) {
        self.settings = settings
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        appearancePopup.addItems(withTitles: AppSettings.Appearance.allCases.map(\.title))
        appearancePopup.target = self
        appearancePopup.action = #selector(changed(_:))
        safeModePopup.addItems(withTitles: SafeMode.allCases.map(\.title))
        safeModePopup.target = self
        safeModePopup.action = #selector(changed(_:))
        reopenCheckbox.target = self
        reopenCheckbox.action = #selector(changed(_:))
        parametersCheckbox.target = self
        parametersCheckbox.action = #selector(changed(_:))
        let seconds = NumberFormatter()
        seconds.allowsFloats = false
        seconds.minimum = NSNumber(value: AppSettings.queryTimeouts.lowerBound)
        seconds.maximum = NSNumber(value: AppSettings.queryTimeouts.upperBound)
        timeoutField.formatter = seconds
        timeoutField.alignment = .right
        timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        timeoutField.target = self
        timeoutField.action = #selector(changed(_:))
        let timeoutRow = NSStackView(views: [timeoutField, NSTextField(labelWithString: "seconds")])
        timeoutRow.spacing = 6
        keepAliveCheckbox.target = self
        keepAliveCheckbox.action = #selector(changed(_:))
        touchIDCheckbox.target = self
        touchIDCheckbox.action = #selector(changed(_:))
        // Sparkle keeps this setting in the user defaults.
        updatesCheckbox.bind(.value, to: updater, withKeyPath: #keyPath(SPUUpdater.automaticallyChecksForUpdates))
        let grid = formGrid([
            ("Appearance", appearancePopup),
            ("Startup", reopenCheckbox),
            ("", hint("The workspaces open when you quit come back with their tabs, unsaved queries included.")),

            ("SQL editor", parametersCheckbox),
            ("", hint("Placeholders such as :name, $1 (PostgreSQL) and ? (MySQL, SQLite) are filled in before the statements run.")),
            ("Query timeout", timeoutRow),
            ("", hint("A statement in a query tab that runs longer is stopped. 0 means no limit.")),

            ("Connections", keepAliveCheckbox),
            ("", hint("Workspaces send SELECT 1 on sessions idle for 30 seconds, so servers and firewalls don't close them.")),

            ("Safe mode for new connections", safeModePopup),
            ("", safeModeHint),
            ("", hint("Each connection keeps its own level: set it in the connection's form, or from the shield in a workspace's toolbar.")),
            ("", touchIDCheckbox),
            ("", touchIDHint),

            ("Updates", updatesCheckbox),
            ("", lastCheckHint),
        ])
        let root = NSView()
        root.addSubview(grid)
        pinTop(grid, in: root)
        root.widthAnchor.constraint(equalToConstant: 620).isActive = true
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        let s = settings.settings
        appearancePopup.selectItem(at: AppSettings.Appearance.allCases.firstIndex(of: s.appearance) ?? 0)
        safeModePopup.selectItem(at: SafeMode.allCases.firstIndex(of: s.defaultSafeMode) ?? 0)
        safeModeHint.stringValue = s.defaultSafeMode.detail
        reopenCheckbox.state = s.reopenWorkspaces ? .on : .off
        parametersCheckbox.state = s.queryParameters ? .on : .off
        timeoutField.integerValue = s.queryTimeout
        keepAliveCheckbox.state = s.keepAlive ? .on : .off
        touchIDCheckbox.state = s.safeModeTouchID ? .on : .off
        touchIDHint.stringValue = BiometricUnlock.isAvailable
            ? "Where safe mode asks for the password, Touch ID can answer, and the password still works."
            : "This Mac has no Touch ID set up."
        lastCheckHint.stringValue = updater.lastUpdateCheckDate.map {
            "Last checked \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? "Not checked yet."
    }

    @objc private func changed(_ sender: Any?) {
        let appearance = AppSettings.Appearance.allCases[max(0, appearancePopup.indexOfSelectedItem)]
        let safeMode = SafeMode.allCases[max(0, safeModePopup.indexOfSelectedItem)]
        let reopen = reopenCheckbox.state == .on
        let parameters = parametersCheckbox.state == .on
        let timeout = timeoutField.stringValue.isEmpty ? AppSettings().queryTimeout : timeoutField.integerValue
        let keepAlive = keepAliveCheckbox.state == .on
        let touchID = touchIDCheckbox.state == .on
        save(settings, in: view) {
            $0.appearance = appearance
            $0.defaultSafeMode = safeMode
            $0.reopenWorkspaces = reopen
            $0.queryParameters = parameters
            $0.queryTimeout = min(max(timeout, AppSettings.queryTimeouts.lowerBound), AppSettings.queryTimeouts.upperBound)
            $0.keepAlive = keepAlive
            $0.safeModeTouchID = touchID
        }
        refresh()
        // Safe-mode hints run from one line to two; the grid is pinned top and bottom.
        view.window?.fit(to: view, animate: true)
    }
}

// MARK: - Fonts & Colors

@MainActor
final class FontsPreferences: NSViewController {
    private let settings: SettingsStore
    let themePopup = NSPopUpButton()
    let fontPopup = NSPopUpButton()
    let editorSize = NSTextField().singleLine()
    private let editorStepper = NSStepper()
    let gridSize = NSTextField().singleLine()
    private let gridStepper = NSStepper()
    let alternatingBox = NSButton(checkboxWithTitle: "Alternate row backgrounds", target: nil, action: nil)
    private let preview = SQLTextView.make()
    private let highlighter = SQLHighlighter(dialect: .postgres)
    private static let sample = """
        -- Customers who ordered this year
        SELECT c.id, c."name", count(*) AS orders
        FROM customers c
        JOIN orders o ON o.customer_id = c.id
        WHERE o.placed_at >= '2026-01-01' AND o.total > $1
        GROUP BY c.id
        LIMIT 50;
        """

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        themePopup.addItems(withTitles: EditorTheme.all.map(\.name))
        fontPopup.addItem(withTitle: "System Monospaced")
        fontPopup.menu?.addItem(.separator())
        fontPopup.addItems(withTitles: AppStyle.monospacedFamilies)
        for (field, stepper, range) in [(editorSize, editorStepper, AppSettings.editorFontSizes), (gridSize, gridStepper, AppSettings.gridFontSizes)] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            field.formatter = {
                let f = NumberFormatter()
                f.minimum = NSNumber(value: range.lowerBound)
                f.maximum = NSNumber(value: range.upperBound)
                f.maximumFractionDigits = 0
                return f
            }()
            stepper.minValue = range.lowerBound
            stepper.maxValue = range.upperBound
            stepper.increment = 1
            stepper.valueWraps = false
        }
        for control in [themePopup, fontPopup, editorSize, editorStepper, gridSize, gridStepper, alternatingBox] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }

        preview.isEditable = false
        preview.string = Self.sample
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.borderType = .bezelBorder
        previewScroll.hasVerticalScroller = false
        previewScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        previewScroll.widthAnchor.constraint(equalToConstant: 440).isActive = true

        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 6
            return s
        }
        let grid = formGrid([
            ("Editor theme", themePopup),
            ("Editor font", row(fontPopup, editorSize, editorStepper, NSTextField(labelWithString: "pt"))),
            ("", previewScroll),
            ("Grid font size", row(gridSize, gridStepper, NSTextField(labelWithString: "pt"))),
            ("", alternatingBox),
            ("", hint("Themes have a light and a dark palette; the editor follows the app's appearance.")),
        ])
        let root = NSView()
        root.addSubview(grid)
        pinTop(grid, in: root)
        root.widthAnchor.constraint(equalToConstant: 620).isActive = true
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: AppStyle.didChange, object: nil)
        refresh()
    }

    private func refresh() {
        let s = settings.settings
        themePopup.selectItem(at: EditorTheme.all.firstIndex { $0.id == s.theme.id } ?? 0)
        if s.editorFontName.isEmpty || fontPopup.item(withTitle: s.editorFontName) == nil {
            fontPopup.selectItem(at: 0)
        } else {
            fontPopup.selectItem(withTitle: s.editorFontName)
        }
        editorSize.doubleValue = s.editorFontSize
        editorStepper.doubleValue = s.editorFontSize
        gridSize.doubleValue = s.gridFontSize
        gridStepper.doubleValue = s.gridFontSize
        alternatingBox.state = s.alternatingRows ? .on : .off
        styleChanged()
    }

    @objc private func styleChanged() {
        preview.applyStyle()
        highlighter.highlight(preview.textStorage!, delta: 0, full: true)
    }

    @objc private func changed(_ sender: Any?) {
        if sender as? NSStepper === editorStepper { editorSize.doubleValue = editorStepper.doubleValue }
        if sender as? NSStepper === gridStepper { gridSize.doubleValue = gridStepper.doubleValue }
        let theme = EditorTheme.all[max(0, themePopup.indexOfSelectedItem)].id
        let font = fontPopup.indexOfSelectedItem <= 0 ? "" : fontPopup.titleOfSelectedItem ?? ""
        let editor = min(max(editorSize.doubleValue, AppSettings.editorFontSizes.lowerBound), AppSettings.editorFontSizes.upperBound)
        let grid = min(max(gridSize.doubleValue, AppSettings.gridFontSizes.lowerBound), AppSettings.gridFontSizes.upperBound)
        let alternating = alternatingBox.state == .on
        save(settings, in: view) {
            $0.editorTheme = theme
            $0.editorFontName = font
            $0.editorFontSize = editor
            $0.gridFontSize = grid
            $0.alternatingRows = alternating
        }
        refresh()
    }
}

// MARK: - Keymap

@MainActor
final class KeymapPreferences: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: SettingsStore
    let table = NSTableView()
    private let message = hint("Click a shortcut, then press the new keys. Delete removes it, Esc keeps the old one.")
    /// Group headers and commands, in display order.
    private var rows: [Row] = []

    private enum Row {
        case group(String)
        case command(KeyCommand)
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        var seen: [String] = []
        for c in Keymap.commands {
            if !seen.contains(c.group) {
                seen.append(c.group)
                rows.append(.group(c.group))
            }
            rows.append(.command(c))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, width) in [("command", 250.0), ("shortcut", 170.0), ("reset", 80.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            table.addTableColumn(column)
        }
        // The section labels say what the columns are; a header would also show rows through it.
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        let bottom = NSStackView(views: [message, NSView(), restore])
        let stack = NSStackView(views: [scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for v in [scroll, bottom] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 620).isActive = true
        view = stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// The row of a section header. For the dev harness.
    func row(ofGroup group: String) -> Int? {
        rows.firstIndex { if case .group(group) = $0 { true } else { false } }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }

    // Section headers are ordinary rows: AppKit's group rows float over the commands below them
    // and draw a band wider than the table.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return row == 0 ? 24 : 34 }
        return 26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            guard tableColumn?.identifier.rawValue == "command" else { return nil }
            let cell = NSView()
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            // Read as words, not the uppercased letters.
            label.setAccessibilityLabel(title)
            label.setAccessibilityRole(.staticText)
            label.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXHeading"))
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
            return cell
        case .command(let command):
            let overrides = settings.settings.keyBindings
            switch tableColumn?.identifier.rawValue {
            case "command":
                let label = NSTextField(labelWithString: command.title)
                label.lineBreakMode = .byTruncatingTail
                return label
            case "shortcut":
                let recorder = ShortcutRecorder()
                recorder.binding = Keymap.binding(for: command.id, overrides: overrides) ?? .empty
                recorder.onRecord = { [weak self] binding in self?.assign(binding, to: command) }
                recorder.setAccessibilityHelp("Shortcut for \(command.title). Press to record a new one.")
                return recorder
            default:
                let changed = overrides[command.id] != nil
                let reset = NSButton(title: "Default", target: self, action: #selector(resetClicked(_:)))
                reset.bezelStyle = .accessoryBarAction
                reset.controlSize = .small
                reset.identifier = .init(command.id)
                reset.isHidden = !changed
                reset.toolTip = "Back to \(command.defaultBinding.display)"
                reset.setAccessibilityLabel("Restore the default shortcut for \(command.title)")
                return reset
            }
        }
    }

    /// Sets a shortcut. One that another command uses is offered to move here; one the app
    /// keeps fixed (Copy, Quit, …) is refused.
    func assign(_ binding: KeyBinding, to command: KeyCommand) {
        let overrides = settings.settings.keyBindings
        guard binding.isEmpty || binding.isValid else {
            return show("\(binding.display) can't be a shortcut: use ⌘ or ⌃ with it (function keys work alone).")
        }
        let fixed = MainMenu.fixedShortcuts(in: NSApp.mainMenu)
        if let taken = fixed.first(where: { $0.binding == binding && !binding.isEmpty }) {
            return show("\(binding.display) is \(taken.title)’s shortcut, which can't be changed.")
        }
        let others = Keymap.conflictingCommands(binding, for: command.id, overrides: overrides)
        let apply = { [self] in
            save(settings, in: view) {
                for other in others { $0.keyBindings[other.id] = .empty }
                $0.keyBindings[command.id] = binding
            }
            show(others.isEmpty ? "" : "\(binding.display) moved from \(others.map(\.title).joined(separator: ", ")).")
            table.reloadData()
        }
        guard !others.isEmpty, let window = view.window else { return apply() }
        let alert = NSAlert()
        alert.messageText = "\(binding.display) is already used by \(others.map(\.title).joined(separator: ", "))."
        alert.informativeText = "Use it for \(command.title) instead? The other command is left without a shortcut."
        alert.addButton(withTitle: "Use Here")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { apply() } else { self?.table.reloadData() }
        }
    }

    private func show(_ text: String) {
        message.stringValue = text.isEmpty ? "Click a shortcut, then press the new keys. Delete removes it, Esc keeps the old one." : text
        message.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        table.reloadData()
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let command = Keymap.command(id) else { return }
        assign(command.defaultBinding, to: command)
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        save(settings, in: view) { $0.keyBindings = [:] }
        show("")
    }
}

/// Click to record a shortcut: the next key press with ⌘ or ⌃ (or a function key) becomes it.
/// Delete clears it; Esc or clicking elsewhere cancels.
@MainActor
final class ShortcutRecorder: NSButton {
    var binding = KeyBinding.empty { didSet { updateTitle() } }
    var onRecord: ((KeyBinding) -> Void)?
    private(set) var isRecording = false { didSet { updateTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(clicked(_:))
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = isRecording ? "Type shortcut…" : binding.isEmpty ? "None" : binding.display
        contentTintColor = isRecording ? .controlAccentColor : binding.isEmpty ? .tertiaryLabelColor : nil
    }

    @objc private func clicked(_ sender: Any?) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    // ⌘ combinations arrive here before the menus see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    /// Turns a key press into a binding and reports it.
    func record(_ event: NSEvent) {
        let modifiers = KeyBinding.Modifiers(event.modifierFlags)
        if modifiers.isEmpty, event.keyCode == 53 {  // Esc
            isRecording = false
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {  // Delete
            isRecording = false
            binding = .empty
            onRecord?(.empty)
            return
        }
        guard let key = Self.key(for: event) else { return NSSound.beep() }
        isRecording = false
        let recorded = KeyBinding(key, modifiers)
        onRecord?(recorded)
    }

    /// The key as a menu key equivalent, ignoring modifiers (⇧⌘] is "]" with shift).
    static func key(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "\r"
        case 76: return "\u{3}"
        case 51: return "\u{8}"
        case 117: return "\u{F728}"
        case 48: return "\t"
        case 49: return " "
        case 123: return "\u{F702}"
        case 124: return "\u{F703}"
        case 125: return "\u{F701}"
        case 126: return "\u{F700}"
        default: break
        }
        if let chars = event.charactersIgnoringModifiers, let u = chars.unicodeScalars.first?.value, (0xF704...0xF726).contains(u) {
            return chars
        }
        guard let plain = event.characters(byApplyingModifiers: []), plain.count == 1 else { return nil }
        return plain.lowercased()
    }
}
