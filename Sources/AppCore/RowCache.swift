import DBKit

/// Rows of a large result, fetched in fixed-size blocks as the grid scrolls.
///
/// The grid reports which rows are on screen; the cache loads the blocks covering them, then
/// one block past each edge, one fetch at a time, nearest-first. The number of blocks held is
/// bounded (least recently seen go first) but blocks on screen are never dropped.
@MainActor
public final class RowCache {
    public typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> [[DBValue]]

    public let rowCount: Int
    public let blockSize: Int
    public let maxBlocks: Int

    /// Called after a block arrives, with the rows it covers.
    public var onLoad: ((Range<Int>) -> Void)?
    /// Called once when a fetch fails; loading stops until a new cache is made.
    public var onError: ((any Error) -> Void)?

    private let fetch: Fetch
    private var blocks: [Int: [[DBValue]]] = [:]
    private var lastSeen: [Int: UInt64] = [:]
    private var clock: UInt64 = 0
    private var visible: Range<Int> = 0..<0
    private var loader: Task<Void, Never>?
    private var loaderID = 0
    private var failed = false

    public init(rowCount: Int, blockSize: Int = 500, maxBlocks: Int = 64, fetch: @escaping Fetch) {
        precondition(blockSize > 0 && maxBlocks > 0)
        self.rowCount = max(0, rowCount)
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
        self.fetch = fetch
    }

    /// The row, or nil while its block is loading. Nil also when the table shrank after counting.
    public func row(at index: Int) -> [DBValue]? {
        let b = index / blockSize
        guard let block = blocks[b] else { return nil }
        let i = index - b * blockSize
        return i < block.count ? block[i] : nil
    }

    public var loadedBlocks: Set<Int> { Set(blocks.keys) }
    public var isLoading: Bool { loader != nil }

    public func setVisibleRows(_ rows: Range<Int>) {
        visible = rows.clamped(to: 0..<rowCount)
        for b in visibleBlocks { touch(b) }
        startLoading()
    }

    public func cancel() {
        loader?.cancel()
        loader = nil
    }

    /// Fetches rows directly, using loaded blocks where possible. For copying a selection.
    public func rows(_ range: Range<Int>) async throws -> [[DBValue]] {
        let range = range.clamped(to: 0..<rowCount)
        let cached = range.compactMap(row(at:))
        if cached.count == range.count { return cached }
        return try await fetch(range.lowerBound, range.count)
    }

    // MARK: - Loading

    private var visibleBlocks: Range<Int> {
        guard !visible.isEmpty else { return 0..<0 }
        return (visible.lowerBound / blockSize)..<((visible.upperBound - 1) / blockSize + 1)
    }

    private func nextMissingBlock() -> Int? {
        guard !failed, !visible.isEmpty else { return nil }
        let onScreen = visibleBlocks
        let last = (rowCount - 1) / blockSize
        // On-screen blocks top to bottom, then the next one down (the usual scroll direction),
        // then the one above.
        let wanted = Array(onScreen) + [onScreen.upperBound, onScreen.lowerBound - 1]
        return wanted.first { $0 >= 0 && $0 <= last && blocks[$0] == nil }
    }

    private func startLoading() {
        guard loader == nil, nextMissingBlock() != nil else { return }
        loaderID += 1
        let id = loaderID
        loader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let b = self.nextMissingBlock() else { break }
                do {
                    let rows = try await self.fetch(b * self.blockSize, self.blockSize)
                    guard !Task.isCancelled else { break }
                    self.store(rows, block: b)
                } catch {
                    if !Task.isCancelled {
                        self.failed = true
                        self.onError?(error)
                    }
                    break
                }
            }
            if let self, self.loaderID == id { self.loader = nil }
        }
    }

    private func store(_ rows: [[DBValue]], block b: Int) {
        blocks[b] = rows
        touch(b)
        evict()
        let start = b * blockSize
        onLoad?(start..<min(start + blockSize, rowCount))
    }

    private func touch(_ b: Int) {
        clock += 1
        lastSeen[b] = clock
    }

    private func evict() {
        let excess = blocks.count - maxBlocks
        guard excess > 0 else { return }
        let onScreen = visibleBlocks
        let victims = blocks.keys
            .filter { !onScreen.contains($0) }
            .sorted { lastSeen[$0, default: 0] < lastSeen[$1, default: 0] }
            .prefix(excess)
        for b in victims {
            blocks[b] = nil
            lastSeen[b] = nil
        }
    }
}
