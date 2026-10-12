import AppCore
import AppKit
import DBKit

/// What an export writes: a table (as the grid shows it, or all of it) or a query result.
enum ExportSubject {
    /// `filter` and `sort` are the grid's; `shownRows` is how many rows they select, when known.
    case table(TableRef, kind: ObjectKind, filter: Filter?, sort: [SortKey], shownRows: Int?)
    /// Rows in memory: a query result, or the page a table grid shows. `origin` describes them.
    case result(name: String, columns: [String], rows: [[DBValue]], origin: String = "from the query")

    var name: String {
        switch self {
        case .table(let t, _, _, _, _): t.name
        case .result(let name, _, _, _): name
        }
    }

    var isTable: Bool { if case .table = self { true } else { false } }
}

/// The last options used, per kind of subject.
struct ExportSettings: Codable {
    var format = 0
    var csv = CSVOptions()
    var json = JSONOptions()
    var sql = SQLExportOptions()
    var wholeTable = false

    static func load(table: Bool) -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: key(table)),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return s
    }

    func save(table: Bool) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(table)) }
    }

    private static func key(_ table: Bool) -> String { table ? "Export.table" : "Export.result" }
}

/// A sheet with the format and its options, then a save panel, progress and Stop.
@MainActor
final class ExportSheetController: NSWindowController, NSTextFieldDelegate {
    let subject: ExportSubject
    private let connection: any DatabaseConnection
    private var settings: ExportSettings
    private var keepAlive: ExportSheetController?
    private var task: Task<Void, Never>?
    private(set) var exportedURL: URL?
    /// For the dev harness: called with the row count or the error when an export ends.
    var onFinish: ((Result<Int, any Error>) -> Void)?

    private let formatControl = NSSegmentedControl(labels: ["CSV", "JSON", "SQL"], trackingMode: .selectOne, target: nil, action: nil)
    private let scopePopup = NSPopUpButton()
    private let csvPane = NSGridView()
    private let jsonPane = NSGridView()
    private let sqlPane = NSGridView()

