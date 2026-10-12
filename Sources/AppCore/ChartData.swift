import DBKit
import Foundation

/// A result's rows as chart points: one column for the labels (or the row number), one numeric
/// column for the values. Our own small design: bar, line and pie, no aggregation except that a
/// pie adds up equal labels.
public enum ChartData {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case bar, line, pie

        public var title: String {
            switch self {
            case .bar: "Bar"
            case .line: "Line"
            case .pie: "Pie"
            }
        }
    }

    public struct Point: Sendable, Hashable {
        public var label: String
        public var value: Double

        public init(_ label: String, _ value: Double) {
            self.label = label
            self.value = value
        }
    }

    /// Most bars or line points drawn; the rest are left out (and the chart says so).
    public static let pointLimit = 500
    /// Pie slices before the rest is added up as "Other".
    public static let sliceLimit = 11

    /// A cell as a number: integers, floating point, and text that reads as a number (Postgres
    /// sends `numeric` as text). Nil for anything else, NULL included.
    public static func number(_ value: DBValue) -> Double? {
        switch value {
        case .integer(let n): return Double(n)
        case .double(let d): return d.isFinite ? d : nil
        case .text(let s): return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// Columns whose values (the first 1,000 rows, NULLs aside) are all numbers, with at least one.
    public static func numericColumns(count: Int, rows: [[DBValue]]) -> [Int] {
        let sample = rows.prefix(1000)
        return (0..<count).filter { c in
            var any = false
            for row in sample where c < row.count && !row[c].isNull {
                guard number(row[c]) != nil else { return false }
                any = true
            }
            return any
        }
    }

    /// The first column that isn't numeric labels the points (nil: the row number); the first
    /// numeric column other than that gives the values.
    public static func defaultAxes(count: Int, rows: [[DBValue]]) -> (label: Int?, value: Int?) {
        let numeric = numericColumns(count: count, rows: rows)
        let label = (0..<count).first { !numeric.contains($0) }
        return (label, numeric.first { $0 != label })
    }

    /// Points in row order for bars and lines, skipping rows without a number; for a pie,
    /// positive values added up per label, largest first, the smallest beyond `sliceLimit`
    /// gathered as "Other". `truncated` tells that rows were left out.
    public static func points(rows: [[DBValue]], label: Int?, value: Int, kind: Kind) -> (points: [Point], truncated: Bool) {
        func name(_ row: [DBValue], _ i: Int) -> String {
            guard let label, label < row.count else { return String(i + 1) }
            return row[label].isNull ? "NULL" : CellText.display(row[label]) ?? ""
        }
        var points: [Point] = []
        var truncated = false
        for (i, row) in rows.enumerated() {
            guard value < row.count, let v = number(row[value]) else { continue }
            if kind != .pie, points.count == pointLimit {
                truncated = true
                break
            }
            points.append(Point(name(row, i), v))
        }
        guard kind == .pie else { return (points, truncated) }
        var sums: [String: Double] = [:]
        var order: [String] = []
        for p in points where p.value > 0 {
            if sums[p.label] == nil { order.append(p.label) }
            sums[p.label, default: 0] += p.value
        }
        var slices = order.map { Point($0, sums[$0]!) }.sorted { $0.value > $1.value }
        if slices.count > sliceLimit + 1 {
            let rest = slices[sliceLimit...].reduce(0) { $0 + $1.value }
            slices = Array(slices.prefix(sliceLimit)) + [Point("Other", rest)]
        }
        return (slices, points.contains { $0.value <= 0 })
    }

    /// Round tick values covering `low...high`, about `count` of them.
    public static func ticks(low: Double, high: Double, count: Int = 5) -> [Double] {
        guard high > low, count > 0 else { return [low] }
        let raw = (high - low) / Double(count)
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        var out: [Double] = []
        var t = floor(low / step) * step
        while t <= high + step * 0.001 {
            out.append(abs(t) < step * 1e-9 ? 0 : t)
            t += step
        }
        if let last = out.last, last < high { out.append(last + step) }
        return out
    }
}
