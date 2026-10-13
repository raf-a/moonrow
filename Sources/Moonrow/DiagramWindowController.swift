import AppCore
import AppKit
import DBKit

/// Show Diagram: the schema's tables and foreign keys, laid out automatically (`SchemaDiagram`).
/// Read-only: boxes can be dragged and the view zoomed, nothing is changed in the database. A
/// double-click on a table opens it in the workspace.
@MainActor
final class DiagramWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    private let canvas = DiagramCanvas()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "Loading…")
    private let searchField = NSSearchField()
    private var loadTask: Task<Void, Never>?
    let schema: String?
    /// A double-click on a table.
    var onOpen: ((DatabaseObject) -> Void)?

    init(title: String, schema: String?) {
        self.schema = schema
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = "Diagram"
        window.subtitle = title
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)

        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 3
        scroll.backgroundColor = .textBackgroundColor
        canvas.onOpen = { [weak self] table in self?.onOpen?(table) }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let root = NSView()
        for v in [scroll, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        window.contentView = root
        let toolbar = NSToolbar(identifier: "Diagram")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        window.setFrameAutosaveName("Diagram")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Reads the tables' columns and keys on `connection` and lays them out.
    func load(_ tables: [TableRef], on connection: @escaping () async throws -> any DatabaseConnection, closeAfter: Bool) {
        loadTask?.cancel()
        status.stringValue = "Reading \(tables.count) \(tables.count == 1 ? "table" : "tables")…"
        loadTask = Task {
            do {
                let session = try await connection()
                defer { if closeAfter { Task { await session.close() } } }
                let diagram = try await SchemaDiagram.load(tables, on: session)
                guard !Task.isCancelled else { return }
                canvas.show(diagram)
                let (t, k) = (diagram.tables.count, diagram.edges.count)
                var text = "\(t) \(t == 1 ? "table" : "tables"), \(k) \(k == 1 ? "foreign key" : "foreign keys")"
                if diagram.omitted > 0 { text += " (\(diagram.omitted) more not shown)" }
                status.stringValue = text
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = "Couldn't read the tables: \(error)"
            }
        }
    }

    func stop() { loadTask?.cancel() }

    var diagram: SchemaDiagram? { canvas.diagram }

    // MARK: - Toolbar

    private static let rearrange = NSToolbarItem.Identifier("rearrange")
    private static let zoomOut = NSToolbarItem.Identifier("zoomOut")
    private static let zoomReset = NSToolbarItem.Identifier("zoomReset")
    private static let zoomIn = NSToolbarItem.Identifier("zoomIn")
    private static let search = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.rearrange, Self.zoomOut, Self.zoomReset, Self.zoomIn, .flexibleSpace, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.search {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Find table"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(findTable(_:))
            return item
        }
        let (label, symbol, action): (String, String, Selector) = switch id {
        case Self.rearrange: ("Rearrange", "arrow.triangle.2.circlepath", #selector(rearrange(_:)))
        case Self.zoomOut: ("Zoom Out", "minus.magnifyingglass", #selector(zoomOut(_:)))
        case Self.zoomReset: ("Actual Size", "1.magnifyingglass", #selector(zoomReset(_:)))
        default: ("Zoom In", "plus.magnifyingglass", #selector(zoomIn(_:)))
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    @objc func rearrange(_ sender: Any?) { canvas.layOut() }
    @objc func zoomOut(_ sender: Any?) { scroll.animator().magnification = max(scroll.minMagnification, scroll.magnification / 1.25) }
    @objc func zoomIn(_ sender: Any?) { scroll.animator().magnification = min(scroll.maxMagnification, scroll.magnification * 1.25) }
    @objc func zoomReset(_ sender: Any?) { scroll.animator().magnification = 1 }

    @objc private func findTable(_ sender: NSSearchField) {
        if let frame = canvas.highlight(matching: sender.stringValue) {
            canvas.scrollToVisible(frame.insetBy(dx: -40, dy: -40))
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField { findTable(field) }
    }
}

/// Draws the diagram: a box per table (name, then its columns with the key ones marked) and a
/// line per foreign key from the referencing columns to the referenced table.
@MainActor
final class DiagramCanvas: NSView {
    private(set) var diagram: SchemaDiagram?
    private(set) var frames: [NSRect] = []
    private var highlighted: Set<Int> = []
    private var dragging: (index: Int, offset: NSPoint)?
    var onOpen: ((DatabaseObject) -> Void)?

    static let header: CGFloat = 26
    static let rowHeight: CGFloat = 18
    static let maxRows = 30
    private static let margin: CGFloat = 40

    override var isFlipped: Bool { true }

    func show(_ diagram: SchemaDiagram) {
        self.diagram = diagram
        layOut()
    }

    /// Back to the automatic layout.
    func layOut() {
        guard let diagram else { return }
        let sizes = diagram.tables.map(Self.size)
        let origins = diagram.layout(sizes: sizes)
        frames = zip(origins, sizes).map { NSRect(origin: NSPoint(x: $0.x + Self.margin, y: $0.y + Self.margin), size: $1) }
        resize()
        needsDisplay = true
    }

    private func resize() {
        let extent = frames.reduce(NSRect.zero) { $0.union($1) }
        setFrameSize(NSSize(width: max(extent.maxX + Self.margin, superview?.bounds.width ?? 0),
                            height: max(extent.maxY + Self.margin, superview?.bounds.height ?? 0)))
    }

    static func size(_ table: SchemaDiagram.Table) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 12)
        var width = (table.ref.name as NSString).size(withAttributes: [.font: bold]).width + 24
        for c in table.columns.prefix(maxRows) {
            let line = "\(c.name)  \(c.typeName)" as NSString
            width = max(width, line.size(withAttributes: [.font: font]).width + 36)
        }
        let rows = min(table.columns.count, maxRows) + (table.columns.count > maxRows ? 1 : 0)
        return CGSize(width: min(max(width, 120), 300), height: header + CGFloat(max(rows, 1)) * rowHeight + 6)
    }

    /// Highlights the tables whose name contains `text`; returns the first one's frame.
    func highlight(matching text: String) -> NSRect? {
        guard let diagram else { return nil }
        let term = text.trimmingCharacters(in: .whitespaces).lowercased()
        highlighted = term.isEmpty ? [] : Set(diagram.tables.indices.filter { diagram.tables[$0].ref.name.lowercased().contains(term) })
        needsDisplay = true
        return highlighted.min().map { frames[$0] }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let diagram else { return }
        // Keys first, under the boxes.
        NSColor.secondaryLabelColor.setStroke()
        for edge in diagram.edges {
            drawEdge(edge, in: diagram)
        }
        for (i, table) in diagram.tables.enumerated() where frames[i].intersects(dirtyRect) {
            drawBox(table, frame: frames[i], highlighted: highlighted.contains(i), keyColumns: Set(
                diagram.edges.filter { $0.child == i }.flatMap(\.columns)))
        }
    }

    private func columnY(_ table: SchemaDiagram.Table, _ name: String, in frame: NSRect) -> CGFloat {
        let i = table.columns.firstIndex { $0.name == name } ?? 0
        return frame.minY + Self.header + (CGFloat(min(i, Self.maxRows)) + 0.5) * Self.rowHeight
    }

    private func drawEdge(_ edge: SchemaDiagram.Edge, in diagram: SchemaDiagram) {
        let child = frames[edge.child]
        let parent = frames[edge.parent]
        let childTable = diagram.tables[edge.child]
        let parentTable = diagram.tables[edge.parent]
        let path = NSBezierPath()
        path.lineWidth = 1.2
        let y1 = columnY(childTable, edge.columns.first ?? "", in: child)
        let y2 = columnY(parentTable, edge.referencedColumns.first ?? "", in: parent)
        if edge.child == edge.parent {
            // A key to its own table: a loop on the right side.
            let x = child.maxX
            path.move(to: NSPoint(x: x, y: y1))
            path.curve(to: NSPoint(x: x, y: y2), controlPoint1: NSPoint(x: x + 40, y: y1), controlPoint2: NSPoint(x: x + 40, y: y2))
            path.stroke()
            return
        }
        // Leave from the side facing the other box.
        let leftward = parent.midX < child.midX
        let start = NSPoint(x: leftward ? child.minX : child.maxX, y: y1)
        let end = NSPoint(x: leftward ? parent.maxX : parent.minX, y: y2)
        let bend = max(30, abs(end.x - start.x) / 2)
        path.move(to: start)
        path.curve(to: end, controlPoint1: NSPoint(x: start.x + (leftward ? -bend : bend), y: start.y),
                   controlPoint2: NSPoint(x: end.x + (leftward ? bend : -bend), y: end.y))
        path.stroke()
        // A bar at the referenced end, a fork at the referencing one.
        let bar = NSBezierPath()
        let dx: CGFloat = leftward ? 6 : -6
        bar.move(to: NSPoint(x: end.x + dx, y: end.y - 5))
        bar.line(to: NSPoint(x: end.x + dx, y: end.y + 5))
        let fork = NSBezierPath()
        let fx: CGFloat = leftward ? -8 : 8
        fork.move(to: NSPoint(x: start.x, y: start.y - 5))
        fork.line(to: NSPoint(x: start.x + fx, y: start.y))
        fork.line(to: NSPoint(x: start.x, y: start.y + 5))
        bar.stroke()
        fork.stroke()
    }

    private func drawBox(_ table: SchemaDiagram.Table, frame: NSRect, highlighted: Bool, keyColumns: Set<String>) {
        let box = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        let head = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.header)
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        (highlighted ? NSColor.systemYellow.withAlphaComponent(0.45) : NSColor.systemBlue.withAlphaComponent(0.18)).setFill()
        head.fill()
        NSGraphicsContext.restoreGraphicsState()
        (highlighted ? NSColor.systemOrange : NSColor.separatorColor).setStroke()
        box.lineWidth = highlighted ? 2 : 1
        box.stroke()

        let title = NSAttributedString(string: table.ref.name, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        title.draw(in: NSRect(x: frame.minX + 10, y: frame.minY + 5, width: frame.width - 20, height: 16))
        let font = NSFont.systemFont(ofSize: 11)
        for (i, c) in table.columns.prefix(Self.maxRows).enumerated() {
            let y = frame.minY + Self.header + CGFloat(i) * Self.rowHeight
            let marker = c.primaryKeyPosition != nil ? "key.fill" : keyColumns.contains(c.name) ? "link" : nil
            if let marker, let image = NSImage(systemSymbolName: marker, accessibilityDescription: nil) {
                let tinted = image.withSymbolConfiguration(.init(paletteColors: [c.primaryKeyPosition != nil ? .systemYellow : .systemBlue]))
                tinted?.draw(in: NSRect(x: frame.minX + 8, y: y + 3, width: 11, height: 11))
            }
            NSAttributedString(string: c.name, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                .draw(in: NSRect(x: frame.minX + 24, y: y + 1, width: frame.width * 0.55 - 24, height: 15))
            let type = NSAttributedString(string: c.typeName, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let w = min(type.size().width, frame.width * 0.45 - 8)
            type.draw(in: NSRect(x: frame.maxX - 8 - w, y: y + 1, width: w, height: 15))
        }
        if table.columns.count > Self.maxRows {
            let y = frame.minY + Self.header + CGFloat(Self.maxRows) * Self.rowHeight
            NSAttributedString(string: "\(table.columns.count - Self.maxRows) more…", attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
            ]).draw(at: NSPoint(x: frame.minX + 24, y: y + 1))
        }
    }

    // MARK: - Mouse

    private func boxIndex(at point: NSPoint) -> Int? {
        frames.indices.last { frames[$0].contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let i = boxIndex(at: point) else { return }
        if event.clickCount == 2, let diagram {
            onOpen?(DatabaseObject(diagram.tables[i].ref, kind: .table))
            return
        }
        dragging = (i, NSPoint(x: point.x - frames[i].minX, y: point.y - frames[i].minY))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        frames[dragging.index].origin = NSPoint(x: max(0, point.x - dragging.offset.x), y: max(0, point.y - dragging.offset.y))
        resize()
        needsDisplay = true
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }
}
