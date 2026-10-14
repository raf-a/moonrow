import AppKit
import Sparkle

/// Sparkle's updater: the feed and the public key come from Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`); whether it checks on its own is the user's choice, in Settings ▸ General.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!

    /// `MOONROW_FEED_URL` points the updater at another appcast, e.g. a test feed on 127.0.0.1.
    private let feedOverride = ProcessInfo.processInfo.environment["MOONROW_FEED_URL"]

    override init() {
        super.init()
        // The updater runs from the app bundle only (not `swift run`), and not under the dev
        // harnesses unless they're given a feed.
        let start = Bundle.main.bundleURL.pathExtension == "app"
            && (DevHarness.allowsSessionRestore || feedOverride != nil)
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride
    }
}
