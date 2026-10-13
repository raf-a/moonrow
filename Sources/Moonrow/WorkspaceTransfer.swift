import AppCore
import AppKit
import DBKit

// Export (File ▸ Export… ⌘E, Export Tables…, the sidebar, the grids' menus) and import
// (File ▸ Import ▸ From CSV… / From JSON… / From SQL File…, the sidebar, the table grid's menu).

extension WorkspaceWindowController {
    func connectTransferActions() {
        sidebar.onExport = { [weak self] object in self?.export(object) }
        sidebar.onExportTables = { [weak self] in self?.presentExportTables() }
        sidebar.onImport = config.readOnly ? nil : { [weak self] object, format in self?.importFile(format, into: object) }
    }

    /// What file-name patterns fill in.
    var fileNameContext: FileNamePattern.Context {
        let database = sidebar.schema ?? (config.database.isEmpty ? (config.driver == .sqlite ? URL(filePath: config.filePath).deletingPathExtension().lastPathComponent : "") : config.database)
        return FileNamePattern.Context(database: database, connection: config.displayName, tag: tag?.name ?? "")
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

    /// Export Tables…: the schema's tables and views, the ones selected in the sidebar (or the
    /// current tab's) ticked.
    @objc func exportTables(_ sender: Any?) {
        presentExportTables()
    }

    @discardableResult
    func presentExportTables() -> ExportTablesSheetController? {
        guard let window, window.attachedSheet == nil else { NSSound.beep(); return nil }
        let objects = environment.catalog.objects.filter { $0.kind.isRelation }
        guard !objects.isEmpty else { NSSound.beep(); return nil }
        var selected = Set(sidebar.selectedObjects.filter { $0.kind.isRelation }.map(\.ref))
        if selected.isEmpty, let tab = tableTab { selected = [tab.table] }
        let sheet = ExportTablesSheetController(objects: objects, selected: selected, connection: connection, context: fileNameContext)
        sheet.begin(on: window)
        return sheet
    }

    @objc func importCSV(_ sender: Any?) { importFile(.csv, into: currentTableForImport) }
    @objc func importJSON(_ sender: Any?) { importFile(.json, into: currentTableForImport) }

    private var currentTableForImport: DatabaseObject? {
        guard let tab = tableTab, tab.kind == .table, !tab.table.name.isEmpty else { return nil }
        return DatabaseObject(tab.table, kind: .table)
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
        let sheet = ExportSheetController(subject: subject, connection: connection, context: fileNameContext)
        sheet.begin(on: window)
        return sheet
    }

    /// The connection imports run on: a session of its own (its statements in the query log),
    /// in the listed schema, where the workspace can open one.
    func transferSession() async throws -> (connection: any DatabaseConnection, closeAfter: Bool) {
        guard openSession != nil else { return (connection, false) }
        let session = try await openLoggedSession()
        if let schema = sidebar.schema, let use = connection.dialect.useSchema(schema) {
            do {
                _ = try await session.execute(SQLStatement(use))
            } catch {
                await session.close()
                throw error
            }
        }
        return (session, true)
    }

    /// Imports a CSV or JSON file into `object` (a table), or into a new table when nil.
    @discardableResult
    func importFile(_ format: ImportFormat, into object: DatabaseObject?, file: URL? = nil) -> ImportSheetController? {
        guard !config.readOnly else {
            presentReadOnly("Importing")
            return nil
        }
        guard let window, window.attachedSheet == nil else { NSSound.beep(); return nil }
        let tables = environment.catalog.objects.filter { $0.kind == .table }.map(\.ref)
        let sheet = ImportSheetController(format: format, target: object?.ref, tables: tables, schema: sidebar.schema,
                                          dialect: connection.dialect) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.transferSession()
        }
        let names = Set(existingNames.map { $0.lowercased() })
        sheet.nameTaken = { names.contains($0.lowercased()) }
        sheet.confirm = { [weak self] statements in await self?.confirmWrite(statements) ?? false }
        sheet.prepare = { [weak self, weak sheet] table in
            guard let self else { return false }
            return await withCheckedContinuation { c in
                self.resolveEdits(on: DatabaseObject(table, kind: .table), before: "Importing", in: sheet?.window,
                                  then: { c.resume(returning: true) }, cancelled: { c.resume(returning: false) })
            }
        }
        sheet.onImported = { [weak self] table, _, created in
            guard let self else { return }
            for tab in self.tabs(showing: DatabaseObject(table, kind: .table)) { tab.reload() }
            self.sidebar.reload()
            _ = created
        }
        sheet.begin(on: window, file: file)
        return sheet
    }

    @objc func importSQLFile(_ sender: Any?) { importSQL() }

    @discardableResult
    func importSQL(file: URL? = nil) -> ImportSQLSheetController? {
        guard !config.readOnly else {
            presentReadOnly("Running a SQL file")
            return nil
        }
        guard let window, window.attachedSheet == nil else { NSSound.beep(); return nil }
        let target = sidebar.schema ?? config.displayName
        let sheet = ImportSQLSheetController(target: target, dialect: connection.dialect) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.transferSession()
        }
        sheet.confirm = { [weak self] statements in await self?.confirmWrite(statements) ?? false }
        sheet.onRan = { [weak self] in self?.sidebar.reload() }
        sheet.begin(on: window, file: file)
        return sheet
    }

    private func presentReadOnly(_ what: String) {
        let alert = NSAlert()
        alert.messageText = "\(config.displayName) is read-only"
        alert.informativeText = "\(what) writes to the database, and this connection only reads."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
