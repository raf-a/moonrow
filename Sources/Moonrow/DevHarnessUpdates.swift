import AppKit

extension DevHarness {
    /// `MOONROW_UPDATE=install` with `MOONROW_FEED_URL`: checks the feed and presses Sparkle's
    /// Install Update, then Install and Relaunch, as each appears. Each step stays on screen for
    /// a few seconds first and is snapshotted into `MOONROW_SNAPSHOTS` when it's set. Sparkle
    /// replaces the app and relaunches it, so run it on a copy. `MOONROW_UPDATE=check` stops at
    /// the update window, to look at its release notes.
    static func updateDemo(_ app: AppDelegate, install: Bool, snapshots: URL?) async throws {
        guard ProcessInfo.processInfo.environment["MOONROW_FEED_URL"] != nil else {
            throw HarnessError("MOONROW_UPDATE needs MOONROW_FEED_URL")
        }
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        let updater = app.updates.updater
        _ = try await waitFor("the updater", seconds: 15) { updater.canCheckForUpdates ? true : nil }
        app.checkForUpdates(nil)
        guard install else { return }
        for (step, title) in ["Install Update", "Install and Relaunch"].enumerated() {
            let button = try await waitFor("“\(title)”", seconds: 60) { enabledButton(titled: title) }
            print("update: \(title)")
            try await Task.sleep(for: .seconds(3))
            if let snapshots, let window = button.window {
                snapshot(window, to: snapshots.appending(path: "update-\(step + 1).png"))
            }
            button.performClick(nil)
        }
    }

    private static func enabledButton(titled title: String) -> NSButton? {
        func search(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title, button.isEnabled, !button.isHiddenOrHasHiddenAncestor {
                return button
            }
            return view.subviews.lazy.compactMap(search).first
        }
        // Hidden apps' windows aren't visible, so every window is searched.
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(search) }.first
    }
}
