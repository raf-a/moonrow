/// Back / Forward over the places a window showed, like a browser's history. Visiting a place
/// drops the forward list. Going back or forward skips places that are gone (a closed query tab,
/// say), and drops them.
public struct NavigationHistory<Place: Hashable & Sendable>: Sendable {
    public private(set) var backList: [Place] = []
    public private(set) var forwardList: [Place] = []
    public private(set) var current: Place?
    /// Older places are forgotten past this many.
    public var limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public var canGoBack: Bool { !backList.isEmpty }
    public var canGoForward: Bool { !forwardList.isEmpty }

    /// Records `place` as shown. Showing the current place again records nothing.
    public mutating func visit(_ place: Place) {
        guard place != current else { return }
        if let current { backList.append(current) }
        if backList.count > limit { backList.removeFirst(backList.count - limit) }
        forwardList.removeAll()
        current = place
    }

    /// The latest earlier place that `isValid` accepts, which becomes current; nil if none.
    public mutating func goBack(where isValid: (Place) -> Bool = { _ in true }) -> Place? {
        while let place = backList.popLast() {
            guard isValid(place) else { continue }
            if let current { forwardList.append(current) }
            current = place
            return place
        }
        return nil
    }

    /// The next later place that `isValid` accepts, which becomes current; nil if none.
    public mutating func goForward(where isValid: (Place) -> Bool = { _ in true }) -> Place? {
        while let place = forwardList.popLast() {
            guard isValid(place) else { continue }
            if let current { backList.append(current) }
            current = place
            return place
        }
        return nil
    }

    /// The place now shown stands for the current one (a closed tab reopened as a new tab).
    public mutating func replaceCurrent(with place: Place) {
        current = place
        if backList.last == place { backList.removeLast() }
        if forwardList.last == place { forwardList.removeLast() }
    }

    /// Forgets places that no longer exist (a committed drop, say).
    public mutating func removeAll(where gone: (Place) -> Bool) {
        backList.removeAll(where: gone)
        forwardList.removeAll(where: gone)
        if let current, gone(current) { self.current = nil }
        // Removing can leave the same place twice in a row.
        backList = backList.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        if let current, backList.last == current { backList.removeLast() }
    }
}
