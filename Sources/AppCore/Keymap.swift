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
        self.key = key.count == 1 && key.first!.isLetter ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public static let empty = KeyBinding("", [])

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
        KeyCommand("showConnections:", "Show Connections", "General", "k", [.command, .shift]),
        KeyCommand("reloadWorkspace:", "Reload Workspace", "General", "r"),
        KeyCommand("focusItemFilter:", "Filter Items in Sidebar", "General", "f", [.command, .shift]),
        KeyCommand("showQueryHistory:", "Show Query History", "General", "y", [.command, .shift]),
        KeyCommand("exportData:", "Export", "General", "e"),

        KeyCommand("newQueryTab:", "New Query Tab", "Tabs", "t"),
        KeyCommand("closeTab:", "Close Tab", "Tabs", "w"),
        KeyCommand("selectNextTab:", "Select Next Tab", "Tabs", "]"),
        KeyCommand("selectPreviousTab:", "Select Previous Tab", "Tabs", "["),

        KeyCommand("runCurrentQuery:", "Run Current Statement", "SQL Editor", "\r"),
        KeyCommand("runAllQueries:", "Run All Statements", "SQL Editor", "\r", [.command, .shift]),
        KeyCommand("cancelQuery:", "Stop Query", "SQL Editor", "."),
        KeyCommand("toggleLineComment:", "Toggle Comment", "SQL Editor", "/"),
        KeyCommand("saveQueryAs:", "Save Query As", "SQL Editor", "s", [.command, .shift]),

        KeyCommand("showTableData:", "Show Table Data", "Table", "[", [.command, .control]),
        KeyCommand("showTableStructure:", "Show Table Structure", "Table", "]", [.command, .control]),
        KeyCommand("commitChanges:", "Commit Changes", "Table", "s"),
        KeyCommand("discardChanges:", "Discard Changes", "Table", "\u{8}", [.command, .shift]),
        KeyCommand("previewChanges:", "Preview Changes", "Table", "p", [.command, .shift]),
        KeyCommand("addRow:", "Add Row", "Table", "i"),
        KeyCommand("duplicateRows:", "Duplicate Rows", "Table", "d"),
        KeyCommand("deleteRows:", "Delete Rows", "Table", "\u{8}"),
        KeyCommand("toggleFilters:", "Show Filters", "Table", "f"),
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
        guard !binding.isEmpty else { return [] }
        let listed = commands.filter { $0.id != id && self.binding(for: $0.id, overrides: overrides) == binding }.map(\.title)
        return listed + fixed.filter { $0.binding == binding }.map(\.title)
    }

    /// Overrides without the entries that just restate a default.
    public static func normalized(_ overrides: [String: KeyBinding]) -> [String: KeyBinding] {
        overrides.filter { id, binding in command(id).map { $0.defaultBinding != binding } ?? false }
    }
}
