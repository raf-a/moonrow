import AppCore
import AppKit
import Darwin

/// Developer self-check, off unless `TABULA_BENCH` names a table:
///
///     TABULA_BENCH=events TABULA_SNAPSHOTS=build/snapshots Tabula build/sample.sqlite
///
/// Opens the table in the first workspace, scrolls it like a fast trackpad, jumps to far-apart
/// rows, prints timings and quits. Snapshots are rendered in-process (no screen-recording
/// permission needed).
@MainActor
enum DevHarness {
    static func runIfRequested(_ app: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        let snapshots = env["TABULA_SNAPSHOTS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        guard let table = env["TABULA_BENCH"] else {
            if let snapshots { snapshotWindowsAndQuit(to: snapshots) }
            return
        }
        Task {
            do {
                try await run(app, table: table, snapshots: snapshots)
            } catch {
                print("bench failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    /// With only `TABULA_SNAPSHOTS` set: renders every visible window once launched, then quits.
    private static func snapshotWindowsAndQuit(to dir: URL) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                let name = window.title.isEmpty ? "window" : window.title
                snapshot(window, to: dir.appending(path: "\(i)-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func run(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        if let snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snap(_ name: String, _ window: NSWindow) {
            if let snapshots { snapshot(window, to: snapshots.appending(path: name)) }
        }

        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let data = try await waitFor("table view") { workspace.content.tableController }
        let cache = try await waitFor("row count") { data.cache }
        let grid = data.grid
        _ = try await waitFor("first rows") { visibleLoaded(grid, cache) ? true : nil }
        snap("1-top.png", window)
        print("rows: \(cache.rowCount), columns: \(grid.numberOfColumns), visible rows: \(grid.rows(in: grid.visibleRect).length)")

        let scroll = try require(grid.enclosingScrollView, "scroll view")
        let clip = scroll.contentView
        let clock = ContinuousClock()

        // Continuous scrolling: 3 rows per 60 Hz frame, 10 seconds' worth.
        var frames: [Double] = []
        var pendingFrames = 0
        for _ in 0..<600 {
            let d = clock.measure {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 3 * grid.rowHeight))
                scroll.reflectScrolledClipView(clip)
                window.displayIfNeeded()
            }
            frames.append(d.ms)
            if !visibleLoaded(grid, cache) { pendingFrames += 1 }
            try await Task.sleep(for: .milliseconds(16))
        }
        frames.sort()
        print(String(format: "scroll 600 frames: p50 %.2f ms, p95 %.2f ms, max %.2f ms; frames with unloaded rows on screen: %d",
                     frames[300], frames[570], frames[599], pendingFrames))

        // Jumps, like dragging the scroller thumb: time until every visible row has data.
        let n = cache.rowCount
        for target in [n / 2, n - 1, n / 8, 0, n * 7 / 9, n - 1].filter({ $0 >= 0 }) {
            let start = clock.now
            let draw = clock.measure {
                grid.scrollRowToVisible(target)
                window.displayIfNeeded()
            }
            _ = try await waitFor("rows at \(target)") { visibleLoaded(grid, cache) ? true : nil }
            window.displayIfNeeded()
            print(String(format: "jump to row %7d: drawn in %.2f ms, data on screen after %.1f ms",
                         target, draw.ms, (clock.now - start).ms))
        }
        snap("2-bottom.png", window)
        print("blocks held: \(cache.loadedBlocks.count) (max \(cache.maxBlocks)), resident memory: \(residentMB()) MB")
    }

    private static func visibleLoaded(_ grid: NSTableView, _ cache: RowCache) -> Bool {
        let r = grid.rows(in: grid.visibleRect)
        guard r.length > 0 else { return true }
        return cache.row(at: r.location) != nil && cache.row(at: min(cache.rowCount - 1, r.location + r.length - 1)) != nil
    }

    private static func waitFor<T>(_ what: String, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(15)
        while true {
            if let value = probe() { return value }
            guard Date() < deadline else { throw HarnessError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw HarnessError("no \(what)") }
        return value
    }

    /// Renders the window's frame view, toolbar included.
    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : -1
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Duration {
    fileprivate var ms: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
