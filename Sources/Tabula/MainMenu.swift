import AppKit

/// Actions sent through the responder chain (nil target). Implemented by whichever window
/// controller or the app delegate handles them.
@MainActor @objc protocol TabulaActions {
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func showConnections(_ sender: Any?)
    @objc optional func reloadWorkspace(_ sender: Any?)
    @objc optional func focusItemFilter(_ sender: Any?)
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
            m.add("Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            m.addItem(.separator())
            m.add("Close", #selector(NSWindow.performClose(_:)), "w")
        }

        main.addSubmenu("Edit") { m in
            m.add("Undo", Selector(("undo:")), "z")
            m.add("Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            m.add("Cut", #selector(NSText.cut(_:)), "x")
            m.add("Copy", #selector(NSText.copy(_:)), "c")
            m.add("Paste", #selector(NSText.paste(_:)), "v")
            m.add("Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            m.add("Filter Items", #selector(TabulaActions.focusItemFilter(_:)), "f", [.command, .shift])
        }

        main.addSubmenu("View") { m in
            m.add("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "0")
            m.addItem(.separator())
            m.add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        main.addSubmenu("Connection") { m in
            m.add("Reload", #selector(TabulaActions.reloadWorkspace(_:)), "r")
            m.addItem(.separator())
            m.add("Show Connections", #selector(TabulaActions.showConnections(_:)), "k", [.command, .shift])
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
