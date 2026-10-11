import AppCore
import AppKit
import DBKit

/// Imports a CSV file into an existing table: file and parsing options, a preview of the first
/// rows, which file column fills each table column, and what to do with rows whose key exists.
/// The file is read into memory whole.
@MainActor
final class ImportCSVSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table: TableRef
    private let connection: any DatabaseConnection
    /// Asked before anything is written, with the first statements (safe mode).
    var confirm: ([String]) async -> Bool = { _ in true }
    /// After a successful import, with the number of rows.
    var onImported: ((Int) -> Void)?
    /// For the dev harness: called with the row count or the error when an import ends.
    var onFinish: ((Result<Int, any Error>) -> Void)?

    private var keepAlive: ImportCSVSheetController?
    private(set) var columns: [ColumnInfo] = []
    private(set) var fileURL: URL?
    private var data: Data?
    private(set) var csv: CSVDocument?
    private(set) var mapping: [Int?] = []
    private var task: Task<Void, Never>?

    private let fileLabel = NSTextField(labelWithString: "No file chosen")
    private let delimiterPopup = NSPopUpButton()
    private let quotePopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()
    private let headerBox = NSButton(checkboxWithTitle: "First line is a header", target: nil, action: nil)
    private let nullBox = NSButton(checkboxWithTitle: "Unquoted NULL means NULL", target: nil, action: nil)
    private let matchPopup = NSPopUpButton()
    private let duplicatePopup = NSPopUpButton()
    private let preview = NSTableView()
    private let mappingTable = NSTableView()
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private static let delimiters: [(String, Character?)] = [("Detect", nil), ("Comma", ","), ("Semicolon", ";"), ("Tab", "\t"), ("Pipe", "|")]
    private static let previewRows = 100

    init(table: TableRef, connection: any DatabaseConnection) {
        self.table = table
        self.connection = connection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 620, height: 480)
        super.init(window: window)
        window.contentView = makeContent()
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the sheet, loads the table's columns and asks for a file.
    func begin(on parent: NSWindow, file: URL? = nil) {
        guard let window else { return }
        keepAlive = self
        parent.beginSheet(window) { [weak self] _ in self?.keepAlive = nil }
        Task {
            do {
                columns = try await connection.columns(of: table)
                remap()
                if let file { load(file) } else { chooseFile(nil) }
            } catch {
                showStatus("Couldn't read the columns of \(table.name): \(error)", error: true)
            }
        }
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Import CSV into \(table.name)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile(_:)))

        for (title, _) in Self.delimiters { delimiterPopup.addItem(withTitle: title) }
        quotePopup.addItems(withTitles: ["\" (double)", "' (single)"])
        encodingPopup.addItems(withTitles: ["Automatic", "UTF-8", "Windows Latin 1", "Mac Roman"])
        headerBox.state = .on
        for control in [delimiterPopup, quotePopup, encodingPopup] as [NSPopUpButton] {
            control.target = self
            control.action = #selector(parsingChanged(_:))
        }
        headerBox.target = self
        headerBox.action = #selector(parsingChanged(_:))
        matchPopup.addItems(withTitles: ["Match columns by name", "Match columns by order"])
        matchPopup.target = self
        matchPopup.action = #selector(matchChanged(_:))
        duplicatePopup.addItems(withTitles: ["Stop on an existing key", "Update rows with an existing key"])
        duplicatePopup.target = self
        duplicatePopup.action = #selector(optionChanged(_:))
        nullBox.target = self
        nullBox.action = #selector(optionChanged(_:))

        preview.headerView = NSTableHeaderView()
        preview.usesAlternatingRowBackgroundColors = true
        preview.columnAutoresizingStyle = .noColumnAutoresizing
        preview.rowSizeStyle = .small
        preview.dataSource = self
        preview.delegate = self
        let previewScroll = scroll(preview)

        mappingTable.rowSizeStyle = .medium
        mappingTable.dataSource = self
        mappingTable.delegate = self
        for (id, title, width) in [("target", "Table column", 220.0), ("source", "From file column", 240.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            mappingTable.addTableColumn(c)
        }
        let mappingScroll = scroll(mappingTable)

        let previewLabel = NSTextField(labelWithString: "File preview (first \(Self.previewRows) rows)")
        let mappingLabel = NSTextField(labelWithString: "Columns")
        for l in [previewLabel, mappingLabel] { l.font = .systemFont(ofSize: 11, weight: .medium) }

        let hint = NSTextField(wrappingLabelWithString:
            "An empty field is NULL; a quoted empty field (\"\") is an empty string. Columns not imported get their default.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        progress.style = .bar
        progress.isHidden = true
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        importButton.target = self
        importButton.action = #selector(importClicked(_:))
        importButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let views: [NSView] = [
            title,
            row(choose, fileLabel),
            row(label("Delimiter"), delimiterPopup, label("Quote"), quotePopup, label("Encoding"), encodingPopup),
            row(headerBox, nullBox),
            previewLabel, previewScroll,
            row(mappingLabel, NSView(), matchPopup, duplicatePopup),
            mappingScroll, hint, progress,
            row(status, NSView(), cancelButton, importButton),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in views where v !== title {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        mappingScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        previewScroll.heightAnchor.constraint(equalTo: mappingScroll.heightAnchor).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        s.borderType = .bezelBorder
        s.setContentHuggingPriority(.init(1), for: .vertical)
        return s
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        return s
    }

    // MARK: - File and parsing

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a CSV file to import into \(table.name)"
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    func load(_ url: URL) {
        do {
            data = try Data(contentsOf: url)
            fileURL = url
            fileLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            fileLabel.textColor = .labelColor
            parse()
        } catch {
            showStatus("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)", error: true)
        }
    }

    private var reader: CSVReader {
        CSVReader(
            delimiter: Self.delimiters[max(0, delimiterPopup.indexOfSelectedItem)].1,
            quote: quotePopup.indexOfSelectedItem == 1 ? "'" : "\"",
            firstLineIsHeader: headerBox.state == .on,
            encoding: CSVReader.Encoding.allCases[max(0, encodingPopup.indexOfSelectedItem)])
    }

    private func parse() {
        guard let data else { return }
        do {
            csv = try reader.read(data)
            showStatus("", error: false)
        } catch {
            csv = nil
            showStatus("\(error)", error: true)
        }
        rebuildPreview()
        remap()
    }

    @objc private func parsingChanged(_ sender: Any?) { parse() }

    @objc private func matchChanged(_ sender: Any?) { remap() }

    @objc private func optionChanged(_ sender: Any?) { updateState() }

    private var match: CSVImportPlan.Match { matchPopup.indexOfSelectedItem == 1 ? .byOrder : .byName }

    /// The automatic mapping for the chosen strategy.
    private func remap() {
        let source = csv?.header
        let effective: CSVImportPlan.Match = source == nil ? .byOrder : match
        mapping = CSVImportPlan.mapping(for: columns, source: source, sourceCount: csv?.columnCount ?? 0, match: effective)
        mappingTable.reloadData()
        updateState()
    }

    private func rebuildPreview() {
        for c in preview.tableColumns.reversed() { preview.removeTableColumn(c) }
        guard let csv else { return preview.reloadData() }
        for (i, name) in csv.columnNames.enumerated() {
            let c = NSTableColumn(identifier: .init(String(i)))
            c.title = name
            c.width = 110
            preview.addTableColumn(c)
        }
        preview.reloadData()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === preview ? min(Self.previewRows, csv?.rows.count ?? 0) : columns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === preview {
            guard let doc = csv, let i = Int(tableColumn.identifier.rawValue), i < doc.rows[row].count else { return nil }
            let field = doc.rows[row][i]
            let text = NSTextField(labelWithString: field.text.isEmpty && !field.quoted ? "NULL" : field.text.replacing(/\r\n|\r|\n/, with: " "))
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 11)
            if field.text.isEmpty && !field.quoted { text.textColor = .tertiaryLabelColor }
            return text
        }
        let column = columns[row]
        if tableColumn.identifier.rawValue == "target" {
            var name = column.name + (column.typeName.isEmpty ? "" : "  \(column.typeName)")
            if column.primaryKeyPosition != nil { name += "  (key)" }
            let text = NSTextField(labelWithString: name)
            text.lineBreakMode = .byTruncatingTail
            return text
        }
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItem(withTitle: "Don't import")
        for name in csv?.columnNames ?? [] { popup.addItem(withTitle: name) }
        popup.selectItem(at: (mapping[safe: row].flatMap { $0 }).map { $0 + 1 } ?? 0)
        popup.tag = row
        popup.target = self
        popup.action = #selector(mappingChanged(_:))
        popup.isEnabled = column.generated?.hasPrefix("GENERATED ALWAYS") != true
        return popup
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard mapping.indices.contains(sender.tag) else { return }
        mapping[sender.tag] = sender.indexOfSelectedItem == 0 ? nil : sender.indexOfSelectedItem - 1
        updateState()
    }

    /// Maps target column `name` to file column `source` (nil: don't import). For the dev harness.
    func setMapping(_ name: String, to source: Int?) {
        guard let i = columns.firstIndex(where: { $0.name == name }) else { return }
        mapping[i] = source
        mappingTable.reloadData()
        updateState()
    }

    // MARK: - Importing

    private func plan() -> CSVImportPlan {
        CSVImportPlan(
            table: table, columns: columns, mapping: mapping,
            onDuplicate: duplicatePopup.indexOfSelectedItem == 1 ? .update : .stop, nullWord: nullBox.state == .on)
    }

    private func updateState() {
        duplicatePopup.isEnabled = !columns.primaryKey.isEmpty
        if columns.primaryKey.isEmpty { duplicatePopup.selectItem(at: 0) }
        guard task == nil else { return }
        guard let csv else {
            importButton.isEnabled = false
            return
        }
        do {
            try plan().validate()
            importButton.isEnabled = !csv.rows.isEmpty
            let mapped = mapping.compactMap { $0 }.count
            showStatus("\(csv.rows.count.formatted()) row\(csv.rows.count == 1 ? "" : "s") in the file; \(mapped) of \(columns.count) columns mapped.", error: false)
        } catch {
            importButton.isEnabled = false
            showStatus("\(error)", error: true)
        }
    }

    @objc private func importClicked(_ sender: Any?) { startImport() }

    /// Runs the import with the options shown. The dev harness calls this directly.
    func startImport() {
        guard let csv, task == nil else { return }
        let plan = plan()
        let preview: [String]
        do {
            preview = try plan.preview(for: csv, dialect: connection.dialect)
        } catch {
            return showStatus("\(error)", error: true)
        }
        let connection = connection
        let total = csv.rows.count
        importButton.isEnabled = false
        task = Task {
            guard await confirm(preview) else {
                task = nil
                updateState()
                return
            }
            progress.isHidden = false
            progress.maxValue = Double(max(1, total))
            progress.doubleValue = 0
            showStatus("Importing…", error: false)
            let result: Result<Int, any Error>
            do {
                let n = try await plan.run(csv, on: connection) { n in
                    Task { @MainActor in self.progressed(n) }
                }
                result = .success(n)
            } catch {
                result = .failure(error)
            }
            task = nil
            progress.isHidden = true
            switch result {
            case .success(let n):
                onImported?(n)
                onFinish?(result)
                close()
            case .failure(let error):
                showStatus("\(error)", error: true)
                importButton.isEnabled = true
                onFinish?(result)
            }
        }
    }

    private func progressed(_ rows: Int) {
        guard task != nil else { return }
        progress.doubleValue = Double(rows)
        showStatus("Importing… \(rows.formatted()) rows sent", error: false)
    }

    private func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancelClicked(_ sender: Any?) {
        // A running import finishes or rolls back on its own; the transaction can't be left halfway.
        guard task == nil else { return NSSound.beep() }
        close()
    }

    override func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { super.close() }
    }
}
