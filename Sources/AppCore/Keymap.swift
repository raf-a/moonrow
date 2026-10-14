import Foundation

/// A keyboard shortcut: a menu key equivalent plus modifiers. An empty key means "no shortcut".
public struct KeyBinding: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// As AppKit's `keyEquivalent`: a lowercase character, `\r`, `\u{8}` (delete), or a
    /// function-key character (`\u{F702}` ←, `\u{F704}` F1, …).
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        var key = key.count == 1 && key.first!.isLetter ? key.lowercased() : key
        // A recorded ⇧⌘] arrives as "}"; it's kept as the key pressed, "]" with ⇧.
        if modifiers.contains(.shift), let base = Self.unshifted[key] { key = base }
        self.key = key
        self.modifiers = modifiers
    }

    /// US-layout punctuation and its shifted character.
    static let shifted: [String: String] = [
        "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~", "-": "_", "=": "+",
    ]
    static let unshifted = Dictionary(uniqueKeysWithValues: shifted.map { ($1, $0) })

    public static let empty = KeyBinding("", [])

    /// The key as a menu item's `keyEquivalent`. AppKit matches the character typed: a shifted
    /// letter by its case, so ⇧⌘S must be "S" (with "s" the item would also catch a plain ⌘S,
    /// and miss ⇧⌘S), and shifted punctuation by its shifted character, so ⇧⌘] is "}".
    public var menuKey: String {
        guard modifiers.contains(.shift) else { return key }
        if key.count == 1 && key.first!.isLetter { return key.uppercased() }
        return Self.shifted[key] ?? key
    }

    public var isEmpty: Bool { key.isEmpty }

    /// F1…F35, arrows, Home/End/Page keys: usable without ⌘ or ⌃.
    var isFunctionKey: Bool {
        guard let u = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1 else { return false }
        return (0xF704...0xF726).contains(u)
    }

    /// A shortcut must use ⌘ or ⌃ (or be a function key), so typing never triggers one.
    public var isValid: Bool {
        !isEmpty && (isFunctionKey || modifiers.contains(.command) || modifiers.contains(.control))
    }

    /// `⇧⌘↩`, in the order macOS menus show modifiers.
    public var display: String {
        guard !isEmpty else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    static func keyName(_ key: String) -> String {
        switch key {
        case "\r": return "↩"
        case "\u{3}": return "⌤"
        case "\u{8}", "\u{7F}": return "⌫"
        case "\u{F728}": return "⌦"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{1B}": return "⎋"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\u{F729}": return "↖"
        case "\u{F72B}": return "↘"
        case "\u{F72C}": return "⇞"
        case "\u{F72D}": return "⇟"
        default:
            if let u = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1, (0xF704...0xF726).contains(u) {
                return "F\(u - 0xF704 + 1)"
            }
            return key.uppercased()
        }
    }
}

/// A menu command whose shortcut can be changed. `id` is the action's selector name.
public struct KeyCommand: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var group: String
    public var defaultBinding: KeyBinding

    public init(_ id: String, _ title: String, _ group: String, _ key: String, _ modifiers: KeyBinding.Modifiers = .command) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultBinding = KeyBinding(key, modifiers)
    }
}

