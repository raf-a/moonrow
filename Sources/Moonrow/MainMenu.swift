import AppCore
import AppKit

/// Actions sent through the responder chain (nil target). Implemented by whichever window
/// controller or the app delegate handles them.
@MainActor @objc protocol MoonrowActions {
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func showPreferences(_ sender: Any?)
    @objc optional func checkForUpdates(_ sender: Any?)
    @objc optional func showConnections(_ sender: Any?)
    @objc optional func newWindow(_ sender: Any?)
    @objc optional func reloadWorkspace(_ sender: Any?)
    @objc optional func focusItemFilter(_ sender: Any?)

    // Data grid
    @objc optional func commitChanges(_ sender: Any?)
    @objc optional func discardChanges(_ sender: Any?)
    @objc optional func previewChanges(_ sender: Any?)
    @objc optional func addRow(_ sender: Any?)
    @objc optional func duplicateRows(_ sender: Any?)
    @objc optional func deleteRows(_ sender: Any?)
    @objc optional func setNull(_ sender: Any?)
    @objc optional func setEmpty(_ sender: Any?)
    @objc optional func setDefault(_ sender: Any?)
    @objc optional func setValueFromFile(_ sender: Any?)
    @objc optional func quickLook(_ sender: Any?)
    @objc optional func copySelectedCells(_ sender: Any?)
    @objc optional func pasteIntoSelectedCells(_ sender: Any?)
    @objc optional func toggleFilters(_ sender: Any?)
    @objc optional func nextPage(_ sender: Any?)
    @objc optional func previousPage(_ sender: Any?)
    @objc optional func reloadCurrentTab(_ sender: Any?)

    // Structure
    @objc optional func showTableData(_ sender: Any?)
    @objc optional func showTableStructure(_ sender: Any?)
    @objc optional func showTableDefinition(_ sender: Any?)
    @objc optional func searchInDatabase(_ sender: Any?)
    @objc optional func showDiagram(_ sender: Any?)
    @objc optional func newTable(_ sender: Any?)
    @objc optional func truncateTable(_ sender: Any?)
    @objc optional func toggleRightSidebar(_ sender: Any?)

    // Tabs and the query editor
    @objc optional func newQueryTab(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func selectNextTab(_ sender: Any?)
    @objc optional func selectPreviousTab(_ sender: Any?)
    @objc optional func selectTabByNumber(_ sender: Any?)
    @objc optional func runCurrentQuery(_ sender: Any?)
    @objc optional func runAllQueries(_ sender: Any?)
    @objc optional func cancelQuery(_ sender: Any?)
    @objc optional func saveSQLAs(_ sender: Any?)
    @objc optional func addToQueries(_ sender: Any?)
    @objc optional func toggleLineComment(_ sender: Any?)
    @objc optional func toggleBlockComment(_ sender: Any?)
    @objc optional func formatSQL(_ sender: Any?)
    @objc optional func compactSQL(_ sender: Any?)
    @objc optional func goToLine(_ sender: Any?)
    @objc optional func toggleQueryLog(_ sender: Any?)
    @objc optional func showRunningQueries(_ sender: Any?)
    @objc optional func showSavedQueries(_ sender: Any?)
    @objc optional func showQueryHistory(_ sender: Any?)

    // Navigation, panes and workspaces
    @objc optional func quickOpen(_ sender: Any?)
    @objc optional func openDatabase(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    @objc optional func splitPaneRight(_ sender: Any?)
    @objc optional func selectNextPane(_ sender: Any?)
    @objc optional func selectPreviousPane(_ sender: Any?)
    @objc optional func selectNextWorkspace(_ sender: Any?)
    @objc optional func selectPreviousWorkspace(_ sender: Any?)

    // Export, import, backup and restore
    @objc optional func exportData(_ sender: Any?)
    @objc optional func exportTables(_ sender: Any?)
    @objc optional func importCSV(_ sender: Any?)
    @objc optional func importJSON(_ sender: Any?)
    @objc optional func importSQLFile(_ sender: Any?)
    @objc optional func backupDatabases(_ sender: Any?)
    @objc optional func restoreDatabase(_ sender: Any?)
    @objc optional func copyRowsAs(_ sender: Any?)
}

@MainActor
enum MainMenu {
    /// Shortcuts of the commands in `Keymap` come from there, with the user's `keyBindings`.
    static func build(keyBindings: [String: KeyBinding] = [:]) -> NSMenu {
        let menu = buildMenus()
        applyKeymap(menu, keyBindings)
        return menu
    }

    private static func applyKeymap(_ menu: NSMenu, _ overrides: [String: KeyBinding]) {
        for item in menu.items {
            if let sub = item.submenu { applyKeymap(sub, overrides) }
            guard let action = item.action, let binding = Keymap.binding(for: NSStringFromSelector(action), overrides: overrides) else { continue }
            item.keyEquivalent = binding.menuKey
            item.keyEquivalentModifierMask = binding.modifierFlags
        }
    }

    /// Every shortcut in `menu` outside `Keymap`, for conflict checks.
    static func fixedShortcuts(in menu: NSMenu?) -> [(title: String, binding: KeyBinding)] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [(title: String, binding: KeyBinding)] in
            if let sub = item.submenu { return fixedShortcuts(in: sub) }
            guard !item.keyEquivalent.isEmpty, !(item.action.map { Keymap.command(NSStringFromSelector($0)) != nil } ?? false) else { return [] }
            return [(item.title, KeyBinding(item.keyEquivalent, .init(item.keyEquivalentModifierMask)))]
        }
    }

