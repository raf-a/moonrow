import DBKit

/// Where a table, view or saved query opens among a pane's tabs, VS Code style: a single click
/// opens it in the pane's preview tab (at most one, shown in italics), which the next single
/// click replaces; a double-click, Quick Open or "Open in New Tab" opens a regular tab.
public enum TabPlacement {
    /// What a pane's tab shows, as far as placement cares.
    public struct Tab: Sendable, Hashable {
        /// Nil for query tabs and staged new tables: they never take an object.
        public var object: DatabaseObject?
        /// The saved query a query tab shows (its path), if any.
        public var savedQuery: String?
        public var isPreview: Bool

        public init(object: DatabaseObject?, savedQuery: String? = nil, isPreview: Bool = false) {
            self.object = object
            self.savedQuery = savedQuery
            self.isPreview = isPreview
        }
    }

    public enum Decision: Sendable, Hashable {
        /// A tab already shows the object.
        case select(Int)
        /// The preview tab shows the object; it becomes a regular tab.
        case promote(Int)
        /// The preview tab shows something else and now shows the object.
        case replacePreview(Int)
        /// A new tab at this index.
        case insert(at: Int, preview: Bool)
    }

    public enum Intent: Sendable, Hashable {
        /// A single click in the sidebar, or back / forward to a closed tab.
        case preview
        /// A double-click, Quick Open, Open Structure.
        case regular
        /// "Open in New Tab": always another regular tab.
        case newTab
    }

    public static func place(_ object: DatabaseObject, intent: Intent, in tabs: [Tab], selected: Int?) -> Decision {
        place(intent: intent, in: tabs, selected: selected) { $0.object == object }
    }

    /// A saved query, by its path.
    public static func place(savedQuery path: String, intent: Intent, in tabs: [Tab], selected: Int?) -> Decision {
        place(intent: intent, in: tabs, selected: selected) { $0.savedQuery == path }
    }

    private static func place(intent: Intent, in tabs: [Tab], selected: Int?, shows: (Tab) -> Bool) -> Decision {
        // New tabs go to the right of the selected tab, else at the end.
        let next = selected.map { min($0 + 1, tabs.count) } ?? tabs.count
        if intent == .newTab { return .insert(at: next, preview: false) }
        // A regular tab is preferred over the preview tab.
        if let i = tabs.firstIndex(where: { shows($0) && !$0.isPreview }) { return .select(i) }
        if let i = tabs.firstIndex(where: { shows($0) && $0.isPreview }) {
            return intent == .regular ? .promote(i) : .select(i)
        }
        if intent == .preview, let i = tabs.firstIndex(where: \.isPreview) { return .replacePreview(i) }
        return .insert(at: next, preview: intent == .preview)
    }
}
