import AppCore
import AppKit

/// The launch window: app identity on the left, saved connections on the right, filed in
/// groups (folders) that can be collapsed, renamed and dragged into.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let store: ConnectionStore
    private unowned let app: AppDelegate

    /// The connections, as Open Connection shows them; here they can also be dragged into groups.
    let list: ConnectionList
    var outline: KeyOutlineView { list.outline }
    let search = NSSearchField()

    init(store: ConnectionStore, app: AppDelegate) {
        self.store = store
        self.app = app
        list = ConnectionList(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        // Only workspace windows merge into native tabs.
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Connections"
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("Welcome")

        list.onMove = { [weak self] ids, group in self?.move(ids, to: group) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(outline)
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let root = NSView()

        // Left: identity, New Connection, Backup and Restore.
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow

        // From Icon Services, as Finder and the Dock draw it. With the Icon Composer icon in
        // Assets.car, NSApp.applicationIconImage comes back as the generic app icon.
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let name = NSTextField(labelWithString: "Moonrow")
        name.font = .systemFont(ofSize: 26, weight: .semibold)
        let version = NSTextField(labelWithString: "Version \(Self.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let newButton = NSButton(title: "New Connection", target: nil, action: #selector(MoonrowActions.newConnection(_:)))
        let backupButton = NSButton(title: "Backup", target: nil, action: #selector(MoonrowActions.backupDatabases(_:)))
        let restoreButton = NSButton(title: "Restore", target: nil, action: #selector(MoonrowActions.restoreDatabase(_:)))
        for b in [newButton, backupButton, restoreButton] {
            b.controlSize = .large
            if #available(macOS 26.0, *) {
                b.bezelStyle = .glass
                b.borderShape = .capsule
            }
            b.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }

        let sideStack = NSStackView(views: [icon, name, version, NSView(), newButton, backupButton, restoreButton])
        sideStack.orientation = .vertical
        sideStack.alignment = .centerX
        sideStack.spacing = 8
        sideStack.setCustomSpacing(16, after: icon)
        sideStack.edgeInsets = NSEdgeInsets(top: 56, left: 20, bottom: 24, right: 20)
        side.addSubview(sideStack)
        sideStack.pin(to: side)

        // Right: search, add, the list.
        search.placeholderString = "Search names, hosts and tags"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let newGroup = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New group")!,
                                target: self, action: #selector(newGroupClicked(_:)))
        newGroup.bezelStyle = .accessoryBarAction
        newGroup.toolTip = "New group"
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New connection")!,
                           target: nil, action: #selector(MoonrowActions.newConnection(_:)))
        add.bezelStyle = .accessoryBarAction
        add.toolTip = "New connection"

        outline.target = self
        outline.doubleAction = #selector(connectClicked(_:))
        outline.menu = makeContextMenu()
        outline.onReturn = { [weak self] in self?.returnPressed() }
        outline.onDelete = { [weak self] in self?.deleteClicked(nil) }
        let scroll = list.scrollView
        // The same controls as the workspace's: the system's search field, and on macOS 26
        // glass buttons like the toolbar's.
        if #available(macOS 26.0, *) {
            for b in [newGroup, add] {
                b.bezelStyle = .glass
                // Round, as the toolbar's.
                b.borderShape = .circle
            }
        }
        let main = header(search: search, buttons: [newGroup, add], over: scroll)

        for v in [side, main] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 250),
            main.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// The search field and buttons in a row above the list.
    private func header(search: NSSearchField, buttons: [NSButton], over scroll: NSScrollView) -> NSView {
        let header = NSStackView(views: [search] + buttons)
        header.spacing = 6
        // In line with the list's selection, not its sides.
        let inset = ConnectionList.selectionInset
        header.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if #available(macOS 26.0, *) {
            // Circles as tall as the search field (they share the stack now, so they can be tied).
            for b in buttons {
                b.heightAnchor.constraint(equalTo: search.heightAnchor).isActive = true
                b.widthAnchor.constraint(equalTo: b.heightAnchor).isActive = true
            }
        }
        let main = NSStackView(views: [header, scroll])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 40, left: 16, bottom: 16, right: 16)
        header.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -32).isActive = true
        scroll.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        return main
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let c = clickedNode?.connection {
            menu.add("Connect", #selector(connectClicked(_:))).target = self
            menu.add("Edit…", #selector(editClicked(_:))).target = self
            menu.add("Duplicate", #selector(duplicateClicked(_:))).target = self
            let move = menu.add("Move to Group", nil)
            move.submenu = NSMenu(title: "Move to Group")
            for g in store.groups {
                let item = move.submenu!.add(g.name, #selector(moveToGroup(_:)))
                item.target = self
                item.representedObject = g.id
                item.state = c.groupID == g.id ? .on : .off
            }
            if !store.groups.isEmpty { move.submenu!.addItem(.separator()) }
            let none = move.submenu!.add("No Group", #selector(moveToGroup(_:)))
            none.target = self
            none.state = store.group(id: c.groupID ?? UUID()) == nil ? .on : .off
            menu.addItem(.separator())
            menu.add("Delete…", #selector(deleteClicked(_:))).target = self
            menu.addItem(.separator())
        } else if clickedNode?.group != nil {
            menu.add("Rename Group…", #selector(renameGroupClicked(_:))).target = self
            menu.add("Delete Group…", #selector(deleteClicked(_:))).target = self
            menu.addItem(.separator())
        }
        menu.add("New Group…", #selector(newGroupClicked(_:))).target = self
        menu.add("New Connection…", #selector(MoonrowActions.newConnection(_:)))
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) { list.query = search.stringValue }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Arrow keys and Return in the search field drive the list.
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            window?.makeFirstResponder(outline)
            outline.keyDown(with: NSApp.currentEvent!)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            returnPressed()
            return true
        default:
            return false
        }
    }

    /// Files connections into a group (nil: no group).
    @discardableResult
    func move(_ ids: [UUID], to group: UUID?) -> Bool {
        do {
            try store.move(ids, to: group)
            return true
        } catch {
            present(error, title: "Couldn't move the connection", in: window)
            return false
        }
    }

    // MARK: - Commands

    private var selectedNode: ConnectionList.Node? { list.selectedNode }
    private var clickedNode: ConnectionList.Node? { list.clickedNode }

    private func returnPressed() {
        guard let node = selectedNode else { return }
        if node.group != nil {
            list.toggle(node)
        } else if let c = node.connection {
            connect(c)
        }
    }

    @objc private func connectClicked(_ sender: Any?) {
        guard let node = clickedNode else { return }
        if node.group != nil, sender is NSOutlineView {
            return list.toggle(node)
        }
        guard let c = node.connection else { return }
        connect(c)
    }

    /// A connection opened here gets a window of its own (File ▸ New Window shows this window).
    func connect(_ c: ConnectionConfig) {
        app.connect(c, presentingErrorsIn: window, placement: .window)
    }

    @objc private func editClicked(_ sender: Any?) {
        guard let c = clickedNode?.connection else { return }
        app.editConnection(c, isNew: false)
    }

    @objc private func duplicateClicked(_ sender: Any?) {
        guard let c = clickedNode?.connection else { return }
        do { try app.duplicateConnection(c.id) } catch { present(error, title: "Couldn't duplicate", in: window) }
    }

    @objc private func moveToGroup(_ sender: NSMenuItem) {
        guard let c = clickedNode?.connection else { return }
        move([c.id], to: sender.representedObject as? UUID)
    }

    @objc func newGroupClicked(_ sender: Any?) {
        askName(title: "New Group", button: "Create", current: "") { [weak self] name in
            guard let self else { return }
            do {
                let group = try self.store.addGroup(named: name)
                // A selected connection outside any group goes into the new one.
                if let c = self.selectedNode?.connection, self.store.group(id: c.groupID ?? UUID()) == nil, sender is NSMenuItem {
                    self.move([c.id], to: group.id)
                }
            } catch {
                present(error, title: "Couldn't create the group", in: self.window)
            }
        }
    }

    @objc private func renameGroupClicked(_ sender: Any?) {
        guard let group = clickedNode?.group else { return }
        askName(title: "Rename Group", button: "Rename", current: group.name) { [weak self] name in
            do { try self?.store.renameGroup(group.id, to: name) } catch {
                present(error, title: "Couldn't rename the group", in: self?.window)
            }
        }
    }

    private func askName(title: String, button: String, current: String, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22)).singleLine()
        field.stringValue = current
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { done(field.stringValue) }
        }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let node = clickedNode, let window else { return }
        let alert = NSAlert()
        if let group = node.group {
            alert.messageText = "Delete the group “\(group.name)”?"
            alert.informativeText = "Its connections are kept, outside any group."
        } else if let c = node.connection {
            alert.messageText = "Delete “\(c.displayName)”?"
            alert.informativeText = "This removes the saved connection. The database itself is not touched."
        } else {
            return
        }
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                if let group = node.group {
                    try self.store.deleteGroup(group.id)
                } else if let c = node.connection {
                    try self.app.deleteConnection(c.id)
                }
            } catch {
                present(error, title: "Couldn't delete", in: self.window)
            }
        }
    }
}

extension NSView {
    /// Pins all four edges to `container`.
    func pin(to container: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }
}

extension NSWindow {
    /// Sizes the window to `content`'s fitting size, keeping its top edge where it is. A free
    /// window is then kept on its screen; a sheet stays attached to its parent.
    func fit(to content: NSView, animate: Bool = false) {
        var frame = frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: self.frame.minX, y: self.frame.maxY - frame.height)
        if sheetParent == nil { frame = constrainFrameRect(frame, to: screen) }
        setFrame(frame, display: true, animate: animate && isVisible)
    }
}
