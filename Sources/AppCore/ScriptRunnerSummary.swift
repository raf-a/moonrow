import Foundation

extension ScriptRunner {
    /// The line a run ends with: how many of its statements ran, which one failed, whether it was
    /// stopped, and how long it took. "3 of 5 statements ran · statement 3 failed · 8 ms"
    public struct Summary: Sendable, Hashable {
        public var total: Int
        /// Statements that started, the failed or stopped one included.
        public var ran: Int
        /// Index of the first statement that failed.
        public var failed: Int?
        public var stopped: Bool
        public var duration: Duration

        public init(total: Int, ran: Int, failed: Int? = nil, stopped: Bool = false, duration: Duration) {
            self.total = total
            self.ran = ran
            self.failed = failed
            self.stopped = stopped
            self.duration = duration
        }

        public func text(locale: Locale = .autoupdatingCurrent) -> String {
            let statements = "\(total.formatted(.number.locale(locale))) statement\(total == 1 ? "" : "s")"
            var parts = [ran < total ? "\(ran.formatted(.number.locale(locale))) of \(statements) ran" : statements]
            if let failed { parts.append("statement \((failed + 1).formatted(.number.locale(locale))) failed") }
            if stopped { parts.append("stopped") }
            parts.append(DurationText.string(duration, locale: locale))
            return parts.joined(separator: " · ")
        }
    }
}

/// How long a statement or a run took, the same everywhere: a decimal under 10 ms (so a quick
/// statement never reads "0 ms"), whole milliseconds under a second, seconds with two decimals
/// under a minute, then minutes and seconds.
public enum DurationText {
    public static func string(_ d: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        let ms = max(0, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        func number(_ value: Double, decimals: Int) -> String {
            value.formatted(.number.precision(.fractionLength(decimals)).locale(locale))
        }
        if ms < 0.05 { return "< \(number(0.1, decimals: 1)) ms" }
        if ms < 9.95 { return "\(number(ms, decimals: 1)) ms" }
        if ms < 999.5 { return "\(number(ms, decimals: 0)) ms" }
        if ms < 59_995 { return "\(number(ms / 1000, decimals: 2)) s" }
        let rounded = Duration.seconds((ms / 1000).rounded())
        return rounded.formatted(.time(pattern: ms < 3_600_000 ? .minuteSecond : .hourMinuteSecond).locale(locale))
    }
}
