import AppCore
import AppKit
import DBKit

// Export (File ▸ Export… ⌘E, the sidebar, the grids' menus) and CSV import (File ▸ Import CSV…,
// the sidebar, the table grid's menu).

extension WorkspaceWindowController {
    func connectTransferActions() {
        sidebar.onExport = { [weak self] object in self?.export(object) }
        sidebar.onImportCSV = config.readOnly ? nil : { [weak self] object in self?.importCSV(into: object) }
    }

    /// The selected table tab as its grid shows it, or the selected query tab's shown result.
    @objc func exportData(_ sender: Any?) {
        if let tab = tableTab, !tab.table.name.isEmpty {
            export(DatabaseObject(tab.table, kind: tab.kind))
        } else if let editor = queryController, let result = editor.results.shownResult {
            presentExport(.result(name: "Result \(result.number)", columns: result.columns.map(\.name), rows: result.rows))
        } else {
            NSSound.beep()
        }
    }

    @objc func importCSV(_ sender: Any?) {
        guard let tab = tableTab, tab.kind == .table, !tab.table.name.isEmpty else { return NSSound.beep() }
        importCSV(into: DatabaseObject(tab.table, kind: .table))
    }

    /// A table or view; the grid's filter and sort apply when a tab shows it.
    func export(_ object: DatabaseObject) {
        let data = tableTabs.first { $0.table == object.ref }?.data
        let query = data?.query
        let shown = data.flatMap { $0.cache == nil ? nil : $0.total }
        presentExport(.table(object.ref, kind: object.kind, filter: query?.filter, sort: query?.sort ?? [], shownRows: shown))
    }

    @discardableResult
    func presentExport(_ subject: ExportSubject) -> ExportSheetController? {
        guard let window, window.attachedSheet == nil else { NSSound.beep(); return nil }
        let sheet = ExportSheetController(subject: subject, connection: connection)
        sheet.begin(on: window)
        return sheet
    }

    @discardableResult
    func importCSV(into object: DatabaseObject, file: URL? = nil) -> ImportCSVSheetController? {
        guard !config.readOnly, object.kind == .table else { NSSound.beep(); return nil }
        guard let window, window.attachedSheet == nil else { NSSound.beep(); return nil }
        let sheet = ImportCSVSheetController(table: object.ref, connection: connection)
        sheet.confirm = { [weak self] statements in await self?.confirmWrite(statements) ?? false }
        sheet.onImported = { [weak self] _ in
            guard let self else { return }
            for tab in self.tabs(showing: object) { tab.reload() }
            self.sidebar.reload()
        }
        // Imported rows reload the tabs showing the table, so their staged edits are settled first.
        resolveEdits(on: object, before: "Importing") { sheet.begin(on: window, file: file) }
        return sheet
    }
}
