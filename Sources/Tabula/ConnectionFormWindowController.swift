import AppCore
import AppKit

/// Creates or edits a saved connection. Only SQLite exists so far; other drivers get their
/// own field sets in M4.
@MainActor
final class ConnectionFormWindowController: NSWindowController, NSWindowDelegate {
    private(set) var config: ConnectionConfig
    private let isNew: Bool
    private let store: ConnectionStore

    /// Asked to connect with the saved config.
    var onConnect: ((ConnectionConfig) -> Void)?
    var onClose: (() -> Void)?

    private let nameField = NSTextField()
    private let pathField = NSTextField()
    private let readOnlyBox = NSButton(checkboxWithTitle: "Open read-only", target: nil, action: nil)
    private let pageSizeField = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var testTask: Task<Void, Never>?

    init(config: ConnectionConfig, isNew: Bool, store: ConnectionStore) {
        self.config = config
        self.isNew = isNew
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = isNew ? "New SQLite Connection" : "Edit \(config.displayName)"
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        show(config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        testTask?.cancel()
        onClose?()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        nameField.placeholderString = "Defaults to the file name"
        pathField.placeholderString = "/path/to/database.sqlite"
        pathField.lineBreakMode = .byTruncatingMiddle
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFile(_:)))
        let pathRow = NSStackView(views: [pathField, choose])
        pathRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Database file"), pathRow],
            [NSGridCell.emptyContentView, readOnlyBox],
            [label("Rows per page"), pageSizeRow()],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 6

        let test = NSButton(title: "Test", target: self, action: #selector(testClicked(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectClicked(_:)))
        connect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [test, NSView(), cancel, save, connect])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true

        let root = NSView()
        root.addSubview(stack)
        stack.pin(to: root)
        return root
    }

    private func pageSizeRow() -> NSView {
        pageSizeField.placeholderString = "All"
        pageSizeField.alignment = .right
        pageSizeField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let hint = NSTextField(labelWithString: "Empty or 0 shows every row")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [pageSizeField, hint])
        row.spacing = 8
        return row
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Model

    private func show(_ c: ConnectionConfig) {
        nameField.stringValue = c.name
        pathField.stringValue = c.filePath
        readOnlyBox.state = c.readOnly ? .on : .off
        pageSizeField.stringValue = c.rowsPerPage > 0 ? String(c.rowsPerPage) : ""
    }

    /// The config as the fields currently describe it.
    private func edited() -> ConnectionConfig {
        var c = config
        c.filePath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = (c.filePath as NSString).lastPathComponent }
        c.readOnly = readOnlyBox.state == .on
        c.rowsPerPage = Int(pageSizeField.stringValue.filter(\.isNumber)) ?? 0
        return c
    }

    private func setStatus(_ text: String, ok: Bool) {
        status.stringValue = text
        status.textColor = ok ? .systemGreen : .systemRed
    }

    @discardableResult
    private func saveEdits() -> Bool {
        let c = edited()
        guard !c.filePath.isEmpty else {
            setStatus("Choose a database file first.", ok: false)
            return false
        }
        do {
            try store.save(c)
            config = c
            return true
        } catch {
            setStatus("Couldn't save: \(error.localizedDescription)", ok: false)
            return false
        }
    }

    // MARK: - Actions

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a SQLite database"
        let current = edited().expandedFilePath
        if !current.isEmpty { panel.directoryURL = URL(filePath: current).deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.pathField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self.status.stringValue = ""
        }
    }

    @objc private func testClicked(_ sender: Any?) {
        let c = edited()
        testTask?.cancel()
        spinner.startAnimation(nil)
        status.stringValue = ""
        testTask = Task {
            defer { spinner.stopAnimation(nil) }
            do {
                try await ConnectionFactory.test(c)
                guard !Task.isCancelled else { return }
                setStatus("Connection works.", ok: true)
            } catch {
                guard !Task.isCancelled else { return }
                setStatus("\(error)", ok: false)
            }
        }
    }

    @objc private func saveClicked(_ sender: Any?) {
        if saveEdits() { close() }
    }

    /// Connect saves first, so a connection that worked is never lost.
    @objc private func connectClicked(_ sender: Any?) {
        guard saveEdits() else { return }
        onConnect?(config)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }
}