    private let delimiterPopup = NSPopUpButton()
    private let customDelimiter = NSTextField()
    private let quotingPopup = NSPopUpButton()
    private let lineBreakPopup = NSPopUpButton()
    private let decimalPopup = NSPopUpButton()
    private let headerBox = NSButton(checkboxWithTitle: "Column names in the first row", target: nil, action: nil)
    private let nullBox = NSButton(checkboxWithTitle: "Write NULL as an empty field", target: nil, action: nil)
    private let flattenBox = NSButton(checkboxWithTitle: "Replace line breaks in values with spaces", target: nil, action: nil)
    private let prettyBox = NSButton(checkboxWithTitle: "Pretty-print (one key per line)", target: nil, action: nil)
    private let dropBox = NSButton(checkboxWithTitle: "DROP TABLE IF EXISTS first", target: nil, action: nil)
    private let createBox = NSButton(checkboxWithTitle: "CREATE TABLE", target: nil, action: nil)
    private let dataBox = NSButton(checkboxWithTitle: "Rows as INSERT statements", target: nil, action: nil)
    private let perInsertField = NSTextField()
    private let tableNameField = NSTextField()

    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)

    private static let delimiters: [(String, String)] = [("Comma", ","), ("Semicolon", ";"), ("Tab", "\t"), ("Pipe", "|")]

    init(subject: ExportSubject, connection: any DatabaseConnection) {
        self.subject = subject
        self.connection = connection
        self.settings = ExportSettings.load(table: subject.isTable)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        window.contentView = makeContent()
        show(settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        keepAlive = self
        parent.beginSheet(window) { [weak self] _ in self?.keepAlive = nil }
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Export \(subject.name)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let source = NSTextField(wrappingLabelWithString: sourceDescription)
        source.textColor = .secondaryLabelColor
        source.preferredMaxLayoutWidth = 420

        formatControl.target = self
        formatControl.action = #selector(formatChanged(_:))

        let topGrid = NSGridView()
        if case .table(_, _, let filter, let sort, let shown) = subject, filter != nil || !sort.isEmpty {
            let current = filter == nil ? "Current sort" : sort.isEmpty ? "Current filter" : "Current filter and sort"
            scopePopup.addItems(withTitles: [current + (shown.map { " (\($0.formatted()) rows)" } ?? ""), "Whole table"])
            topGrid.addRow(with: [label("Rows"), scopePopup])
        }
        topGrid.addRow(with: [label("Format"), formatControl])
        let top: [NSView] = [title, source, topGrid]

        for (title, _) in Self.delimiters { delimiterPopup.addItem(withTitle: title) }
        delimiterPopup.addItem(withTitle: "Other:")
        delimiterPopup.target = self
        delimiterPopup.action = #selector(delimiterChanged(_:))
        customDelimiter.widthAnchor.constraint(equalToConstant: 32).isActive = true
        customDelimiter.alignment = .center
        customDelimiter.delegate = self
        quotingPopup.addItems(withTitles: ["Only when needed", "Every field"])
        lineBreakPopup.addItems(withTitles: ["LF (\\n)", "CRLF (\\r\\n)", "CR (\\r)"])
        decimalPopup.addItems(withTitles: [". (1.5)", ", (1,5)"])
        csvPane.addRow(with: [label("Delimiter"), row(delimiterPopup, customDelimiter)])
        csvPane.addRow(with: [label("Quotes"), quotingPopup])
        csvPane.addRow(with: [label("Line break"), lineBreakPopup])
        csvPane.addRow(with: [label("Decimal"), decimalPopup])
        for box in [headerBox, nullBox, flattenBox] { csvPane.addRow(with: [NSGridCell.emptyContentView, box]) }

        jsonPane.addRow(with: [label(""), prettyBox])
        let blobs = NSTextField(labelWithString: "Blobs are written as base64 strings.")
        blobs.textColor = .secondaryLabelColor
        blobs.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        jsonPane.addRow(with: [NSGridCell.emptyContentView, blobs])

        perInsertField.alignment = .right
        perInsertField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        tableNameField.placeholderString = "result"
        tableNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        if !subject.isTable { sqlPane.addRow(with: [label("Table name"), tableNameField]) }
        sqlPane.addRow(with: [label("Include"), dropBox])
        if subject.isTable { sqlPane.addRow(with: [NSGridCell.emptyContentView, createBox]) }
        sqlPane.addRow(with: [NSGridCell.emptyContentView, dataBox])
        sqlPane.addRow(with: [label("Rows per INSERT"), perInsertField])

        for pane in [topGrid, csvPane, jsonPane, sqlPane] {
            pane.rowSpacing = 7
            pane.columnSpacing = 8
            pane.column(at: 0).xPlacement = .trailing
            pane.column(at: 0).width = 120
            pane.setContentHuggingPriority(.required, for: .vertical)
            pane.rowAlignment = .firstBaseline
        }

        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 420).isActive = true
        status.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.preferredMaxLayoutWidth = 420
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        revealButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(exportClicked(_:))
        exportButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [revealButton, NSView(), cancelButton, exportButton])

        let stack = NSStackView(views: top + [csvPane, jsonPane, sqlPane, progress, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        return s
    }

    private var sourceDescription: String {
        switch subject {
        case .table(let t, let kind, let filter, _, let shown):
            let what = kind == .table ? "Table" : "View"
            var s = "\(what) \(t)"
            if let shown { s += " — \(shown.formatted()) row\(shown == 1 ? "" : "s")" + (filter == nil ? "" : " match the filter") }
            return s
        case .result(_, let columns, let rows, let origin):
            return "\(rows.count.formatted()) row\(rows.count == 1 ? "" : "s"), \(columns.count) column\(columns.count == 1 ? "" : "s") \(origin)"
        }
    }

    // MARK: - Settings

    private func show(_ s: ExportSettings) {
        formatControl.selectedSegment = min(2, max(0, s.format))
        scopePopup.selectItem(at: s.wholeTable && scopePopup.numberOfItems > 1 ? 1 : 0)
        if let i = Self.delimiters.firstIndex(where: { $0.1 == s.csv.delimiter }) {
            delimiterPopup.selectItem(at: i)
            customDelimiter.stringValue = ""
        } else {
            delimiterPopup.selectItem(at: Self.delimiters.count)
            customDelimiter.stringValue = s.csv.delimiter
        }
        quotingPopup.selectItem(at: s.csv.quoting == .always ? 1 : 0)
        lineBreakPopup.selectItem(at: CSVOptions.LineBreak.allCases.firstIndex(of: s.csv.lineBreak) ?? 0)
        decimalPopup.selectItem(at: s.csv.decimalSeparator == "," ? 1 : 0)
        headerBox.state = s.csv.includeHeader ? .on : .off
        nullBox.state = s.csv.nullAsEmpty ? .on : .off
        flattenBox.state = s.csv.flattenLineBreaks ? .on : .off
        prettyBox.state = s.json.pretty ? .on : .off
        dropBox.state = s.sql.dropTable ? .on : .off
        createBox.state = s.sql.includeStructure ? .on : .off
        dataBox.state = s.sql.includeData ? .on : .off
        perInsertField.stringValue = String(s.sql.rowsPerInsert)
        tableNameField.stringValue = subject.isTable ? "" : subject.name.lowercased().replacingOccurrences(of: " ", with: "_")
        updatePanes()
    }

    private func edited() -> ExportSettings {
        var s = settings
        s.format = formatControl.selectedSegment
        s.wholeTable = scopePopup.indexOfSelectedItem == 1
        let d = delimiterPopup.indexOfSelectedItem
        s.csv.delimiter = d < Self.delimiters.count ? Self.delimiters[d].1 : customDelimiter.stringValue
        s.csv.quoting = quotingPopup.indexOfSelectedItem == 1 ? .always : .ifNeeded
        s.csv.lineBreak = CSVOptions.LineBreak.allCases[max(0, lineBreakPopup.indexOfSelectedItem)]
        s.csv.decimalSeparator = decimalPopup.indexOfSelectedItem == 1 ? "," : "."
        s.csv.includeHeader = headerBox.state == .on
        s.csv.nullAsEmpty = nullBox.state == .on
        s.csv.flattenLineBreaks = flattenBox.state == .on
        s.json.pretty = prettyBox.state == .on
        s.sql.dropTable = dropBox.state == .on
        s.sql.includeStructure = createBox.state == .on
        s.sql.includeData = dataBox.state == .on
        s.sql.rowsPerInsert = max(1, Int(perInsertField.stringValue.filter(\.isNumber)) ?? 100)
        return s
    }

    private var format: ExportFormat {
        let s = edited()
        switch s.format {
        case 1: return .json(s.json)
        case 2:
            var o = s.sql
            if !subject.isTable { o.includeStructure = false }
            return .sql(o)
        default: return .csv(s.csv)
        }
    }

    private func updatePanes() {
        let f = formatControl.selectedSegment
        csvPane.isHidden = f != 0
        jsonPane.isHidden = f != 1
        sqlPane.isHidden = f != 2
        customDelimiter.isHidden = delimiterPopup.indexOfSelectedItem < Self.delimiters.count
        if task == nil {
            status.stringValue = ""
            progress.isHidden = true
            revealButton.isHidden = true
        }
        if let window, let content = window.contentView { window.fit(to: content) }
    }

    @objc private func formatChanged(_ sender: Any?) { updatePanes() }

    /// 0 CSV, 1 JSON, 2 SQL. For the dev harness.
    func selectFormat(_ index: Int) {
        formatControl.selectedSegment = index
        updatePanes()
        window?.displayIfNeeded()
    }
    @objc private func delimiterChanged(_ sender: Any?) { updatePanes() }

    // MARK: - Exporting

    private var defaultFileName: String {
        let base = subject.name.isEmpty ? "export" : subject.name
        return base.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
    }

    private func job() -> ExportJob {
        switch subject {
        case .table(let t, _, let filter, let sort, _):
            let whole = scopePopup.indexOfSelectedItem == 1
            return ExportJob(source: .table(t, filter: whole ? nil : filter, sort: whole ? [] : sort, connection: connection), format: format)
        case .result(_, let columns, let rows, _):
            let name = tableNameField.stringValue.trimmingCharacters(in: .whitespaces)
            return ExportJob(source: .rows(name: name.isEmpty ? "result" : name, columns: columns, rows: rows, dialect: connection.dialect), format: format)
        }
    }

    @objc private func exportClicked(_ sender: Any?) {
        if case .csv(let o) = format {
            do { try o.validate() } catch { return showStatus("\(error)", error: true) }
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    /// Writes the file with the options shown. The dev harness calls this directly.
    func export(to url: URL) {
        settings = edited()
        settings.save(table: subject.isTable)
        let job = job()
        let total: Int? = switch subject {
        case .table(_, _, _, _, let shown): scopePopup.indexOfSelectedItem == 1 ? nil : shown
        case .result(_, _, let rows, _): rows.count
        }
        progress.isHidden = false
        progress.isIndeterminate = total == nil || total == 0
        progress.maxValue = Double(max(1, total ?? 1))
        progress.doubleValue = 0
        if progress.isIndeterminate { progress.startAnimation(nil) }
        exportButton.isEnabled = false
        revealButton.isHidden = true
        cancelButton.title = "Stop"
        showStatus("Exporting…", error: false)
        task = Task {
            let result: Result<Int, any Error>
            do {
                let n = try await job.run(to: url) { n in
                    Task { @MainActor in self.progressed(n) }
                }
                result = .success(n)
            } catch {
                result = .failure(error)
            }
            finished(result, url: url)
        }
    }

    private func progressed(_ rows: Int) {
        guard task != nil else { return }
        if !progress.isIndeterminate { progress.doubleValue = Double(rows) }
        showStatus("Exporting… \(rows.formatted()) rows", error: false)
    }

    private func finished(_ result: Result<Int, any Error>, url: URL) {
        task = nil
        progress.stopAnimation(nil)
        exportButton.isEnabled = true
        cancelButton.title = "Done"
        switch result {
        case .success(let n):
            exportedURL = url
            progress.isHidden = true
            revealButton.isHidden = false
            showStatus("Exported \(n.formatted()) row\(n == 1 ? "" : "s") to \(url.lastPathComponent).", error: false)
        case .failure(let error):
            progress.isHidden = true
            cancelButton.title = "Cancel"
            showStatus(error is CancellationError ? "Stopped. No file was written." : "Export failed: \(error)", error: !(error is CancellationError))
        }
        onFinish?(result)
    }

    private func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancelClicked(_ sender: Any?) {
        if let task {
            task.cancel()
            return
        }
        close()
    }

    override func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { super.close() }
    }

    @objc private func reveal(_ sender: Any?) {
        if let exportedURL { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
    }

    func controlTextDidChange(_ obj: Notification) { status.stringValue = "" }
}

extension CopyFormat {
    /// "Copy Rows As ▸" with one item per format; each item's tag is its index in `allCases`.
    @MainActor
    static func menuItem(target: AnyObject, action: Selector, title: String = "Copy Rows As") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for (i, format) in allCases.enumerated() {
            let entry = menu.addItem(withTitle: format.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.tag = i
        }
        item.submenu = menu
        return item
    }
}
