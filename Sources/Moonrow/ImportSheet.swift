import AppCore
import AppKit
import DBKit

enum ImportFormat {
    case csv, json

    var title: String { self == .csv ? "CSV" : "JSON" }
}

/// Imports a CSV or JSON file into a table, existing or created from the file: parsing options,
/// a preview of the first rows, which file column fills each table column (or each new column's
/// name and type), and what to do with rows whose key exists. The file is read a record at a
/// time while the rows are sent, in one transaction; Stop rolls it back.
@MainActor
final class ImportSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    let format: ImportFormat
    private let dialect: any Dialect
    /// The tables of the schema; the first choice of "Existing table".
    private let tables: [TableRef]
    /// Where new tables go.
    private let schema: String?
    /// Whether a table or view of that name exists (new tables need a free name).
    var nameTaken: (String) -> Bool = { _ in false }
    /// The connection the import runs on: a session of its own where the workspace has one.
    var session: () async throws -> (connection: any DatabaseConnection, closeAfter: Bool)
    /// Asked before anything is written, with the first statements (safe mode).
    var confirm: ([String]) async -> Bool = { _ in true }
    /// Before a run into an existing table: settles its staged edits; false cancels.
    var prepare: (TableRef) async -> Bool = { _ in true }
    /// After a successful import: the table, the rows, and whether it was created.
    var onImported: ((TableRef, Int, Bool) -> Void)?
    /// For the dev harness: called with the row count or the error when an import ends.
    var onFinish: ((Result<Int, any Error>) -> Void)?

    private var keepAlive: ImportSheetController?
    private(set) var target: TableRef?
    private(set) var columns: [ColumnInfo] = []
    private(set) var fileURL: URL?
    /// The first records and the file's column names.
    private(set) var preview: [ImportRecord] = []
    private(set) var columnNames: [String] = []
    private var hasNames = true
    private(set) var mapping: [Int?] = []
    /// When creating a table: the guessed columns, as edited.
    private(set) var design: ImportTableDesign?
    private var task: Task<Void, Never>?
    private var isRunning: Bool { task != nil }

    private let fileLabel = NSTextField(labelWithString: "No file chosen")
    private let existingRadio = NSButton(radioButtonWithTitle: "Existing table", target: nil, action: nil)
    private let newRadio = NSButton(radioButtonWithTitle: "New table", target: nil, action: nil)
    private let tablePopup = NSPopUpButton()
    private let newNameField = NSTextField()
    private let delimiterPopup = NSPopUpButton()
    private let quotePopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()
    private let headerBox = NSButton(checkboxWithTitle: "First line is a header", target: nil, action: nil)
    private let nullBox = NSButton(checkboxWithTitle: "Unquoted NULL means NULL", target: nil, action: nil)
    private let commaBox = NSButton(checkboxWithTitle: "Numbers use a decimal comma (1.234,5)", target: nil, action: nil)
    private let matchPopup = NSPopUpButton()
    private let duplicatePopup = NSPopUpButton()
    private let previewTable = NSTableView()
    private let mappingTable = NSTableView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var csvRows: [NSView] = []

    private static let delimiters: [(String, Character?)] = [("Detect", nil), ("Comma", ","), ("Semicolon", ";"), ("Tab", "\t"), ("Pipe", "|")]
    private static let previewRows = 100

    init(format: ImportFormat, target: TableRef?, tables: [TableRef], schema: String?, dialect: any Dialect,
         session: @escaping () async throws -> (connection: any DatabaseConnection, closeAfter: Bool)) {
        self.format = format
        self.target = target
        self.tables = tables
        self.schema = schema
        self.dialect = dialect
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 660, height: 540)
        super.init(window: window)
        window.contentView = makeContent()
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isNewTable: Bool { newRadio.state == .on }

    /// Shows the sheet, loads the target's columns and asks for a file.
    func begin(on parent: NSWindow, file: URL? = nil) {
        guard let window else { return }
        keepAlive = self
        parent.beginSheet(window) { [weak self] _ in self?.keepAlive = nil }
        Task {
            await targetChanged()
            if let file { load(file) } else { chooseFile(nil) }
        }
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Import \(format.title)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile(_:)))

        for t in tables { tablePopup.addItem(withTitle: t.name) }
        if let target, let i = tables.firstIndex(of: target) { tablePopup.selectItem(at: i) }
        existingRadio.state = tables.isEmpty ? .off : .on
        existingRadio.isEnabled = !tables.isEmpty
        newRadio.state = tables.isEmpty ? .on : .off
        for control in [existingRadio, newRadio] {
            control.target = self
            control.action = #selector(targetKindChanged(_:))
        }
        tablePopup.target = self
        tablePopup.action = #selector(targetKindChanged(_:))
        newNameField.placeholderString = "new_table"
        newNameField.delegate = self
        newNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        for (title, _) in Self.delimiters { delimiterPopup.addItem(withTitle: title) }
        quotePopup.addItems(withTitles: ["\" (double)", "' (single)"])
        encodingPopup.addItems(withTitles: ["Automatic", "UTF-8", "Windows Latin 1", "Mac Roman"])
        headerBox.state = .on
        for control in [delimiterPopup, quotePopup, encodingPopup] as [NSPopUpButton] {
            control.target = self
            control.action = #selector(parsingChanged(_:))
        }
        for box in [headerBox, commaBox] {
            box.target = self
            box.action = #selector(parsingChanged(_:))
        }
        matchPopup.addItems(withTitles: ["Match columns by name", "Match columns by order"])
        matchPopup.target = self
        matchPopup.action = #selector(matchChanged(_:))
        duplicatePopup.addItems(withTitles: ["Stop on an existing key", "Update rows with an existing key"])
        duplicatePopup.target = self
        duplicatePopup.action = #selector(optionChanged(_:))
        nullBox.target = self
        nullBox.action = #selector(optionChanged(_:))

        previewTable.headerView = NSTableHeaderView()
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.columnAutoresizingStyle = .noColumnAutoresizing
        previewTable.rowSizeStyle = .small
        previewTable.dataSource = self
        previewTable.delegate = self
        let previewScroll = scroll(previewTable)

        mappingTable.rowSizeStyle = .medium
        mappingTable.dataSource = self
        mappingTable.delegate = self
        let mappingScroll = scroll(mappingTable)

        let previewLabel = NSTextField(labelWithString: "File preview (first \(Self.previewRows) rows)")
        let mappingLabel = NSTextField(labelWithString: "Columns")
        for l in [previewLabel, mappingLabel] { l.font = .systemFont(ofSize: 11, weight: .medium) }

        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.isHidden = true
        progress.minValue = 0
        progress.maxValue = 1
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        importButton.target = self
        importButton.action = #selector(importClicked(_:))
        importButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let parsing = row(label("Delimiter"), delimiterPopup, label("Quote"), quotePopup, label("Encoding"), encodingPopup, headerBox)
        csvRows = [parsing]
        let values = format == .csv ? row(nullBox, commaBox) : row(commaBox)
        let views: [NSView] = [
            title,
            row(choose, fileLabel),
            row(label("Into"), existingRadio, tablePopup, newRadio, newNameField),
            parsing, values,
            previewLabel, previewScroll,
            row(mappingLabel, NSView(), matchPopup, duplicatePopup),
            mappingScroll, hint, progress,
            row(status, NSView(), cancelButton, importButton),
        ]
        parsing.isHidden = format != .csv
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in views where v !== title {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        mappingScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
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

    // MARK: - Target

    @objc private func targetKindChanged(_ sender: Any?) {
        if sender as? NSButton === newRadio || sender as? NSButton === existingRadio {
            existingRadio.state = sender as? NSButton === existingRadio ? .on : .off
            newRadio.state = sender as? NSButton === newRadio ? .on : .off
        }
        Task { await targetChanged() }
    }

    /// Makes the sheet import into a new table named `name`. For the dev harness.
    func chooseNewTable(_ name: String) {
        existingRadio.state = .off
        newRadio.state = .on
        newNameField.stringValue = name
        Task { await targetChanged() }
    }

    /// The target's controls at once, then (existing table) its columns.
    private func targetChanged() async {
        let generation = targetGeneration &+ 1
        targetGeneration = generation
        tablePopup.isEnabled = !isNewTable
        newNameField.isEnabled = isNewTable
        matchPopup.isHidden = isNewTable
        duplicatePopup.isHidden = isNewTable
        columns = []
        if isNewTable {
            if newNameField.stringValue.isEmpty, let file = fileURL {
                newNameField.stringValue = Self.tableName(from: file)
            }
            rebuildDesign()
        } else {
            design = nil
            let t = tables[safe: tablePopup.indexOfSelectedItem]
            target = t
            remap()
            rebuildMappingColumns()
            if let t {
                do {
                    let (connection, closeAfter) = try await session()
                    let loaded = try await connection.columns(of: t)
                    if closeAfter { await connection.close() }
                    // A later choice wins.
                    guard generation == targetGeneration else { return }
                    columns = loaded
                } catch {
                    showStatus("Couldn't read the columns of \(t.name): \(error)", error: true)
                }
            }
            remap()
        }
        rebuildMappingColumns()
        updateState()
    }
    private var targetGeneration = 0

    /// A table name from a file name: lowercase letters, digits and underscores.
    static func tableName(from file: URL) -> String {
        let base = file.deletingPathExtension().lastPathComponent.lowercased()
        let cleaned = String(base.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return cleaned.isEmpty ? "imported" : (cleaned.first!.isNumber ? "t_" + cleaned : cleaned)
    }

    // MARK: - File and parsing

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a \(format.title) file to import"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText, .tabSeparatedText, .plainText, .text] : [.json, .text]
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    func load(_ url: URL) {
        fileURL = url
        var label = (url.path as NSString).abbreviatingWithTildeInPath
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            label += " — " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        fileLabel.stringValue = label
        fileLabel.textColor = .labelColor
        if newNameField.stringValue.isEmpty { newNameField.stringValue = Self.tableName(from: url) }
        parse()
    }

    private var csvOptions: CSVReader {
        CSVReader(
            delimiter: Self.delimiters[max(0, delimiterPopup.indexOfSelectedItem)].1,
            quote: quotePopup.indexOfSelectedItem == 1 ? "'" : "\"",
            firstLineIsHeader: headerBox.state == .on,
            encoding: CSVReader.Encoding.allCases[max(0, encodingPopup.indexOfSelectedItem)])
    }

    /// A fresh reader over the whole file.
    private func reader() throws -> any ImportRecords {
        guard let fileURL else { throw DatabaseError("Choose a file first.") }
        switch format {
        case .csv: return try CSVRecordReader(url: fileURL, options: csvOptions)
        case .json: return try JSONRecordReader(url: fileURL)
        }
    }

    private func parse() {
        guard fileURL != nil else { return }
        do {
            let r = try reader()
            columnNames = r.columnNames
            hasNames = r.hasNames
            preview = try r.take(Self.previewRows)
            showStatus("", error: false)
        } catch {
            columnNames = []
            preview = []
            showStatus("\(error)", error: true)
        }
        rebuildPreview()
        if isNewTable { rebuildDesign() } else { remap() }
        rebuildMappingColumns()
        updateState()
    }

    @objc private func parsingChanged(_ sender: Any?) { parse() }

    @objc private func matchChanged(_ sender: Any?) { remap() }

    @objc private func optionChanged(_ sender: Any?) { updateState() }

    private var match: CSVImportPlan.Match { matchPopup.indexOfSelectedItem == 1 ? .byOrder : .byName }

    /// The automatic mapping for the chosen strategy.
    private func remap() {
        let effective: CSVImportPlan.Match = hasNames ? match : .byOrder
        mapping = CSVImportPlan.mapping(for: columns, source: hasNames ? columnNames : nil, sourceCount: columnNames.count, match: effective)
        mappingTable.reloadData()
        updateState()
    }

    /// Guesses the new table's columns from the first records of the file.
    private func rebuildDesign() {
        guard fileURL != nil, !columnNames.isEmpty else {
            design = nil
            mappingTable.reloadData()
            return
        }
        let name = newNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let sample = (try? reader().take(importScanLimit)) ?? preview
        design = ImportTableDesign.guess(table: TableRef(schema: schema, name), names: columnNames, hasNames: hasNames,
                                         records: sample, dialect: dialect, decimalComma: commaBox.state == .on)
        mappingTable.reloadData()
    }

    private func rebuildPreview() {
        for c in previewTable.tableColumns.reversed() { previewTable.removeTableColumn(c) }
        for (i, name) in columnNames.enumerated() {
            let c = NSTableColumn(identifier: .init(String(i)))
            c.title = name
            c.width = 110
            previewTable.addTableColumn(c)
        }
        previewTable.reloadData()
    }

    private func rebuildMappingColumns() {
        for c in mappingTable.tableColumns.reversed() { mappingTable.removeTableColumn(c) }
        let layout: [(String, String, Double)] = isNewTable
            ? [("include", "", 24), ("file", "File column", 200), ("name", "Column name", 200), ("type", "Type", 200)]
            : [("target", "Table column", 240), ("source", "From file column", 260)]
        for (id, title, width) in layout {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            mappingTable.addTableColumn(c)
        }
        mappingTable.reloadData()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === previewTable { return preview.count }
        return isNewTable ? design?.columns.count ?? 0 : columns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier.rawValue
        if tableView === previewTable {
            guard let i = Int(id), i < preview[row].fields.count else { return nil }
            let field = preview[row].fields[i]
            let isNull = field.text.isEmpty && !field.quoted
            let text = NSTextField(labelWithString: isNull ? "NULL" : field.text.replacing(/\r\n|\r|\n/, with: " "))
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 11)
            if isNull { text.textColor = .tertiaryLabelColor }
            return text
        }
        if isNewTable, let design {
            let column = design.columns[row]
            switch id {
            case "include":
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(includeChanged(_:)))
                box.state = column.include ? .on : .off
                box.tag = row
                return CenteredCell(box, centerX: true)
            case "file":
                let text = NSTextField(labelWithString: columnNames[safe: row] ?? "")
                text.lineBreakMode = .byTruncatingTail
                return CenteredCell(text)
            case "name":
                let field = NSTextField(string: column.name)
                field.tag = row
                field.identifier = .init("name")
                field.delegate = self
                field.isEnabled = column.include
                return field
            default:
                let combo = NSComboBox()
                combo.addItems(withObjectValues: dialect.commonTypes)
                combo.stringValue = column.typeName
                combo.tag = row
                combo.identifier = .init("type")
                combo.delegate = self
                combo.target = self
                combo.action = #selector(typeChosen(_:))
                combo.isEnabled = column.include
                return combo
            }
        }
        let column = columns[row]
        if id == "target" {
            var name = column.name + (column.typeName.isEmpty ? "" : "  \(column.typeName)")
            if column.primaryKeyPosition != nil { name += "  (key)" }
            let text = NSTextField(labelWithString: name)
            text.lineBreakMode = .byTruncatingTail
            return CenteredCell(text)
        }
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItem(withTitle: "Don't import")
        for name in columnNames { popup.addItem(withTitle: name) }
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

    @objc private func includeChanged(_ sender: NSButton) {
        guard design?.columns.indices.contains(sender.tag) == true else { return }
        design!.columns[sender.tag].include = sender.state == .on
        mappingTable.reloadData(forRowIndexes: [sender.tag], columnIndexes: IndexSet(0..<mappingTable.numberOfColumns))
        updateState()
    }

    @objc private func typeChosen(_ sender: NSComboBox) {
        guard design?.columns.indices.contains(sender.tag) == true else { return }
        design!.columns[sender.tag].typeName = sender.stringValue
        updateState()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === newNameField {
            design?.table = TableRef(schema: schema, newNameField.stringValue.trimmingCharacters(in: .whitespaces))
        } else if design?.columns.indices.contains(field.tag) == true {
            if field.identifier?.rawValue == "name" { design!.columns[field.tag].name = field.stringValue }
            if field.identifier?.rawValue == "type" { design!.columns[field.tag].typeName = field.stringValue }
        }
        updateState()
    }

    /// Maps target column `name` to file column `source` (nil: don't import). For the dev harness.
    func setMapping(_ name: String, to source: Int?) {
        guard let i = columns.firstIndex(where: { $0.name == name }) else { return }
        mapping[i] = source
        mappingTable.reloadData()
        updateState()
    }

    /// Ticks "Numbers use a decimal comma". For the dev harness.
    func setDecimalComma(_ on: Bool) {
        commaBox.state = on ? .on : .off
        parsingChanged(nil)
    }

    /// Sets a new table's column type. For the dev harness.
    func setType(_ type: String, ofColumn index: Int) {
        guard design?.columns.indices.contains(index) == true else { return }
        design!.columns[index].typeName = type
        mappingTable.reloadData()
        updateState()
    }

    // MARK: - Importing

    /// The plan, and the CREATE TABLE when the table is new.
    private func plan() throws -> (CSVImportPlan, DDLPlan?) {
        let comma = commaBox.state == .on
        if isNewTable {
            guard let design else { throw DatabaseError("Choose a file first.") }
            let name = design.table.name
            if nameTaken(name) { throw DatabaseError("A table or view named \(name) exists already.") }
            let ddl = try design.plan(dialect)
            return (CSVImportPlan(table: design.table, columns: design.tableColumns, mapping: design.mapping, nullWord: nullBox.state == .on,
                                  decimalComma: comma), ddl)
        }
        guard let target else { throw DatabaseError("Choose the table to import into.") }
        return (CSVImportPlan(table: target, columns: columns, mapping: mapping,
                              onDuplicate: duplicatePopup.indexOfSelectedItem == 1 ? .update : .stop,
                              nullWord: nullBox.state == .on, decimalComma: comma), nil)
    }

    private func updateState() {
        duplicatePopup.isEnabled = !columns.primaryKey.isEmpty
        if columns.primaryKey.isEmpty { duplicatePopup.selectItem(at: 0) }
        hint.stringValue = format == .csv
            ? "An empty field is NULL; a quoted empty field (\"\") is an empty string. Columns not imported get their default."
            : "null and missing keys are NULL; nested objects and arrays are imported as JSON text. Columns not imported get their default."
        if isNewTable { hint.stringValue += " Types are guessed from the first \(importScanLimit.formatted()) rows." }
        guard !isRunning else { return }
        guard fileURL != nil, !columnNames.isEmpty else {
            importButton.isEnabled = false
            return
        }
        do {
            let (p, ddl) = try plan()
            try p.validate()
            importButton.isEnabled = true
            let mapped = p.mapping.compactMap { $0 }.count
            let what = ddl == nil ? "\(mapped) of \(columns.count) columns mapped" : "a new table with \(p.columns.count) column\(p.columns.count == 1 ? "" : "s")"
            showStatus("\(columnNames.count) column\(columnNames.count == 1 ? "" : "s") in the file; \(what).", error: false)
        } catch {
            importButton.isEnabled = false
            showStatus("\(error)", error: true)
        }
    }

    @objc private func importClicked(_ sender: Any?) { startImport() }

    /// Runs the import with the options shown. The dev harness calls this directly.
    func startImport() {
        guard !isRunning else { return }
        let planned: (CSVImportPlan, DDLPlan?)
        let statements: [String]
        do {
            planned = try plan()
            statements = (planned.1?.statements.map { $0 + ";" } ?? [])
                + (try planned.0.preview(rows: preview.map(\.fields), dialect: dialect))
        } catch {
            return showStatus("\(error)", error: true)
        }
        let (plan, creating) = planned
        let records: any ImportRecords
        do { records = try reader() } catch { return showStatus("\(error)", error: true) }
        importButton.isEnabled = false
        cancelButton.title = "Stop"
        let box = UncheckedRecords(records)
        task = Task {
            var approved = await confirm(statements)
            if approved, creating == nil { approved = await prepare(plan.table) }
            guard approved else {
                task = nil
                cancelButton.title = "Cancel"
                updateState()
                return
            }
            progress.isHidden = false
            progress.doubleValue = 0
            showStatus("Importing…", error: false)
            let result: Result<Int, any Error>
            do {
                let (connection, closeAfter) = try await session()
                do {
                    let n = try await plan.run(box.records, on: connection, creating: creating) { rows, fraction in
                        Task { @MainActor in self.progressed(rows, fraction) }
                    }
                    result = .success(n)
                } catch {
                    result = .failure(error)
                }
                if closeAfter { await connection.close() }
            } catch {
                result = .failure(error)
            }
            task = nil
            progress.isHidden = true
            cancelButton.title = "Cancel"
            switch result {
            case .success(let n):
                onImported?(plan.table, n, creating != nil)
                onFinish?(result)
                close()
            case .failure(let error):
                let stopped = error is CancellationError
                showStatus(stopped ? "Stopped. Nothing was imported." : "\(error)", error: !stopped)
                importButton.isEnabled = true
                onFinish?(result)
            }
        }
    }

    private func progressed(_ rows: Int, _ fraction: Double) {
        guard isRunning else { return }
        progress.doubleValue = fraction
        showStatus("Importing… \(rows.formatted()) rows sent", error: false)
    }

    private func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancelClicked(_ sender: Any?) {
        if let task {
            // Stop: the transaction rolls back.
            task.cancel()
            return
        }
        close()
    }

    override func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { super.close() }
    }
}

/// A reader handed to the import task.
private final class UncheckedRecords: @unchecked Sendable {
    let records: any ImportRecords
    init(_ records: any ImportRecords) { self.records = records }
}
