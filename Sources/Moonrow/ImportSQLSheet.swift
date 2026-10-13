import AppCore
import AppKit
import DBKit

/// File ▸ Import ▸ From SQL File…: runs a SQL script or dump (plain or gzip) statement by
/// statement, with progress and Stop, on a session of its own that starts in the workspace's
/// schema. pg_dump's COPY data and psql's `\` commands are handled; MySQL's `DELIMITER` and
/// `/*!…*/` too.
@MainActor
final class ImportSQLSheetController: NSWindowController {
    private let target: String
    /// The connection the file runs on, already in the right schema.
    var session: () async throws -> (connection: any DatabaseConnection, closeAfter: Bool)
    /// Asked before anything runs, with the first statements (safe mode).
    var confirm: ([String]) async -> Bool = { _ in true }
    /// After a run that sent anything, even one that failed or was stopped.
    var onRan: (() -> Void)?
    /// For the dev harness.
    var onFinish: ((Result<SQLFileImport.Summary, any Error>) -> Void)?
    private let dialect: any Dialect

    private var keepAlive: ImportSQLSheetController?
    private(set) var fileURL: URL?
    private var task: Task<Void, Never>?

    private let fileLabel = NSTextField(labelWithString: "No file chosen")
    private let encodingPopup = NSPopUpButton()
    private let continueBox = NSButton(checkboxWithTitle: "Continue after errors", target: nil, action: nil)
    private let previewView = NSTextView()
    private let messagesView = NSTextView()
    private var messagesScroll: NSScrollView!
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private static let encodings: [(String, String.Encoding)] = [("UTF-8", .utf8), ("Windows Latin 1", .windowsCP1252), ("Mac Roman", .macOSRoman)]
    private static let previewCharacters = 100_000

    init(target: String, dialect: any Dialect, session: @escaping () async throws -> (connection: any DatabaseConnection, closeAfter: Bool)) {
        self.target = target
        self.dialect = dialect
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 560, height: 440)
        super.init(window: window)
        window.contentView = makeContent()
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func begin(on parent: NSWindow, file: URL? = nil) {
        guard let window else { return }
        keepAlive = self
        parent.beginSheet(window) { [weak self] _ in self?.keepAlive = nil }
        if let file { load(file) } else { chooseFile(nil) }
    }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Import SQL File into \(target)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile(_:)))
        for (name, _) in Self.encodings { encodingPopup.addItem(withTitle: name) }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))

        let previewScroll = textScroll(previewView)
        messagesScroll = textScroll(messagesView)
        messagesScroll.isHidden = true
        let previewLabel = NSTextField(labelWithString: "Preview (first \(Self.previewCharacters.formatted()) characters)")
        previewLabel.font = .systemFont(ofSize: 11, weight: .medium)

        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        runButton.target = self
        runButton.action = #selector(runClicked(_:))
        runButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let encodingRow = NSStackView(views: [NSTextField(labelWithString: "Encoding"), encodingPopup, continueBox])
        encodingRow.spacing = 8
        let views: [NSView] = [
            title, NSStackView(views: [choose, fileLabel]), encodingRow, previewLabel, previewScroll, messagesScroll, progress,
            NSStackView(views: [status, NSView(), cancelButton, runButton]),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in views where v !== title { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        messagesScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        return stack
    }

    private func textScroll(_ view: NSTextView) -> NSScrollView {
        view.isEditable = false
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let s = NSScrollView()
        s.documentView = view
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
        s.setContentHuggingPriority(.init(1), for: .vertical)
        return s
    }

    private var encoding: String.Encoding { Self.encodings[max(0, encodingPopup.indexOfSelectedItem)].1 }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a SQL file (plain or .gz) to run on \(target)"
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
        showPreview()
        updateState()
    }

    @objc private func encodingChanged(_ sender: Any?) { showPreview() }

    private func showPreview() {
        guard let fileURL else { return }
        do {
            let bytes = try FileBytes(url: fileURL)
            var data = Data()
            while data.count < Self.previewCharacters * 2, let piece = try bytes.read() { data.append(piece) }
            var text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
            if text.count > Self.previewCharacters { text = String(text.prefix(Self.previewCharacters)) + "\n…" }
            previewView.string = text
            showStatus(bytes.isCompressed ? "gzip-compressed; it's decompressed as it runs." : "", error: false)
        } catch {
            previewView.string = ""
            showStatus("\(error)", error: true)
        }
    }

    private func updateState() {
        guard task == nil else { return }
        runButton.isEnabled = fileURL != nil
    }

    @objc private func runClicked(_ sender: Any?) { start() }

    /// Runs the file with the options shown. The dev harness calls this directly.
    func start() {
        guard let fileURL, task == nil else { return }
        let job = SQLFileImport(url: fileURL, encoding: encoding, continueOnError: continueBox.state == .on)
        let first: [String]
        do { first = try job.firstStatements(5, dialect: dialect) } catch { return showStatus("\(error)", error: true) }
        runButton.isEnabled = false
        cancelButton.title = "Stop"
        messagesView.string = ""
        messagesScroll.isHidden = true
        task = Task {
            guard await confirm(first) else {
                task = nil
                cancelButton.title = "Cancel"
                updateState()
                return
            }
            progress.isHidden = false
            progress.doubleValue = 0
            showStatus("Running…", error: false)
            let result: Result<SQLFileImport.Summary, any Error>
            var ran = false
            do {
                let (connection, closeAfter) = try await session()
                ran = true
                do {
                    result = .success(try await job.run(on: connection) { p in
                        Task { @MainActor in self.progressed(p) }
                    })
                } catch {
                    result = .failure(error)
                }
                if closeAfter { await connection.close() }
            } catch {
                result = .failure(error)
            }
            task = nil
            progress.isHidden = true
            cancelButton.title = "Done"
            runButton.isEnabled = true
            if ran { onRan?() }
            finished(result)
        }
    }

    private func progressed(_ p: SQLFileImport.Progress) {
        guard task != nil else { return }
        progress.doubleValue = p.fraction
        let failed = p.failed > 0 ? ", \(p.failed) failed" : ""
        showStatus("\(p.statements.formatted()) statements run\(failed)" + (p.current.isEmpty ? "" : " — \(p.current)"), error: false)
    }

    private func finished(_ result: Result<SQLFileImport.Summary, any Error>) {
        switch result {
        case .success(let s):
            var lines = s.failed.map { "Failed: \($0)" }
            lines += s.skipped.map { "Skipped psql command, \($0)" }
            if !lines.isEmpty {
                messagesView.string = lines.joined(separator: "\n")
                messagesScroll.isHidden = false
            }
            let failed = s.failed.isEmpty ? "" : "; \(s.failed.count) failed"
            showStatus("Ran \(s.statements.formatted()) statement\(s.statements == 1 ? "" : "s")\(failed).", error: !s.failed.isEmpty)
        case .failure(let error):
            if error is CancellationError {
                showStatus("Stopped. Statements that ran before stay applied.", error: false)
            } else {
                let e = error as? DatabaseError
                showStatus(e?.message ?? "\(error)", error: true)
                if let sql = e?.sql {
                    messagesView.string = sql
                    messagesScroll.isHidden = false
                }
            }
        }
        onFinish?(result)
    }

    private func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.toolTip = text
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
}