/// The commands the Keymap preferences offer, with their default shortcuts, and the user's
/// changes on top. The app's menus take every listed command's shortcut from here.
public enum Keymap {
    public static let commands: [KeyCommand] = [
        KeyCommand("newConnection:", "New Connection", "General", "n"),
        KeyCommand("showConnections:", "Open Connection", "General", "k", [.command, .shift]),
        KeyCommand("newWindow:", "New Window", "General", "n", [.command, .option]),
        KeyCommand("reloadWorkspace:", "Reload Workspace", "General", "r"),
        KeyCommand("focusItemFilter:", "Filter Items in Sidebar", "General", "f", [.command, .shift]),
        KeyCommand("showQueryHistory:", "Show Query History", "General", "y", [.command, .shift]),
        KeyCommand("exportData:", "Export", "General", "e"),
        KeyCommand("undo:", "Undo", "General", "z"),
        KeyCommand("redo:", "Redo", "General", "z", [.command, .shift]),
        KeyCommand("toggleRightSidebar:", "Toggle Right Sidebar", "General", " ", []),
        KeyCommand("toggleSidebar:", "Toggle Left Sidebar", "General", "0"),
        KeyCommand("toggleQueryLog:", "Toggle Query Log", "General", "c", [.command, .control]),
        KeyCommand("showRunningQueries:", "Running Queries", "General", ""),
        KeyCommand("searchInDatabase:", "Search in Database", "General", ""),
        KeyCommand("showDiagram:", "Show Diagram", "General", ""),
        KeyCommand("exportTables:", "Export Tables", "General", ""),
        KeyCommand("importJSON:", "Import JSON", "General", ""),
        KeyCommand("importSQLFile:", "Import SQL File", "General", ""),
        KeyCommand("backupDatabases:", "Backup", "General", ""),
        KeyCommand("restoreDatabase:", "Restore", "General", ""),

        KeyCommand("quickOpen:", "Quick Open", "Navigate", "p"),
        KeyCommand("openDatabase:", "Open Database", "Navigate", "k"),
        KeyCommand("goBack:", "Back", "Navigate", "\u{F702}", [.command, .control]),
        KeyCommand("goForward:", "Forward", "Navigate", "\u{F703}", [.command, .control]),
        KeyCommand("splitPaneRight:", "Split Pane Right", "Navigate", "d", [.command, .shift]),
        KeyCommand("selectNextPane:", "Select Next Pane", "Navigate", "]", [.command, .option]),
        KeyCommand("selectPreviousPane:", "Select Previous Pane", "Navigate", "[", [.command, .option]),
        KeyCommand("selectNextWorkspace:", "Select Next Workspace", "Navigate", "]", [.command, .shift]),
        KeyCommand("selectPreviousWorkspace:", "Select Previous Workspace", "Navigate", "[", [.command, .shift]),

        KeyCommand("newQueryTab:", "New Query Tab", "Tabs", "t"),
        KeyCommand("closeTab:", "Close Tab", "Tabs", "w"),
        KeyCommand("selectNextTab:", "Select Next Tab", "Tabs", "]"),
        KeyCommand("selectPreviousTab:", "Select Previous Tab", "Tabs", "["),

        // In a grid, Run Current opens the cell editor and Add Row's shortcut is Beautify in the
        // editor (AppKit lets only one menu item have a shortcut); the item takes its title from
        // the focus.
        KeyCommand("runCurrentQuery:", "Run Current Statement / Open Cell Editor", "SQL Editor", "\r"),
        KeyCommand("runAllQueries:", "Run All Statements", "SQL Editor", "\r", [.command, .shift]),
        KeyCommand("cancelQuery:", "Stop Query", "SQL Editor", "."),
        KeyCommand("toggleLineComment:", "Toggle Comment", "SQL Editor", "/"),
        KeyCommand("toggleBlockComment:", "Toggle Block Comment", "SQL Editor", "/", [.command, .option]),
        KeyCommand("compactSQL:", "Compact SQL", "SQL Editor", "i", [.command, .shift]),
        KeyCommand("saveQuery:", "Save", "SQL Editor", ""),
        KeyCommand("saveQueryAs:", "Save As", "SQL Editor", "s", [.command, .shift]),

        KeyCommand("showTableData:", "Show Table Data", "Table", "[", [.command, .control]),
        KeyCommand("showTableStructure:", "Show Table Structure", "Table", "]", [.command, .control]),
        KeyCommand("showTableDefinition:", "Show Definition", "Table", ""),
        KeyCommand("commitChanges:", "Commit Changes", "Table", "s"),
        KeyCommand("discardChanges:", "Discard Changes", "Table", "\u{8}", [.command, .shift]),
        KeyCommand("previewChanges:", "Preview Changes", "Table", "p", [.command, .shift]),
        KeyCommand("addRow:", "Add Row / Beautify SQL", "Table", "i"),
        KeyCommand("duplicateRows:", "Duplicate Rows", "Table", "d"),
        KeyCommand("deleteRows:", "Delete Rows or Items", "Table", "\u{8}"),
        KeyCommand("truncateTable:", "Truncate Table", "Table", "\u{8}", .option),
        KeyCommand("toggleFilters:", "Show Filters", "Table", "f"),
        KeyCommand("copySelectedCells:", "Copy Selected Cells", "Table", "c", [.command, .shift]),
        KeyCommand("pasteIntoSelectedCells:", "Paste into Selected Cells", "Table", "v", [.command, .shift]),
        KeyCommand("reloadCurrentTab:", "Reload Table", "Table", "r", [.command, .option]),
        KeyCommand("previousPage:", "Previous Page", "Table", "\u{F702}"),
        KeyCommand("nextPage:", "Next Page", "Table", "\u{F703}"),
    ]

    public static func command(_ id: String) -> KeyCommand? { commands.first { $0.id == id } }

    /// The shortcut in effect: the user's (which may be `.empty`), else the default.
    public static func binding(for id: String, overrides: [String: KeyBinding]) -> KeyBinding? {
        overrides[id] ?? command(id)?.defaultBinding
    }

    /// Titles of everything else `binding` would trigger: other listed commands, and `fixed`
    /// shortcuts the user can't change (Copy, Quit, …).
    public static func conflicts(
        _ binding: KeyBinding, for id: String, overrides: [String: KeyBinding],
        fixed: [(title: String, binding: KeyBinding)] = []
    ) -> [String] {
        conflictingCommands(binding, for: id, overrides: overrides).map(\.title)
            + fixed.filter { !binding.isEmpty && $0.binding == binding }.map(\.title)
    }

    /// Other listed commands that have `binding`.
    public static func conflictingCommands(_ binding: KeyBinding, for id: String, overrides: [String: KeyBinding]) -> [KeyCommand] {
        guard !binding.isEmpty else { return [] }
        return commands.filter { $0.id != id && self.binding(for: $0.id, overrides: overrides) == binding }
    }

    /// Overrides without the entries that just restate a default.
    public static func normalized(_ overrides: [String: KeyBinding]) -> [String: KeyBinding] {
        overrides.filter { id, binding in command(id).map { $0.defaultBinding != binding } ?? false }
    }
}
