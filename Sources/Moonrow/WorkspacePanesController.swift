import AppKit

/// The workspace's panes side by side, each a `WorkspaceTabsController` with its own tab strip.
/// Split Pane Right (⇧⌘D) adds one; a pane whose last tab closes goes away, unless it's the
/// only one. The active pane takes the window's commands; a click anywhere in a pane makes it
/// the active one.
@MainActor
final class WorkspacePanesController: NSViewController, NSSplitViewDelegate {
    private let split = NSSplitView()
    private(set) var panes: [WorkspaceTabsController] = []
    private(set) var activeIndex = 0
    /// Called for every new pane, before it gets tabs.
    var onNewPane: ((WorkspaceTabsController) -> Void)?
    /// After the active pane changes.
    var onActivate: (() -> Void)?
    private var clickMonitor: Any?

    var active: WorkspaceTabsController { panes[activeIndex] }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        view = split
        addPane(at: 0)
        // A click in a pane activates it; the click itself goes on as usual.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.clicked(event) }
            return event
        }
    }

    /// Stops watching clicks. For a closing window.
    func tearDown() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func clicked(_ event: NSEvent) {
        guard event.window === view.window, panes.count > 1 else { return }
        let point = split.convert(event.locationInWindow, from: nil)
        if let i = panes.firstIndex(where: { $0.view.frame.contains(point) }), i != activeIndex {
            activate(i, focus: false)
        }
    }

    /// A new, empty pane at `index` (to the right of the active one by default), made active.
    @discardableResult
    func addPane(at index: Int? = nil) -> WorkspaceTabsController {
        let i = min(index ?? activeIndex + 1, panes.count)
        let pane = WorkspaceTabsController()
        onNewPane?(pane)
        pane.onEmpty = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.removeIfEmpty(pane)
        }
        panes.insert(pane, at: i)
        addChild(pane)
        split.insertArrangedSubview(pane.view, at: i)
        pane.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        equalizeWidths()
        activate(i, focus: false)
        return pane
    }

    /// Removes an empty pane, unless it's the last one.
    private func removeIfEmpty(_ pane: WorkspaceTabsController) {
        guard pane.tabs.isEmpty, panes.count > 1, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        remove(at: i)
    }

    /// Closes a pane without asking (its tabs are stopped); the one to its left becomes active.
    func remove(at i: Int) {
        guard panes.count > 1, panes.indices.contains(i) else { return }
        let pane = panes.remove(at: i)
        pane.closeAll()
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        equalizeWidths()
        let next = min(max(0, i - 1), panes.count - 1)
        activeIndex = -1
        activate(next, focus: true)
    }

    /// Makes the pane at `i` active; `focus` moves the keyboard focus into its selected tab.
    func activate(_ i: Int, focus: Bool) {
        guard panes.indices.contains(i) else { return }
        let changed = i != activeIndex
        activeIndex = i
        for (n, pane) in panes.enumerated() { pane.isActive = n == i || panes.count == 1 }
        if focus { view.window?.makeFirstResponder(panes[i].current?.preferredResponder ?? panes[i].strip) }
        if changed { onActivate?() }
    }

    /// The pane showing `tab`.
    func pane(of tab: any WorkspaceTab) -> WorkspaceTabsController? {
        panes.first { $0.index(of: tab) != nil }
    }

    func index(of pane: WorkspaceTabsController) -> Int? { panes.firstIndex { $0 === pane } }

    /// Every tab of every pane, left to right.
    var allTabs: [any WorkspaceTab] { panes.flatMap(\.tabs) }

    private func equalizeWidths() {
        guard panes.count > 1 else { return }
        split.layoutSubtreeIfNeeded()
        let width = (split.bounds.width - split.dividerThickness * CGFloat(panes.count - 1)) / CGFloat(panes.count)
        for i in 0..<(panes.count - 1) {
            split.setPosition(width * CGFloat(i + 1) + split.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(proposed, splitView.arrangedSubviews[i].frame.minX + 260)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(proposed, splitView.arrangedSubviews[i + 1].frame.maxX - 260)
    }
}
