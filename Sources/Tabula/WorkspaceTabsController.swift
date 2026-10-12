import AppKit

/// Something a workspace tab shows: a table's data or a query editor.
@MainActor
protocol WorkspaceTab: NSViewController {
    /// Stays the same for the tab's life; Back / Forward find tabs by it.
    var tabID: UUID { get }
    /// The pane's preview tab: a single-clicked item that the next single click replaces.
    var isPreview: Bool { get }
    var tabItem: TabStrip.Item { get }
    /// Set by the tab container; call when `tabItem` changes.
    var onTabItemChange: (() -> Void)? { get set }
    /// Gets focus when the tab is selected.
    var preferredResponder: NSView { get }
    /// Deals with unsaved work (asking if needed), then calls `proceed` if the tab may close.
    func prepareToClose(then proceed: @escaping () -> Void)
    /// The tab is gone: stop loading and running.
    func tabDidClose()
}

extension WorkspaceTab {
    var isPreview: Bool { false }
}

/// One pane of the workspace: a strip of tabs on top, the selected tab's view below.
@MainActor
final class WorkspaceTabsController: NSViewController {
    let strip = TabStrip()
    private let container = NSView()
    private let placeholder = NSTextField(labelWithString: "Open a table from the sidebar, or press ⌘T for a new query")
    private(set) var tabs: [any WorkspaceTab] = []
    private(set) var selectedIndex: Int?
    /// After the selected tab changes (or its title does).
    var onSelectionChange: (() -> Void)?
    /// The + button.
    var onNewTab: (() -> Void)?
    /// A double-click on a tab.
    var onDoubleClickTab: ((Int) -> Void)?
    /// After the last tab closed.
    var onEmpty: (() -> Void)?

    var current: (any WorkspaceTab)? { selectedIndex.map { tabs[$0] } }

    override func loadView() {
        strip.onSelect = { [weak self] i in self?.select(i) }
        strip.onClose = { [weak self] i in self?.close(i) }
        strip.onAdd = { [weak self] in self?.onNewTab?() }
        strip.onDoubleClick = { [weak self] i in self?.onDoubleClickTab?(i) }
        strip.addToolTip = "New query tab (⌘T)"
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 14)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for v in [strip, container, placeholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // The window's content runs under the toolbar; start below it.
            strip.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = root
    }

    func add(_ tab: any WorkspaceTab, at index: Int? = nil, focus: Bool = true) {
        let i = min(index ?? tabs.count, tabs.count)
        tabs.insert(tab, at: i)
        addChild(tab)
        tab.onTabItemChange = { [weak self] in
            self?.updateStrip()
            self?.onSelectionChange?()
        }
        select(i, force: true, focus: focus)
    }

    /// Swaps the tab at `index` for `tab` (a table tab opening another table).
    func replace(at index: Int, with tab: any WorkspaceTab, focus: Bool = true) {
        let old = tabs[index]
        old.tabDidClose()
        old.view.removeFromSuperview()
        old.removeFromParent()
        tabs.remove(at: index)
        if selectedIndex == index { selectedIndex = nil }
        add(tab, at: index, focus: focus)
    }

    /// Selects the tab and gives it the focus (`focus`, when the pane is the active one).
    func select(_ index: Int, force: Bool = false, focus: Bool = true) {
        guard index >= 0, index < tabs.count else { return }
        if index == selectedIndex, !force { return }
        current?.view.removeFromSuperview()
        selectedIndex = index
        let tab = tabs[index]
        container.addSubview(tab.view)
        tab.view.translatesAutoresizingMaskIntoConstraints = false
        tab.view.pin(to: container)
        placeholder.isHidden = true
        updateStrip()
        if focus { view.window?.makeFirstResponder(tab.preferredResponder) }
        onSelectionChange?()
    }

    func index(of tab: any WorkspaceTab) -> Int? { tabs.firstIndex { $0 === tab } }

    /// Closes the tab once it agrees to (staged edits get resolved first).
    func close(_ index: Int) {
        guard index < tabs.count else { return }
        let tab = tabs[index]
        tab.prepareToClose { [weak self, weak tab] in
            guard let self, let tab, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.remove(at: i)
        }
    }

    private func remove(at index: Int) {
        let tab = tabs.remove(at: index)
        tab.tabDidClose()
        tab.view.removeFromSuperview()
        tab.removeFromParent()
        if let s = selectedIndex {
            if s == index {
                selectedIndex = nil
                // Like most tabbed apps: the tab to the right, else the one to the left.
                if !tabs.isEmpty { return select(min(index, tabs.count - 1), force: true, focus: isActive) }
            } else if s > index {
                selectedIndex = s - 1
            }
        }
        placeholder.isHidden = !tabs.isEmpty
        updateStrip()
        onSelectionChange?()
        if tabs.isEmpty { onEmpty?() }
    }

    /// The pane the window's commands go to. Only its selected tab gets the accent line.
    var isActive = true {
        didSet { if isViewLoaded { strip.isActive = isActive } }
    }

    /// Stops every tab without asking. For a closing window.
    func closeAll() {
        for tab in tabs { tab.tabDidClose() }
    }

    func selectNext(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let i = ((selectedIndex ?? 0) + delta + tabs.count) % tabs.count
        select(i)
    }

    /// Redraws tab titles (a staged new table was renamed, say).
    func refreshTabItems() { updateStrip() }

    private func updateStrip() {
        guard isViewLoaded else { return }
        strip.items = tabs.map(\.tabItem)
        strip.selectedIndex = selectedIndex
    }
}
