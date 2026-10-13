import AppCore
import AppKit
import DBKit

/// Asks for the values of a run's placeholders (`QueryParameters`). Each row has the value and
/// how it's written in: Auto (numbers, NULL, TRUE and FALSE as typed, anything else quoted),
/// Text (always quoted) or SQL (as typed). The workspace remembers the last input per name.
@MainActor
final class QueryParametersSheet: NSWindowController {
    struct Input: Hashable {
        var text: String
        var kind: QueryParameters.Kind
    }

    private let keys: [String]
    private var fields: [NSTextField] = []
    private var kinds: [NSPopUpButton] = []
    private var completion: (([String: Input]?) -> Void)?

    init(keys: [String], remembered: [String: Input]) {
        self.keys = keys
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Query Parameters"
        super.init(window: window)
        build(remembered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ remembered: [String: Input]) {
        let title = NSTextField(labelWithString: keys.count == 1 ? "The query has a parameter." : "The query has \(keys.count) parameters.")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        var rows: [[NSView]] = []
        for key in keys {
            let label = NSTextField(labelWithString: key)
            label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            let field = NSTextField()
            field.placeholderString = "Value"
            field.stringValue = remembered[key]?.text ?? ""
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            let kind = NSPopUpButton()
            kind.addItems(withTitles: ["Auto", "Text", "SQL"])
            kind.selectItem(at: QueryParameters.Kind.allCases.firstIndex(of: remembered[key]?.kind ?? .auto) ?? 0)
            kind.toolTip = "Auto: numbers, NULL, TRUE and FALSE as typed, anything else quoted. Text: always quoted. SQL: as typed."
            kind.controlSize = .small
            fields.append(field)
            kinds.append(kind)
            rows.append([label, field, kind])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = keys.count > 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let run = NSButton(title: "Run", target: self, action: #selector(run(_:)))
        run.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, run])

        let root = NSView()
        for v in [title, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let height = min(CGFloat(keys.count) * 32, 8 * 32)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: height),
            grid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        window?.contentView = root
        window?.initialFirstResponder = fields.first
        // Tab moves through the value fields.
        for (a, b) in zip(fields, fields.dropFirst() + fields.prefix(1)) { a.nextKeyView = b }
    }

    func begin(on window: NSWindow, completion: @escaping ([String: Input]?) -> Void) {
        guard let sheet = self.window else { return completion(nil) }
        self.completion = completion
        window.beginSheet(sheet) { _ in _ = self }
    }

    var inputs: [String: Input] {
        Dictionary(uniqueKeysWithValues: keys.indices.map { i in
            (keys[i], Input(text: fields[i].stringValue, kind: QueryParameters.Kind.allCases[max(0, kinds[i].indexOfSelectedItem)]))
        })
    }

    @objc private func run(_ sender: Any?) { finish(inputs) }
    @objc private func cancel(_ sender: Any?) { finish(nil) }

    private func finish(_ result: [String: Input]?) {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    // MARK: - For the dev harness

    func fill(_ key: String, _ text: String, kind: QueryParameters.Kind = .auto) {
        guard let i = keys.firstIndex(of: key) else { return }
        fields[i].stringValue = text
        kinds[i].selectItem(at: QueryParameters.Kind.allCases.firstIndex(of: kind) ?? 0)
    }

    func confirm() { run(nil) }
}
