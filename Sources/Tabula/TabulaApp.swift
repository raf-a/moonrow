import AppKit

@main
@MainActor
enum TabulaMain {
    // NSApplication holds its delegate weakly.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Needed when run as a bare executable (`swift run Tabula`) rather than from the bundle.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
