import AppCore
import AppKit
import DBKit

extension DevHarness {
    /// `MOONROW_TRANSFER=<table>`: M11's export, import, backup and restore through the real
    /// sheets and windows. It commits (new tables `m11_*`, rows in them; on servers a restored
    /// database it drops again): point it at a copy of a SQLite file or a scratch server
    /// database. Files go to `MOONROW_SNAPSHOTS`.
    ///
    /// Steps: Export Tables… as Excel, CSV (a folder) and gzipped SQL; ⌘E as Excel; a CSV with a
    /// decimal comma into a new table (types guessed); JSON into that table; a large CSV stopped
    /// halfway (nothing imported); a SQL file run with progress; Settings ▸ Locations; and with
    /// `MOONROW_CONNECT` (Postgres, MySQL, MariaDB) Backup of the database and Restore into a new
    /// database.
    static func transferDemo(_ app: AppDelegate, table: String, snapshots: URL?) async throws {
        let dir = try require(snapshots, "MOONROW_SNAPSHOTS (the files are written there)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func snap(_ name: String, _ window: NSWindow?) {
            window?.layoutIfNeeded()
            window?.displayIfNeeded()
            if let window { snapshot(window, to: dir.appending(path: name)) }
        }
        func check(_ ok: Bool, _ what: String) throws {
            guard ok else { throw HarnessError("expected: \(what)") }
            print("ok: \(what)")
        }
        func send(_ action: Selector) {
            NSApp.sendAction(action, to: nil, from: nil)
        }
        let workspace = try await waitFor("workspace") { app.workspaces.first }
        let window = try require(workspace.window, "workspace window")
        try await makeKey(window)
        let connection = workspace.connection
        let dialect = connection.dialect
        func count(_ name: String) async throws -> Int {
            let result = try await connection.execute(SQLStatement("SELECT count(*) FROM \(dialect.quoteIdentifier(name))"))
            guard case .integer(let n)? = result.rows.first?.first else { throw HarnessError("no count for \(name)") }
            return Int(n)
        }
        func sheet<T>(_ type: T.Type) async throws -> T {
            try await waitFor("\(type) sheet") { window.attachedSheet?.windowController as? T }
        }
        func sheetGone() async throws {
            _ = try await waitFor("sheet closed") { window.attachedSheet == nil ? true : nil }
        }
        // Leftovers of an earlier run.
        for name in ["m11_imported", "m11_script"] {
            _ = try? await connection.execute(SQLStatement("DROP TABLE IF EXISTS \(dialect.quoteIdentifier(name))"))
        }
        workspace.sidebar.reload()
        _ = try await waitFor("sidebar item \(table)") { workspace.sidebar.select(named: table) ? true : nil }
        let tab = try await waitFor("table tab") { workspace.tableTab }
        let data = try await waitFor("table view") { tab.data }
        _ = try await waitFor("rows") { data.cache }
        let other = try require(workspace.environment.catalog.objects.first { $0.kind == .table && $0.ref.name != table }, "a second table")

        // MARK: Export Tables…
        send(#selector(MoonrowActions.exportTables(_:)))
        let tables = try await sheet(ExportTablesSheetController.self)
        try check(tables.rows.filter(\.selected).map(\.object.ref.name) == [table], "Export Tables starts with the open table ticked")
        tables.select([table, other.ref.name])
        func exportTables(_ format: Int, to url: URL, _ label: String) async throws -> [URL] {
            tables.options.selectFormat(format)
            var outcome: Result<[URL], any Error>?
            tables.onFinish = { outcome = $0 }
            tables.export(to: url)
            let files = try await waitFor("\(label) export") { outcome }.get()
            print("\(label): \(files.map(\.lastPathComponent))")
            return files
        }
        tables.options.selectFormat(3)
        snap("transfer-01-export-tables.png", tables.window)
        let book = dir.appending(path: "m11-tables.xlsx")
        _ = try await exportTables(3, to: book, "Excel")
        try check(FileManager.default.fileExists(atPath: book.path), "one workbook for two tables")
        let folder = dir.appending(path: "m11-csv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csvFiles = try await exportTables(0, to: folder, "CSV")
        try check(csvFiles.count == 2, "a CSV file per table")
        tables.options.selectFormat(2)
        tables.options.setGzip(true)
        snap("transfer-02-export-tables-sql.png", tables.window)
        let script = dir.appending(path: "m11-tables.sql.gz")
        _ = try await exportTables(2, to: script, "SQL")
        let text = String(decoding: try GzipReader.decompress(script), as: UTF8.self)
        try check(text.hasPrefix("-- Exported by Moonrow") && text.contains("INSERT INTO"), "one gzipped SQL script")
        tables.options.setGzip(false)
        tables.close()
        try await sheetGone()

        // MARK: ⌘E as Excel
        try await pressMenu(#selector(MoonrowActions.exportData(_:)), in: window)
        let single = try await sheet(ExportSheetController.self)
        single.selectFormat(3)
        try check(single.defaultFileName == "\(table).xlsx", "⌘E names the file from the pattern")
        snap("transfer-03-export-excel.png", single.window)
        var outcome: Result<Int, any Error>?
        single.onFinish = { outcome = $0 }
        single.export(to: dir.appending(path: "m11-\(table).xlsx"))
        print("⌘E Excel: \(try await waitFor("Excel export") { outcome }.get()) rows")
        single.selectFormat(0)
        single.close()
        try await sheetGone()

        // MARK: A CSV into a new table
        let csv = dir.appending(path: "m11-prices.csv")
        try "id;item;price;day\n1;apple;1,50;2024-01-02\n2;\"pear; ripe\";1.234,5;2024-02-03\n3;fig;;\n".write(to: csv, atomically: true, encoding: .utf8)
        let importer = try require(workspace.importFile(.csv, into: nil, file: csv), "import sheet")
        _ = try await waitFor("file read") { importer.preview.isEmpty ? nil : true }
        importer.chooseNewTable("m11_imported")
        importer.setDecimalComma(true)
        let design = try await waitFor("guessed columns") { importer.design?.columns.count == 4 ? importer.design : nil }
        print("guessed: \(design.columns.map { "\($0.name) \($0.typeName)" })")
        try check(importer.isNewTable && design.columns[2].typeName.lowercased() != "text", "the price column is guessed numeric with a decimal comma")
        snap("transfer-04-import-new-table.png", importer.window)
        var imported: Result<Int, any Error>?
        importer.onFinish = { imported = $0 }
        importer.startImport()
        try check(try await waitFor("CSV import") { imported }.get() == 3, "three rows imported into the new table")
        try await sheetGone()
        _ = try await waitFor("m11_imported listed") { workspace.environment.catalog.objects.contains { $0.ref.name == "m11_imported" } ? true : nil }
        try check(try await count("m11_imported") == 3, "m11_imported has the rows")

        // MARK: JSON into that table
        let json = dir.appending(path: "m11-more.json")
        try #"[{"id": 4, "item": "kiwi", "price": 0.5}, {"item": "lime", "id": 5, "day": "2024-03-04", "extra": true}]"#
            .write(to: json, atomically: true, encoding: .utf8)
        let target = DatabaseObject(TableRef(schema: workspace.sidebar.schema, "m11_imported"), kind: .table)
        let jsonImporter = try require(workspace.importFile(.json, into: target, file: json), "JSON import sheet")
        _ = try await waitFor("JSON read and columns loaded") { jsonImporter.preview.count == 2 && !jsonImporter.columns.isEmpty ? true : nil }
        try check(jsonImporter.mapping.compactMap { $0 }.count == 4, "JSON keys map to the columns by name")
        snap("transfer-05-import-json.png", jsonImporter.window)
        imported = nil
        jsonImporter.onFinish = { imported = $0 }
        jsonImporter.startImport()
        try check(try await waitFor("JSON import") { imported }.get() == 2, "two JSON rows imported")
        try await sheetGone()
        try check(try await count("m11_imported") == 5, "m11_imported has five rows")

        // MARK: A large CSV, stopped
        var big = "id,item\n"
        for i in 0..<200_000 { big += "\(1000 + i),row \(i)\n" }
        let bigURL = dir.appending(path: "m11-big.csv")
        try big.write(to: bigURL, atomically: true, encoding: .utf8)
        let bigImporter = try require(workspace.importFile(.csv, into: target, file: bigURL), "large import sheet")
        _ = try await waitFor("large file read") { bigImporter.preview.isEmpty || bigImporter.columns.isEmpty ? nil : true }
        imported = nil
        bigImporter.onFinish = { imported = $0 }
        bigImporter.startImport()
        try await Task.sleep(for: .milliseconds(150))
        snap("transfer-06-import-running.png", bigImporter.window)
        if imported == nil { try require(descendant(of: bigImporter.window!.contentView!, NSButton.self) { $0.title == "Stop" }, "Stop").performClick(nil) }
        let stopped = try await waitFor("stopped import") { imported }
        var expected = 5
        switch stopped {
        case .failure(let e) where e is CancellationError: print("ok: Stop ends the import")
        case .success(let n):
            print("note: the import finished before Stop")
            expected += n
        case .failure(let e): throw e
        }
        try check(try await count("m11_imported") == expected, "a stopped import leaves nothing")
        snap("transfer-07-import-stopped.png", bigImporter.window)
        bigImporter.close()
        try await sheetGone()

        // MARK: A SQL file
        let sql = dir.appending(path: "m11-script.sql")
        var body = "CREATE TABLE m11_script (id integer PRIMARY KEY, note varchar(40));\n"
        for i in 0..<500 { body += "INSERT INTO m11_script VALUES (\(i), 'note \(i); with a semicolon');\n" }
        try body.write(to: sql, atomically: true, encoding: .utf8)
        send(#selector(MoonrowActions.importSQLFile(_:)))
        // The menu path opens a panel; take the sheet behind it and give it the file instead.
        let runner: ImportSQLSheetController
        if let s = window.attachedSheet?.windowController as? ImportSQLSheetController {
            runner = s
            for panel in NSApp.windows where panel is NSOpenPanel { panel.close() }
            if let panelSheet = s.window?.attachedSheet { s.window?.endSheet(panelSheet) }
            s.load(sql)
        } else {
            runner = try require(workspace.importSQL(file: sql), "SQL file sheet")
        }
        snap("transfer-08-sql-file.png", runner.window)
        var ran: Result<SQLFileImport.Summary, any Error>?
        runner.onFinish = { ran = $0 }
        runner.start()
        let summary = try await waitFor("SQL file run") { ran }.get()
        try check(summary.statements == 501 && summary.failed.isEmpty, "the SQL file ran all 501 statements")
        snap("transfer-09-sql-file-done.png", runner.window)
        runner.close()
        try await sheetGone()
        try check(try await count("m11_script") == 500, "m11_script has the rows")

        // MARK: Settings ▸ Locations
        app.showLocations()
        let prefs = try await waitFor("settings window") { NSApp.windows.first { $0.title == "Locations" && $0.isVisible } }
        try await Task.sleep(for: .seconds(1))
        snap("transfer-10-locations.png", prefs)
        prefs.close()

        // MARK: Backup and Restore (servers)
        guard workspace.config.driver.isServer else {
            print("backup and restore: skipped (SQLite)")
            return
        }
        // The windows list saved connections: save the workspace's (same id, so its login is reused).
        try app.store.save(workspace.config)
        let database = workspace.config.driver == .postgres ? workspace.config.database : (workspace.sidebar.schema ?? workspace.config.database)
        app.backupDatabases(nil)
        let backup = try require(app.backupWindow, "backup window")
        _ = try await waitFor("databases listed") { backup.databases.contains(database) ? true : nil }
        backup.select(database: database)
        try check(backup.selectedDatabase == database, "the workspace's database is selected")
        try await Task.sleep(for: .milliseconds(200))
        snap("transfer-11-backup.png", backup.window)
        // The file name editor: the pattern as tokens, a separator and a placeholder added.
        backup.fileName.openEditor()
        let editor = try await waitFor("file name editor") { backup.fileName.editor }
        try check(editor.pattern == backup.fileName.pattern, "the editor starts at the pattern")
        editor.append("_")
        editor.append("{connection}")
        try check(editor.previewLabel.stringValue.hasPrefix("\(database)-") && editor.previewLabel.stringValue.contains("_\(workspace.config.displayName)"),
                  "the preview follows the pattern: \(editor.previewLabel.stringValue)")
        try await Task.sleep(for: .milliseconds(200))
        snap("transfer-11b-file-name.png", editor.sheet)
        backup.window?.endSheet(editor.sheet)
        var backedUp: Result<Void, any Error>?
        backup.onFinish = { backedUp = $0 }
        let backupFolder = dir.appending(path: "m11-backup")
        try? FileManager.default.removeItem(at: backupFolder)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let file = backupFolder.appending(path: workspace.config.driver == .postgres ? "\(database).dump" : "\(database).sql")
        backup.run(to: file)
        try await waitFor("backup", timeout: 120) { backedUp }.get()
        try check(FileManager.default.fileExists(atPath: file.path), "the backup file exists")
        print("backup: \(file.lastPathComponent), \((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) bytes")
        snap("transfer-12-backup-done.png", backup.runSheet?.sheet)
        backup.runSheet?.onDone()
        backup.close()

        app.restoreDatabase(nil)
        let restore = try require(app.restoreWindow, "restore window")
        _ = try await waitFor("databases listed for restore") { restore.databases.isEmpty ? nil : true }
        let restored = "m11_restored_\(Int.random(in: 1000...9999))"
        try check(await restore.createDatabase(restored), "New Database… creates \(restored)")
        try check(restore.selectedDatabase == restored, "the new database is selected")
        try await Task.sleep(for: .milliseconds(200))
        snap("transfer-13-restore.png", restore.window)
        var restoreResult: Result<Void, any Error>?
        restore.onFinish = { restoreResult = $0 }
        restore.run(try restore.job(for: file).get())
        let restoreOutcome = try await waitFor("restore", timeout: 120) { restoreResult }
        snap("transfer-14-restore-done.png", restore.runSheet?.sheet)
        restore.runSheet?.onDone()
        restore.close()
        try restoreOutcome.get()
        let listed = try await ServerInfo.databases(connection)
        try check(listed.contains(restored), "the restored database exists")
        // Leave no restored database behind (Postgres can't drop the database it's in; we're not in it).
        _ = try? await connection.execute(SQLStatement("DROP DATABASE \(dialect.quoteIdentifier(restored))"))
        try? app.store.delete(id: workspace.config.id)
    }

    static func waitFor<T>(_ what: String, timeout: TimeInterval, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = probe() { return value }
            guard Date() < deadline else { throw HarnessError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
