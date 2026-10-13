import AppCore
import AppKit
import DBKit

/// File ▸ Export Tables…: several tables and views at once. CSV and JSON write a file per table
/// into a folder; SQL writes one script (structure, DROP and rows chosen per table); Excel writes
/// one workbook with a sheet per table.
@MainActor
final class ExportTablesSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var object: DatabaseObject
        var selected: Bool
        var structure = true
        var drop = false
        var data = true
    }

    private(set) var rows: [Row]
    private let connection: any DatabaseConnection
    private let context: FileNamePattern.Context
    private var settings: ExportSettings
    private var keepAlive: ExportTablesSheetController?
    private var task: Task<Void, Never>?
    private(set) var written: [URL] = []
    /// For the dev harness: the files written, or the error, when an export ends.
    var onFinish: ((Result<[URL], any Error>) -> Void)?

    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var options: ExportOptionsView!
    private let namesLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)

    init(objects: [DatabaseObject], selected: Set<TableRef>, connection: any DatabaseConnection, context: FileNamePattern.Context) {
        rows = objects.map { Row(object: $0, selected: selected.contains($0.ref)) }
        self.connection = connection
        self.context = context
        var s = ExportSettings.load(.tables)
        if s.pattern.isEmpty { s.pattern = FileNamePattern.export }
        settings = s
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 560, height: 480)
        super.init(window: window)
        window.contentView = makeContent()
        update()
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
        let title = NSTextField(labelWithString: "Export Tables")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        // The name takes what the fixed checkbox columns leave.
        for (id, heading, width) in [("export", "", 28.0), ("name", "Table", 300.0), ("structure", "Structure", 76.0), ("drop", "Drop", 52.0), ("data", "Rows", 52.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = heading
            c.width = width
            if id == "name" {
                c.resizingMask = .autoresizingMask
                c.minWidth = 120
            } else {
                c.resizingMask = []
                c.minWidth = width
                c.headerCell.alignment = .center
            }
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        let all = NSButton(title: "Select All", target: self, action: #selector(selectAllTables(_:)))
        let none = NSButton(title: "Select None", target: self, action: #selector(selectNoTables(_:)))
        for b in [all, none] { b.controlSize = .small }
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        let listButtons = NSStackView(views: [all, none, NSView(), countLabel])

        options = ExportOptionsView(settings: settings, sqlMode: .perTable)
        options.onChange = { [weak self] in self?.update() }
        namesLabel.textColor = .secondaryLabelColor
        namesLabel.font = .systemFont(ofSize: 11)
        namesLabel.lineBreakMode = .byTruncatingTail

        progress.style = .bar
        progress.isHidden = true
        status.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
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

        let views: [NSView] = [title, scroll, listButtons, options, namesLabel, progress, status, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in [scroll, listButtons, namesLabel, progress, status, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        return stack
    }

    // MARK: - List

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        if id == "name" {
            let kind = r.object.kind == .table ? "" : r.object.kind == .view ? "view" : "materialized view"
            let title = NSMutableAttributedString(string: r.object.ref.name)
            if !kind.isEmpty {
                title.append(NSAttributedString(string: "  " + kind, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
            let text = NSTextField(labelWithAttributedString: title)
            text.lineBreakMode = .byTruncatingTail
            return CenteredCell(text)
        }
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.identifier = .init(id)
        box.tag = row
        switch id {
        case "export": box.state = r.selected ? .on : .off
        case "structure": box.state = r.structure ? .on : .off
        case "drop": box.state = r.drop ? .on : .off
        default:
            box.state = r.data && r.object.kind == .table ? .on : .off
            // A view's rows are its tables'.
            box.isEnabled = r.object.kind == .table
        }
        if id != "export" { box.isEnabled = box.isEnabled && r.selected }
        return CenteredCell(box, centerX: id != "export")
    }

    @objc private func toggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), let id = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        // A click on a selected row's box sets every selected row.
        let targets = table.selectedRowIndexes.contains(sender.tag) ? Array(table.selectedRowIndexes) : [sender.tag]
        for i in targets {
            switch id {
            case "export": rows[i].selected = on
            case "structure": rows[i].structure = on
            case "drop": rows[i].drop = on
            default: rows[i].data = on
            }
        }
        table.reloadData()
        update()
    }

    @objc private func selectAllTables(_ sender: Any?) { setAll(true) }
    @objc private func selectNoTables(_ sender: Any?) { setAll(false) }

    /// For the dev harness too.
    func setAll(_ on: Bool) {
        for i in rows.indices { rows[i].selected = on }
        table.reloadData()
        update()
    }

    /// Selects exactly these tables. For the dev harness.
    func select(_ names: Set<String>) {
        for i in rows.indices { rows[i].selected = names.contains(rows[i].object.ref.name) }
        table.reloadData()
        update()
    }

    // MARK: - State

    private func job() -> TablesExportJob {
        let items = rows.filter(\.selected).map { TablesExportJob.Item($0.object, structure: $0.structure, drop: $0.drop, data: $0.data) }
        let pattern = options.edited.pattern
        return TablesExportJob(items: items, format: options.format, connection: connection,
                               pattern: FileNamePattern(pattern.isEmpty ? FileNamePattern.export : pattern), context: context)
    }

    private func update() {
        let isSQL = options.formatControl.selectedSegment == 2
        for id in ["structure", "drop", "data"] { table.tableColumn(withIdentifier: .init(id))?.isHidden = !isSQL }
        let selected = rows.filter(\.selected).count
        countLabel.stringValue = "\(selected) of \(rows.count) selected"
        if task == nil {
            exportButton.isEnabled = selected > 0
            status.stringValue = ""
            revealButton.isHidden = true
            progress.isHidden = true
        }
        let j = job()
        var taken = Set<String>()
        if j.isSingleFile {
            namesLabel.stringValue = "One file: " + j.fileName(for: nil, taken: &taken)
        } else {
            let names = j.items.prefix(3).map { j.fileName(for: $0.object.ref.name, taken: &taken) }
            namesLabel.stringValue = names.isEmpty ? "" : "In a folder: " + names.joined(separator: ", ") + (j.items.count > 3 ? ", …" : "")
        }
        if let window, let content = window.contentView, window.frame.height < content.fittingSize.height {
            window.fit(to: content)
        }
    }

    // MARK: - Exporting

    @objc private func exportClicked(_ sender: Any?) {
        if case .csv(let o) = options.format {
            do { try o.validate() } catch { return showStatus("\(error)", error: true) }
        }
        guard let window else { return }
        let j = job()
        if j.isSingleFile {
            let panel = NSSavePanel()
            var taken = Set<String>()
            panel.nameFieldStringValue = j.fileName(for: nil, taken: &taken)
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.export(to: url)
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose the folder for the files; files with the same names are replaced."
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.export(to: url)
            }
        }
    }

    /// Exports with the options shown, to a folder (CSV, JSON) or a file (SQL, Excel). The dev
    /// harness calls this directly.
    func export(to destination: URL) {
        settings = options.edited
        settings.save(.tables)
        let j = job()
        let names = j.items.map(\.object.ref.name)
        progress.isHidden = false
        progress.isIndeterminate = false
        progress.maxValue = Double(max(1, names.count))
        progress.doubleValue = 0
        exportButton.isEnabled = false
        revealButton.isHidden = true
        cancelButton.title = "Stop"
        showStatus("Exporting…", error: false)
        task = Task {
            let result: Result<[URL], any Error>
            do {
                let files = try await j.run(to: destination) { item, rows in
                    Task { @MainActor in self.progressed(item: item, of: names, rows: rows) }
                }
                result = .success(files)
            } catch {
                result = .failure(error)
            }
            finished(result, destination: destination)
        }
    }

    private func progressed(item: Int, of names: [String], rows: Int) {
        guard task != nil, names.indices.contains(item) else { return }
        progress.doubleValue = Double(item)
        showStatus("Exporting \(names[item]) (\(item + 1) of \(names.count))… \(rows.formatted()) rows", error: false)
    }

    private func finished(_ result: Result<[URL], any Error>, destination: URL) {
        task = nil
        exportButton.isEnabled = true
        progress.isHidden = true
        switch result {
        case .success(let files):
            written = files
            cancelButton.title = "Done"
            revealButton.isHidden = false
            let what = job().isSingleFile ? destination.lastPathComponent : "\(files.count) file\(files.count == 1 ? "" : "s") in \(destination.lastPathComponent)"
            showStatus("Exported \(job().items.count) table\(job().items.count == 1 ? "" : "s") to \(what).", error: false)
        case .failure(let error):
            cancelButton.title = "Cancel"
            let stopped = error is CancellationError
            showStatus(stopped ? "Stopped. Files already finished were kept." : "Export failed: \(error)", error: !stopped)
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
        if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
    }
}

/// A table cell holding one control, centred vertically (and horizontally when asked), so
/// checkboxes and labels line up in rows taller than they are.
final class CenteredCell: NSTableCellView {
    init(_ content: NSView, centerX: Bool = false) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var constraints = [content.centerYAnchor.constraint(equalTo: centerYAnchor)]
        if centerX {
            constraints.append(content.centerXAnchor.constraint(equalTo: centerXAnchor))
        } else {
            constraints += [content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
