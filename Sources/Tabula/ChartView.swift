import AppCore
import AppKit
import DBKit

/// A result as a bar, line or pie chart (`ChartData`): popups for the kind, the label column
/// and the value column over the drawing.
@MainActor
final class ChartViewController: NSViewController {
    private let columns: [ResultColumn]
    private let rows: () -> [[DBValue]]
    private let kindPopup = NSPopUpButton()
    private let labelPopup = NSPopUpButton()
    private let valuePopup = NSPopUpButton()
    private let note = NSTextField(labelWithString: "")
    let chart = ChartCanvas()
    private var numeric: [Int] = []

    init(columns: [ResultColumn], rows: @escaping () -> [[DBValue]]) {
        self.columns = columns
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        kindPopup.addItems(withTitles: ChartData.Kind.allCases.map(\.title))
        for p in [kindPopup, labelPopup, valuePopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.action = #selector(changed(_:))
        }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [NSTextField(labelWithString: "Chart"), kindPopup, NSTextField(labelWithString: "Labels"),
                                      labelPopup, NSTextField(labelWithString: "Values"), valuePopup, note])
        for case let label as NSTextField in bar.arrangedSubviews where label !== note {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        for v in [bar, chart] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            chart.topAnchor.constraint(equalTo: bar.bottomAnchor),
            chart.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chart.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refreshColumns()
    }

    /// Fills the column popups from the rows so far; keeps choices that still apply.
    func refreshColumns() {
        guard isViewLoaded else { return }
        let rows = rows()
        numeric = ChartData.numericColumns(count: columns.count, rows: rows)
        let keepLabel = labelPopup.numberOfItems > 0 ? labelPopup.selectedTag() : nil
        let keepValue = valuePopup.numberOfItems > 0 ? valuePopup.selectedTag() : nil
        let axes = ChartData.defaultAxes(count: columns.count, rows: rows)
        labelPopup.removeAllItems()
        labelPopup.addItem(withTitle: "Row number")
        labelPopup.lastItem?.tag = -1
        for (i, c) in columns.enumerated() {
            labelPopup.addItem(withTitle: c.name)
            labelPopup.lastItem?.tag = i
        }
        valuePopup.removeAllItems()
        for i in numeric {
            valuePopup.addItem(withTitle: columns[i].name)
            valuePopup.lastItem?.tag = i
        }
        labelPopup.selectItem(withTag: keepLabel ?? axes.label ?? -1)
        if let v = keepValue.flatMap({ numeric.contains($0) ? $0 : nil }) ?? axes.value { valuePopup.selectItem(withTag: v) }
        valuePopup.isEnabled = !numeric.isEmpty
        redraw()
    }

    @objc private func changed(_ sender: Any?) { redraw() }

    private func redraw() {
        let kind = ChartData.Kind.allCases[max(0, kindPopup.indexOfSelectedItem)]
        guard !numeric.isEmpty, valuePopup.selectedTag() >= 0 else {
            chart.show([], kind: kind)
            note.stringValue = "No column holds numbers."
            return
        }
        let label = labelPopup.selectedTag() >= 0 ? labelPopup.selectedTag() : nil
        let (points, truncated) = ChartData.points(rows: rows(), label: label, value: valuePopup.selectedTag(), kind: kind)
        chart.show(points, kind: kind)
        note.stringValue = !truncated ? "" : kind == .pie ? "Zero and negative values are left out."
            : "The first \(ChartData.pointLimit.formatted()) points are shown."
    }

    /// For the dev harness.
    func select(kind: ChartData.Kind) {
        kindPopup.selectItem(at: ChartData.Kind.allCases.firstIndex(of: kind) ?? 0)
        redraw()
    }
}

