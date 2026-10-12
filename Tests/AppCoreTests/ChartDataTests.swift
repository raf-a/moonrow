import AppCore
import DBKit
import Testing

@Suite struct ChartDataTests {
    let rows: [[DBValue]] = [
        [.text("a"), .integer(3), .text("1.5")],
        [.text("b"), .null, .text("2")],
        [.text("a"), .integer(2), .text("x")],
    ]

    @Test func numbersAndDefaultAxes() {
        #expect(ChartData.number(.text(" 2.5 ")) == 2.5)
        #expect(ChartData.number(.text("abc")) == nil)
        #expect(ChartData.number(.null) == nil)
        #expect(ChartData.number(.double(.infinity)) == nil)
        // The third column has "x", so it isn't numeric; NULLs don't count against a column.
        #expect(ChartData.numericColumns(count: 3, rows: rows) == [1])
        #expect(ChartData.defaultAxes(count: 3, rows: rows) == (0, 1))
        // Only numbers: labels are row numbers, values the first column.
        #expect(ChartData.defaultAxes(count: 2, rows: [[.integer(1), .integer(2)]]) == (nil, 0))
        #expect(ChartData.defaultAxes(count: 1, rows: [[.text("x")]]) == (0, nil))
    }

    @Test func barsKeepRowOrderAndSkipMissingValues() {
        let (points, truncated) = ChartData.points(rows: rows, label: 0, value: 1, kind: .bar)
        #expect(points == [.init("a", 3), .init("a", 2)])
        #expect(!truncated)
        let numbered = ChartData.points(rows: rows, label: nil, value: 1, kind: .line).points
        #expect(numbered.map(\.label) == ["1", "3"])
        let many = (0..<600).map { [DBValue.integer(Int64($0))] }
        let cut = ChartData.points(rows: many, label: nil, value: 0, kind: .bar)
        #expect(cut.points.count == ChartData.pointLimit && cut.truncated)
    }

    @Test func pieAddsUpLabelsAndGathersTheRest() {
        let (points, _) = ChartData.points(rows: rows, label: 0, value: 1, kind: .pie)
        #expect(points == [.init("a", 5)])
        let many = (1...14).map { [DBValue.text("s\($0)"), .integer(Int64($0))] }
        let pie = ChartData.points(rows: many, label: 0, value: 1, kind: .pie).points
        #expect(pie.count == ChartData.sliceLimit + 1)
        #expect(pie.first == .init("s14", 14))
        #expect(pie.last == .init("Other", 1 + 2 + 3))
        // Non-positive values can't be slices.
        #expect(ChartData.points(rows: [[.text("z"), .integer(-1)]], label: 0, value: 1, kind: .pie) == ([], true))
    }

    @Test func ticks() {
        #expect(ChartData.ticks(low: 0, high: 10) == [0, 2, 4, 6, 8, 10])
        #expect(ChartData.ticks(low: 0, high: 7) == [0, 2, 4, 6, 8])
        #expect(ChartData.ticks(low: -3, high: 3) == [-4, -2, 0, 2, 4])
        #expect(ChartData.ticks(low: 5, high: 5) == [5])
    }
}
