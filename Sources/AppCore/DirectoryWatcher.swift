import CoreServices
import Foundation

/// Calls back on the main queue when anything changes inside a directory (its subdirectories
/// included), through FSEvents. Changes that come close together arrive as one call.
@MainActor
public final class DirectoryWatcher {
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    /// Watches nothing when the stream can't be created.
    public init(_ directory: URL, latency: TimeInterval = 0.2, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { watcher.onChange() }
        }
        // FSEvents reports real paths: /var/folders/… is /private/var/folders/….
        let path = directory.resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
