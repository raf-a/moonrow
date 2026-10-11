import AppKit

/// Actions sent through the responder chain (nil target). Implemented by whichever window
/// controller or the app delegate handles them.
@MainActor @objc protocol TabulaActions {
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func showConnections(_ sender: Any?)
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
    @objc optional func toggleFilters(_ sender: Any?)
    @objc optional func nextPage(_ sender: Any?)
    @objc optional func previousPage(_ sender: Any?)
    @objc optional func reloadCurrentTab(_ sender: Any?)

    // Tabs and the query editor
    @objc optional func newQueryTab(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func selectNextTab(_ sender: Any?)
    @objc optional func selectPreviousTab(_ sender: Any?)
    @objc optional func selectTabByNumber(_ sender: Any?)
    @objc optional func runCurrentQuery(_ sender: Any?)
    @objc optional func runAllQueries(_ sender: Any?)
    @objc optional func cancelQuery(_ sender: Any?)
    @objc optional func saveQueryAs(_ sender: Any?)
    @objc optional func toggleLineComment(_ sender: Any?)
    @objc optional func showSavedQueries(_ sender: Any?)
    @objc optional func showQueryHistory(_ sender: Any?)
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        main.addSubmenu("") { m in
            m.add("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
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
            m.add("New Connection…", #selector(TabulaActions.newConnection(_:)), "n")
            m.add("New Query Tab", #selector(TabulaActions.newQueryTab(_:)), "t")
            m.add("Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            m.addItem(.separator())
            m.add("Close Tab", #selector(TabulaActions.closeTab(_:)), "w")
            m.add("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
            m.addItem(.separator())
            m.add("Save Query As…", #selector(TabulaActions.saveQueryAs(_:)), "s", [.command, .shift])
        }

        main.addSubmenu("Edit") { m in
            m.add("Undo", Selector(("undo:")), "z")
            m.add("Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            m.add("Commit Changes", #selector(TabulaActions.commitChanges(_:)), "s")
            m.add("Discard Changes", #selector(TabulaActions.discardChanges(_:)), "\u{8}", [.command, .shift])
            m.add("Preview Changes", #selector(TabulaActions.previewChanges(_:)), "p", [.command, .shift])
            m.addItem(.separator())
            m.add("Add Row", #selector(TabulaActions.addRow(_:)), "i")
            m.add("Duplicate Rows", #selector(TabulaActions.duplicateRows(_:)), "d")
            m.add("Delete Rows", #selector(TabulaActions.deleteRows(_:)), "\u{8}")
            let setValue = m.add("Set Value", nil)
            setValue.submenu = NSMenu(title: "Set Value")
            setValue.submenu!.add("NULL", #selector(TabulaActions.setNull(_:)))
            setValue.submenu!.add("Empty String", #selector(TabulaActions.setEmpty(_:)))
            setValue.submenu!.add("DEFAULT", #selector(TabulaActions.setDefault(_:)))
            m.addItem(.separator())
            m.add("Cut", #selector(NSText.cut(_:)), "x")
            m.add("Copy", #selector(NSText.copy(_:)), "c")
            m.add("Paste", #selector(NSText.paste(_:)), "v")
            m.add("Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            m.add("Toggle Comment", #selector(TabulaActions.toggleLineComment(_:)), "/")
            let find = m.add("Find", nil)
            find.submenu = NSMenu(title: "Find")
            for (title, action, key, mods) in [
                // ⌘F is "Show Filters" below; a query tab answers it with the find bar.
                ("Find…", NSTextFinder.Action.showFindInterface, "", NSEvent.ModifierFlags.command),
                ("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
                ("Find Next", .nextMatch, "g", .command),
                ("Find Previous", .previousMatch, "g", [.command, .shift]),
                ("Use Selection for Find", .setSearchString, "e", .command),
            ] {
                find.submenu!.add(title, #selector(NSTextView.performFindPanelAction(_:)), key, mods).tag = action.rawValue
            }
            m.addItem(.separator())
            m.add("Show Filters", #selector(TabulaActions.toggleFilters(_:)), "f")
            m.add("Filter Items", #selector(TabulaActions.focusItemFilter(_:)), "f", [.command, .shift])
        }

        main.addSubmenu("View") { m in
            m.add("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "0")
            m.addItem(.separator())
            m.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        main.addSubmenu("Connection") { m in
            m.add("Reload", #selector(TabulaActions.reloadWorkspace(_:)), "r")
            m.add("Reload Table", #selector(TabulaActions.reloadCurrentTab(_:)), "r", [.command, .option])
            m.addItem(.separator())
            m.add("Run Current Statement", #selector(TabulaActions.runCurrentQuery(_:)), "\r")
            m.add("Run All Statements", #selector(TabulaActions.runAllQueries(_:)), "\r", [.command, .shift])
            m.add("Stop Query", #selector(TabulaActions.cancelQuery(_:)), ".")
            m.addItem(.separator())
            m.add("Show Connections", #selector(TabulaActions.showConnections(_:)), "k", [.command, .shift])
        }

        main.addSubmenu("Navigate") { m in
            m.add("Previous Page", #selector(TabulaActions.previousPage(_:)), "\u{F702}")
            m.add("Next Page", #selector(TabulaActions.nextPage(_:)), "\u{F703}")
            m.addItem(.separator())
            m.add("Select Next Tab", #selector(TabulaActions.selectNextTab(_:)), "]")
            m.add("Select Previous Tab", #selector(TabulaActions.selectPreviousTab(_:)), "[")
            let tabs = m.add("Select Tab", nil)
            tabs.submenu = NSMenu(title: "Select Tab")
            for i in 1...9 {
                tabs.submenu!.add(i == 9 ? "Last Tab" : "Tab \(i)", #selector(TabulaActions.selectTabByNumber(_:)), String(i)).tag = i
            }
            m.addItem(.separator())
            m.add("Saved Queries", #selector(TabulaActions.showSavedQueries(_:)))
            m.add("Query History", #selector(TabulaActions.showQueryHistory(_:)), "y", [.command, .shift])
        }

        let window = main.addSubmenu("Window") { m in
            m.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            m.add("Zoom", #selector(NSWindow.performZoom(_:)))
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
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }
}