    private static let editMenuDelegate = EditMenuDelegate()

    /// A query tab hides Show Filters (Find ▸ Find… is the same command there); it shows again
    /// each time the menu updates, before the items are validated.
    private final class EditMenuDelegate: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items where item.action == #selector(MoonrowActions.toggleFilters(_:)) { item.isHidden = false }
        }
    }

    private static func buildMenus() -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        main.addSubmenu("") { m in
            m.add("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.add("Check for Updates…", #selector(MoonrowActions.checkForUpdates(_:)))
            m.addItem(.separator())
            m.add("Settings…", #selector(MoonrowActions.showPreferences(_:)), ",")
            m.addItem(.separator())
            let services = m.add("Services", nil)
            services.submenu = NSMenu()
            NSApp.servicesMenu = services.submenu
            m.addItem(.separator())
            m.add("Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
            m.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            m.add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            m.add("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        }

        main.addSubmenu("File") { m in
            m.add("New Connection…", #selector(MoonrowActions.newConnection(_:)), "n")
            m.add("New Window", #selector(MoonrowActions.newWindow(_:)), "n", [.command, .option])
            m.add("New Query Tab", #selector(MoonrowActions.newQueryTab(_:)), "t")
            m.add("New Table…", #selector(MoonrowActions.newTable(_:)))
            // ⌘O opens SQL files into query tabs; databases open through connections.
            m.add("Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            m.addItem(.separator())
            m.add("Close Tab", #selector(MoonrowActions.closeTab(_:)), "w")
            m.add("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
            m.addItem(.separator())
            m.add("Add to Queries…", #selector(MoonrowActions.addToQueries(_:)))
            m.add("Save SQL As…", #selector(MoonrowActions.saveSQLAs(_:)), "s", [.command, .shift])
            m.addItem(.separator())
            m.add("Export…", #selector(MoonrowActions.exportData(_:)), "e")
            m.add("Export Tables…", #selector(MoonrowActions.exportTables(_:)))
            let importItem = m.add("Import", nil)
            importItem.submenu = NSMenu(title: "Import")
            importItem.submenu!.add("From CSV…", #selector(MoonrowActions.importCSV(_:)))
            importItem.submenu!.add("From JSON…", #selector(MoonrowActions.importJSON(_:)))
            importItem.submenu!.add("From SQL File…", #selector(MoonrowActions.importSQLFile(_:)))
            m.addItem(.separator())
            m.add("Backup…", #selector(MoonrowActions.backupDatabases(_:)))
            m.add("Restore…", #selector(MoonrowActions.restoreDatabase(_:)))
        }

        main.addSubmenu("Edit") { m in
            m.delegate = editMenuDelegate
            m.add("Undo", Selector(("undo:")), "z")
            m.add("Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            m.add("Commit Changes", #selector(MoonrowActions.commitChanges(_:)), "s")
            m.add("Discard Changes", #selector(MoonrowActions.discardChanges(_:)), "\u{8}", [.command, .shift])
            m.add("Preview Changes", #selector(MoonrowActions.previewChanges(_:)), "p", [.command, .shift])
            m.addItem(.separator())
            // ⌘I: Beautify SQL in a query tab, which answers it (AppKit gives a shortcut to one
            // item only).
            m.add("Add Row", #selector(MoonrowActions.addRow(_:)), "i")
            m.add("Duplicate Rows", #selector(MoonrowActions.duplicateRows(_:)), "d")
            // Titled by whoever has the focus: Delete Rows, Delete Columns, Delete Table, …
            m.add("Delete", #selector(MoonrowActions.deleteRows(_:)), "\u{8}")
            m.add("Truncate Table…", #selector(MoonrowActions.truncateTable(_:)), "\u{8}", .option)
            let setValue = m.add("Set Value", nil)
            setValue.submenu = NSMenu(title: "Set Value")
            setValue.submenu!.add("NULL", #selector(MoonrowActions.setNull(_:)))
            setValue.submenu!.add("Empty String", #selector(MoonrowActions.setEmpty(_:)))
            setValue.submenu!.add("DEFAULT", #selector(MoonrowActions.setDefault(_:)))
            setValue.submenu!.addItem(.separator())
            setValue.submenu!.add("From File…", #selector(MoonrowActions.setValueFromFile(_:)))
            m.addItem(.separator())
            m.add("Cut", #selector(NSText.cut(_:)), "x")
            m.add("Copy", #selector(NSText.copy(_:)), "c")
            m.add("Copy Selected Cells", #selector(MoonrowActions.copySelectedCells(_:)), "c", [.command, .shift])
            m.add("Paste", #selector(NSText.paste(_:)), "v")
            m.add("Paste into Selected Cells", #selector(MoonrowActions.pasteIntoSelectedCells(_:)), "v", [.command, .shift])
            m.add("Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            m.add("Toggle Comment", #selector(MoonrowActions.toggleLineComment(_:)), "/")
            m.add("Toggle Block Comment", #selector(MoonrowActions.toggleBlockComment(_:)), "/", [.command, .option])
            m.add("Compact SQL", #selector(MoonrowActions.compactSQL(_:)), "i", [.command, .shift])
            // ⌃Space by default, which macOS often keeps for switching input sources.
            m.add("Complete", #selector(NSTextView.complete(_:)))
            let find = m.add("Find", nil)
            find.submenu = NSMenu(title: "Find")
            for (title, action, key, mods) in [
                // ⌘F is "Show Filters" below; a query tab answers it with the find bar.
                ("Find…", NSTextFinder.Action.showFindInterface, "", NSEvent.ModifierFlags.command),
                ("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
                ("Find Next", .nextMatch, "g", .command),
                ("Find Previous", .previousMatch, "g", [.command, .shift]),
                // ⌘E is Export.
                ("Use Selection for Find", .setSearchString, "", .command),
            ] {
                find.submenu!.add(title, #selector(NSTextView.performFindPanelAction(_:)), key, mods).tag = action.rawValue
            }
            m.add("Go to Line…", #selector(MoonrowActions.goToLine(_:)))
            m.addItem(.separator())
            m.add("Show Filters", #selector(MoonrowActions.toggleFilters(_:)), "f")
            m.add("Filter Items", #selector(MoonrowActions.focusItemFilter(_:)), "f", [.command, .shift])
        }

        main.addSubmenu("View") { m in
            let sidebars = m.add("Sidebars", nil)
            sidebars.submenu = NSMenu(title: "Sidebars")
            sidebars.submenu!.add("Left Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "0")
            sidebars.submenu!.add("Right Sidebar", #selector(MoonrowActions.toggleRightSidebar(_:)), " ", [])
            sidebars.submenu!.add("Query Log", #selector(MoonrowActions.toggleQueryLog(_:)), "c", [.command, .control])
            m.addItem(.separator())
            // Workspace windows can share one window's tabs (Window ▸ Merge All Windows).
            m.add("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)))
            m.add("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift])
            m.addItem(.separator())
            // fn-F, the system's shortcut; with any other AppKit adds a second item.
            m.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", .function)
        }

        main.addSubmenu("Connection") { m in
            m.add("Reload", #selector(MoonrowActions.reloadWorkspace(_:)), "r")
            m.add("Reload Table", #selector(MoonrowActions.reloadCurrentTab(_:)), "r", [.command, .option])
            m.addItem(.separator())
            // ⌘↩: in a grid, the cell editor, which answers it under its own title.
            m.add("Run Current Statement", #selector(MoonrowActions.runCurrentQuery(_:)), "\r")
            m.add("Run All Statements", #selector(MoonrowActions.runAllQueries(_:)), "\r", [.command, .shift])
            m.add("Stop Query", #selector(MoonrowActions.cancelQuery(_:)), ".")
            m.add("Running Queries…", #selector(MoonrowActions.showRunningQueries(_:)))
            m.addItem(.separator())
            m.add("Search in Database…", #selector(MoonrowActions.searchInDatabase(_:)))
            m.add("Show Diagram", #selector(MoonrowActions.showDiagram(_:)))
            m.addItem(.separator())
            m.add("Open Connection…", #selector(MoonrowActions.showConnections(_:)), "k", [.command, .shift])
        }

        main.addSubmenu("Navigate") { m in
            m.add("Quick Open…", #selector(MoonrowActions.quickOpen(_:)), "p")
            m.add("Open Database…", #selector(MoonrowActions.openDatabase(_:)), "k")
            m.add("Back", #selector(MoonrowActions.goBack(_:)), "\u{F702}", [.command, .control])
            m.add("Forward", #selector(MoonrowActions.goForward(_:)), "\u{F703}", [.command, .control])
            m.addItem(.separator())
            m.add("Show Table Data", #selector(MoonrowActions.showTableData(_:)), "[", [.command, .control])
            m.add("Show Table Structure", #selector(MoonrowActions.showTableStructure(_:)), "]", [.command, .control])
            m.add("Show Definition", #selector(MoonrowActions.showTableDefinition(_:)))
            m.addItem(.separator())
            m.add("Previous Page", #selector(MoonrowActions.previousPage(_:)), "\u{F702}")
            m.add("Next Page", #selector(MoonrowActions.nextPage(_:)), "\u{F703}")
            m.addItem(.separator())
            m.add("Select Next Tab", #selector(MoonrowActions.selectNextTab(_:)), "]")
            m.add("Select Previous Tab", #selector(MoonrowActions.selectPreviousTab(_:)), "[")
            let tabs = m.add("Select Tab", nil)
            tabs.submenu = NSMenu(title: "Select Tab")
            for i in 1...9 {
                tabs.submenu!.add(i == 9 ? "Last Tab" : "Tab \(i)", #selector(MoonrowActions.selectTabByNumber(_:)), String(i)).tag = i
            }
            m.addItem(.separator())
            m.add("Split Pane Right", #selector(MoonrowActions.splitPaneRight(_:)), "d", [.command, .shift])
            m.add("Select Next Pane", #selector(MoonrowActions.selectNextPane(_:)), "]", [.command, .option])
            m.add("Select Previous Pane", #selector(MoonrowActions.selectPreviousPane(_:)), "[", [.command, .option])
            m.addItem(.separator())
            m.add("Select Next Workspace", #selector(MoonrowActions.selectNextWorkspace(_:)), "]", [.command, .shift])
            m.add("Select Previous Workspace", #selector(MoonrowActions.selectPreviousWorkspace(_:)), "[", [.command, .shift])
            m.addItem(.separator())
            m.add("Saved Queries", #selector(MoonrowActions.showSavedQueries(_:)))
            m.add("Query History", #selector(MoonrowActions.showQueryHistory(_:)), "y", [.command, .shift])
        }

        let window = main.addSubmenu("Window") { m in
            m.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            m.add("Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            m.add("Connections", #selector(AppDelegate.showWelcome(_:)))
            m.addItem(.separator())
            m.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window

        return main
    }
}

extension NSMenu {
    @discardableResult
    fileprivate func addSubmenu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        fill(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        addItem(item)
        return menu
    }

    @discardableResult
    func add(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: KeyBinding(key, .init(modifiers)).menuKey)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }
}

extension KeyBinding {
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension KeyBinding.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}