/// Draws chart points. Bars and lines get a value axis with round ticks; a pie gets a legend.
final class ChartCanvas: NSView {
    private(set) var points: [ChartData.Point] = []
    private(set) var kind = ChartData.Kind.bar
    private static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal,
        .systemYellow, .systemRed, .systemIndigo, .systemBrown, .systemMint, .systemGray,
    ]
    private static let font = NSFont.systemFont(ofSize: 10)

    func show(_ points: [ChartData.Point], kind: ChartData.Kind) {
        self.points = points
        self.kind = kind
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard !points.isEmpty else { return }
        if kind == .pie { drawPie() } else { drawAxes() }
    }

    private func text(_ s: String, at p: NSPoint, align: NSTextAlignment = .left, color: NSColor = .secondaryLabelColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        var origin = p
        if align == .right { origin.x -= size.width }
        if align == .center { origin.x -= size.width / 2 }
        (s as NSString).draw(at: origin, withAttributes: attrs)
    }

    private static func format(_ v: Double) -> String {
        abs(v) >= 1e6 || (abs(v) < 1e-3 && v != 0) ? String(format: "%.3g", v)
            : v.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func drawAxes() {
        let values = points.map(\.value)
        let ticks = ChartData.ticks(low: min(0, values.min()!), high: max(0, values.max()!))
        let low = ticks.first!, high = ticks.last! == low ? low + 1 : ticks.last!
        let labelWidth = ticks.map { (Self.format($0) as NSString).size(withAttributes: [.font: Self.font]).width }.max()! + 8
        let plot = NSRect(x: bounds.minX + labelWidth + 4, y: bounds.minY + 22, width: bounds.width - labelWidth - 16, height: bounds.height - 34)
        guard plot.width > 20, plot.height > 20 else { return }
        func y(_ v: Double) -> CGFloat { plot.minY + CGFloat((v - low) / (high - low)) * plot.height }
        NSColor.separatorColor.setStroke()
        for t in ticks {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y(t)))
            line.line(to: NSPoint(x: plot.maxX, y: y(t)))
            line.lineWidth = t == 0 ? 1 : 0.5
            line.stroke()
            text(Self.format(t), at: NSPoint(x: plot.minX - 6, y: y(t) - 6), align: .right)
        }
        let step = plot.width / CGFloat(points.count)
        // Labels: as many as fit without overlapping.
        let every = max(1, Int(ceil(70 / step)))
        for (i, p) in points.enumerated() where i % every == 0 {
            let label = p.label.count > 12 ? String(p.label.prefix(11)) + "…" : p.label
            text(label, at: NSPoint(x: plot.minX + step * (CGFloat(i) + 0.5), y: plot.minY - 16), align: .center)
        }
        Self.palette[0].setFill()
        Self.palette[0].setStroke()
        if kind == .bar {
            for (i, p) in points.enumerated() {
                let x = plot.minX + step * CGFloat(i) + step * 0.15
                let top = y(p.value), zero = y(0)
                NSBezierPath(rect: NSRect(x: x, y: min(top, zero), width: max(1, step * 0.7), height: abs(top - zero))).fill()
            }
        } else {
            let path = NSBezierPath()
            for (i, p) in points.enumerated() {
                let point = NSPoint(x: plot.minX + step * (CGFloat(i) + 0.5), y: y(p.value))
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
                if points.count <= 60 { NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill() }
            }
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func drawPie() {
        let total = points.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }
        let legendWidth: CGFloat = 170
        let radius = max(10, min(bounds.width - legendWidth - 30, bounds.height - 30) / 2)
        let center = NSPoint(x: bounds.minX + 15 + radius, y: bounds.midY)
        var angle: CGFloat = 90
        for (i, p) in points.enumerated() {
            let sweep = CGFloat(p.value / total) * 360
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle - sweep, clockwise: true)
            wedge.close()
            Self.palette[i % Self.palette.count].setFill()
            wedge.fill()
            NSColor.textBackgroundColor.setStroke()
            wedge.lineWidth = 1
            wedge.stroke()
            angle -= sweep
        }
        var y = center.y + CGFloat(points.count) * 8
        for (i, p) in points.enumerated() {
            let x = center.x + radius + 24
            Self.palette[i % Self.palette.count].setFill()
            NSBezierPath(rect: NSRect(x: x, y: y + 2, width: 9, height: 9)).fill()
            let percent = (p.value / total * 100).formatted(.number.precision(.fractionLength(0...1)))
            let label = p.label.count > 18 ? String(p.label.prefix(17)) + "…" : p.label
            text("\(label)  \(percent) %", at: NSPoint(x: x + 14, y: y), color: .labelColor)
            y -= 16
        }
    }
}
