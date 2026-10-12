import AppCore
import AppKit

/// Where a chosen connection's workspace goes.
enum WorkspacePlacement {
    /// A tab of the frontmost workspace window (a window of its own if there is none).
    case tab
    /// A window of its own.
    case window
}

/// Open Connection (⇧⌘K): the saved connections, listed as on the welcome window
/// (`ConnectionList`), to open one as a tab. A sheet on the workspace window, or a window of its
/// own when no workspace is open. Return or a double-click connects; the context menu picks a new
/// tab or a new window.
@MainActor
final class ConnectionPicker: NSObject, NSSearchFieldDelegate, NSMenuDelegate, NSWindowDelegate {
    let window: NSWindow
    let search = NSSearchField()
    let list: ConnectionList
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    /// What Return, the Connect button and a double-click do.
    let placement: WorkspacePlacement

    /// The connection chosen, and where it goes.
    var onConnect: ((ConnectionConfig, WorkspacePlacement) -> Void)?
    var onNewConnection: (() -> Void)?
    var onEdit: ((ConnectionConfig) -> Void)?
    var onClose: (() -> Void)?

    init(store: ConnectionStore, title: String, placement: WorkspacePlacement) {
        self.placement = placement
        list = ConnectionList(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500), styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = title
        // The heading inside says it; as a free-standing window the title bar stays empty.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = makeContent(title: title)
        list.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.connectButton.isEnabled = self.list.selectedConnection != nil
        }
        connectButton.isEnabled = list.selectedConnection != nil
    }

    private func makeContent(title: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center

        search.placeholderString = "Search names, hosts and tags"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let outline = list.outline
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onReturn = { [weak self] in self?.connect(nil) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let new = NSButton(title: "New Connection…", target: self, action: #selector(newConnection(_:)))
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, NSView(), new, connectButton])
        buttons.spacing = 8

        let scroll = list.scrollView
        let stack = NSStackView(views: [heading, search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [search, scroll, buttons, heading] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return stack
    }

    /// As a sheet on `parent`, or as a window of its own.
    func show(on parent: NSWindow?) {
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(search)
    }

    func close() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        onClose?()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    var selected: ConnectionConfig? { list.selectedConnection }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) { list.query = search.stringValue }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            // The arrows move in the list while typing goes on in the field.
            if let event = NSApp.currentEvent { list.outline.keyDown(with: event) }
        case #selector(NSResponder.insertNewline(_:)): connect(nil)
        case #selector(NSResponder.cancelOperation(_:)): cancel(nil)
        default: return false
        }
        return true
    }

    // MARK: - Commands

    @objc private func doubleClicked() {
        guard let node = list.outline.item(atRow: list.outline.clickedRow) as? ConnectionList.Node else { return }
        if let c = node.connection { choose(c, placement) } else { list.toggle(node) }
    }

    /// Return or Connect: the selected connection; on a group, opens or closes it.
    @objc func connect(_ sender: Any?) {
        guard let node = list.selectedNode else { return NSSound.beep() }
        if let c = node.connection { choose(c, placement) } else { list.toggle(node) }
    }

    private func choose(_ c: ConnectionConfig, _ placement: WorkspacePlacement) {
        close()
        onConnect?(c, placement)
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc private func newConnection(_ sender: Any?) {
        close()
        onNewConnection?()
    }

    private var clicked: ConnectionConfig? { list.clickedNode?.connection }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clicked != nil else { return }
        menu.add("Connect in New Tab", #selector(connectInNewTab(_:))).target = self
        menu.add("Connect in New Window", #selector(connectInNewWindow(_:))).target = self
        menu.addItem(.separator())
        menu.add("Edit…", #selector(edit(_:))).target = self
    }

    @objc private func connectInNewTab(_ sender: Any?) { if let c = clicked { choose(c, .tab) } }
    @objc private func connectInNewWindow(_ sender: Any?) { if let c = clicked { choose(c, .window) } }

    @objc private func edit(_ sender: Any?) {
        guard let c = clicked else { return }
        close()
        onEdit?(c)
    }
}
