import AppKit

@main
@MainActor
enum MoonrowMain {
    // NSApplication holds its delegate weakly.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Needed when run as a bare executable (`swift run Moonrow`) rather than from the bundle.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
