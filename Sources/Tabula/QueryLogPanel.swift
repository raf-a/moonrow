import AppCore
import AppKit
import DBKit

/// The middle of a workspace window: the panes over the query log (⌃⌘C), which starts hidden.
/// The log keeps its height when the window grows.
@MainActor
final class WorkspaceCenterController: NSViewController, NSSplitViewDelegate {
    let panes: WorkspacePanesController
    let log: QueryLogViewController
    private let split = NSSplitView()
    static let logVisibleKey = "QueryLogVisible"
    private static let logHeightKey = "QueryLogHeight"

    init(panes: WorkspacePanesController, log: QueryLogViewController) {
        self.panes = panes
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        addChild(panes)
        addChild(log)
        split.addArrangedSubview(panes.view)
        split.addArrangedSubview(log.view)
        split.setHoldingPriority(.init(250), forSubviewAt: 0)
        split.setHoldingPriority(.init(260), forSubviewAt: 1)
        log.view.isHidden = !UserDefaults.standard.bool(forKey: Self.logVisibleKey)
        view = split
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didPlaceLog, isLogVisible, split.bounds.height > 0 {
            didPlaceLog = true
            placeLog()
        }
    }
    private var didPlaceLog = false

    var isLogVisible: Bool { !log.view.isHidden }

    private var logHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.logHeightKey)
        return saved >= 80 ? saved : 180
    }

    private func placeLog() {
        let height = min(logHeight, max(80, split.bounds.height - 160))
        split.setPosition(split.bounds.height - height - split.dividerThickness, ofDividerAt: 0)
    }

    func toggleLog() {
        if isLogVisible { UserDefaults.standard.set(log.view.frame.height, forKey: Self.logHeightKey) }
        log.view.isHidden.toggle()
        split.adjustSubviews()
        if isLogVisible {
            placeLog()
            log.scrollToEnd()
        }
        UserDefaults.standard.set(isLogVisible, forKey: Self.logVisibleKey)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(proposed, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(proposed, splitView.bounds.height - 80)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if isLogVisible, log.view.frame.height >= 80 { UserDefaults.standard.set(log.view.frame.height, forKey: Self.logHeightKey) }
    }
}

/// The query log: every statement the workspace's connection sent (browsing, introspection,
/// commits, query tabs) with its time, duration and rows or error. Copy takes all of it;
/// Clear empties it.
@MainActor
final class QueryLogViewController: NSViewController {
    let log: QueryLog
    private let dialect: any Dialect
    private let scroll = NSTextView.scrollableTextView()
    private var text: NSTextView { scroll.documentView as! NSTextView }
    private let countLabel = NSTextField(labelWithString: "")
    /// Entries already in the text view, counted from the start of the log (dropped ones too).
    private var written = 0
    private static let maxShown = 2_000

    init(log: QueryLog, dialect: any Dialect) {
        self.log = log
        self.dialect = dialect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        text.isEditable = false
        text.isRichText = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)

        let title = NSTextField(labelWithString: "Query Log")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyLog(_:)))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog(_:)))
        for b in [copy, clear] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        copy.toolTip = "Copy the whole log"
        let bar = NSStackView(views: [title, countLabel, NSView(), copy, clear])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let line = NSBox()
        line.boxType = .separator
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        for v in [line, bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: root.topAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: line.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(logChanged), name: QueryLog.didChange, object: log)
        logChanged()
    }

    /// Lines in the text view.
    private var shownLines = 0

    /// Appends what's new; starts over after a Clear.
    @objc private func logChanged() {
        guard let storage = text.textStorage else { return }
        let total = log.dropped + log.entries.count
        if total < written {
            storage.setAttributedString(NSAttributedString())
            written = 0
            shownLines = 0
        }
        let atEnd = scroll.contentView.bounds.maxY >= text.bounds.maxY - 4
        let new = log.entries.suffix(min(total - written, log.entries.count))
        let out = NSMutableAttributedString()
        for entry in new {
            let color: NSColor = entry.error == nil ? .labelColor : entry.error == "Cancelled" ? .systemOrange : .systemRed
            out.append(NSAttributedString(string: QueryLog.line(entry, dialect: dialect) + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color,
            ]))
        }
        storage.append(out)
        written = total
        shownLines += new.count
        // The view keeps the last maxShown lines; Copy takes the whole log.
        if shownLines > Self.maxShown {
            let string = storage.string as NSString
            var end = 0
            for _ in 0..<(shownLines - Self.maxShown) {
                let r = string.range(of: "\n", options: [], range: NSRange(location: end, length: string.length - end))
                guard r.location != NSNotFound else { break }
                end = NSMaxRange(r)
            }
            storage.deleteCharacters(in: NSRange(location: 0, length: end))
            shownLines = Self.maxShown
        }
        countLabel.stringValue = log.entries.isEmpty ? "" : "\(log.entries.count.formatted()) statement\(log.entries.count == 1 ? "" : "s")"
        if atEnd { scrollToEnd() }
    }

    func scrollToEnd() { text.scrollToEndOfDocument(nil) }

    @objc func copyLog(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text(dialect: dialect), forType: .string)
    }

    @objc func clearLog(_ sender: Any?) { log.clear() }

    var shownText: String { text.string }
}
