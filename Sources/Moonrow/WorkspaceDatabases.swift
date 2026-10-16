import AppCore
import AppKit
import DBKit
import DriverPostgres

// Open Database (⌘K): the server's databases. Postgres reconnects the workspace to the chosen
// one (for this window; the saved connection keeps its database), MySQL switches with `USE`.

extension WorkspaceWindowController {
    var isPostgres: Bool { connection is PostgresConnection }

    /// The database the workspace is in: Postgres's (as connected, or switched to with ⌘K;
    /// the user's name when none was given), MySQL's listed one. Nil for SQLite, or MySQL
    /// without a database.
    var currentDatabase: String? {
        if let pg = connection as? PostgresConnection { return pg.database ?? pg.configuration.user }
        return connection.dialect.lexer == .mysql ? sidebar.schema : nil
    }

    /// Postgres: the database ⌘K switched to, when the saved connection names another; kept in
    /// the session so the workspace comes back there.
    var switchedDatabase: String? {
        guard let pg = connection as? PostgresConnection, let now = pg.database else { return nil }
        return now == savedDatabase ? nil : now
    }

    /// Opens ⌘K's window once the workspace window is on screen with nothing over it.
    func offerDatabases() {
        guard let window, !hasOfferedDatabases else { return }
        if window.isVisible, window.attachedSheet == nil {
            hasOfferedDatabases = true
            return openDatabase(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.hasOfferedDatabases, self.sidebar.schema == nil, self.window?.isVisible == true,
                  self.window?.attachedSheet == nil else { return }
            self.hasOfferedDatabases = true
            self.openDatabase(nil)
        }
    }

    @objc func openDatabase(_ sender: Any?) {
        guard DatabaseCatalog.canSwitch(connection), let window, window.attachedSheet == nil else { return NSSound.beep() }
        let picker = DatabasePicker()
        picker.current = currentDatabase
        picker.canRename = isPostgres
        picker.canCreate = !config.readOnly
        picker.onOpen = { [weak self] name in self?.switchDatabase(to: name) }
        picker.onOpenInNewTab = { [weak self] name in self?.onOpenDatabaseInNewTab?(name) }
        picker.onNew = { [weak self, weak picker] in if let picker { self?.newDatabase(in: picker) } }
        picker.onRename = { [weak self, weak picker] name in if let picker { self?.renameDatabase(name, in: picker) } }
        picker.onDrop = { [weak self, weak picker] name in if let picker { self?.dropDatabase(name, in: picker) } }
        picker.onClose = { [weak self, weak picker] in if self?.databasePicker === picker { self?.databasePicker = nil } }
        databasePicker = picker
        picker.begin(on: window)
        reloadDatabases(in: picker)
    }

    private func reloadDatabases(in picker: DatabasePicker, select: String? = nil) {
        let connection = connection
        Task {
            do {
                picker.show(try await DatabaseCatalog.switchable(connection), select: select)
            } catch {
                picker.close()
                present(error, title: "Couldn't list the databases", in: window)
            }
        }
    }

    /// Moves the workspace to `name`. MySQL lists that database (`USE`). Postgres first settles
    /// staged changes (commit or discard, as when closing), then reconnects: the old database's
    /// tabs close, query tabs stay, and the sidebar lists the new database's schemas.
    func switchDatabase(to name: String) {
        guard name != currentDatabase else { return }
        guard isPostgres else {
            leftSidebar.show(.items)
            if !sidebar.switchSchema(to: name) {
                sidebar.schemaToRestore = name
                sidebar.reloadSchemas()
            }
            return
        }
        resolveStagedChanges(before: "Switching to \(name)") { [weak self] in
            guard let self else { return }
            Task { await self.reconnect(to: name) }
        }
    }

    private func reconnect(to name: String) async {
        do {
            try await DatabaseCatalog.switchTo(name, on: connection)
        } catch {
            present(error, title: "Couldn't open \(name)", in: window)
            return
        }
        for pane in panes.panes {
            for tab in pane.tabs where tab is any ObjectTab { closeWithoutAsking(tab) }
        }
        forgetObjectPlaces()
        quickOpenItems = []
        quickOpenRecent = []
        showSubtitle()
        leftSidebar.show(.items)
        sidebar.reloadSchemas()
        onSessionChange?()
    }

    // MARK: - New, rename, drop

    private func newDatabase(in picker: DatabasePicker) {
        guard picker.window.attachedSheet == nil else { return }
        let sheet = NewDatabaseSheet(existing: picker.databases, connection: connection) { [weak self, weak picker] new in
            guard let self, let picker else { return false }
            let sql = DatabaseCatalog.createSQL(new, dialect: self.connection.dialect)
            guard await self.runDatabaseStatement(sql, title: "Create the database \(new.name)?", confirm: "Create",
                                                  on: self.newDatabaseSheet?.sheet ?? picker.window,
                                                  showError: { self.newDatabaseSheet?.show(error: $0) }) else { return false }
            self.reloadDatabases(in: picker, select: new.name)
            if !self.isPostgres { self.sidebar.reloadSchemas() }
            return true
        }
        newDatabaseSheet = sheet
        picker.window.beginSheet(sheet.sheet) { [weak self] _ in self?.newDatabaseSheet = nil }
    }

    private func renameDatabase(_ name: String, in picker: DatabasePicker) {
        guard name != currentDatabase else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Rename “\(name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: picker.window) { [weak self, weak picker] response in
            let new = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !new.isEmpty, new != name, let self, let picker,
                  let sql = DatabaseCatalog.renameSQL(name, to: new, dialect: self.connection.dialect) else { return }
            Task {
                guard await self.runDatabaseStatement(sql, title: "Rename the database \(name)?", confirm: "Rename",
                                                      on: picker.window, showError: nil) else { return }
                self.reloadDatabases(in: picker, select: new)
            }
        }
    }

    private func dropDatabase(_ name: String, in picker: DatabasePicker) {
        guard name != currentDatabase else { return NSSound.beep() }
        let sql = DatabaseCatalog.dropSQL(name, dialect: connection.dialect)
        let alert = NSAlert()
        alert.messageText = "Drop the database “\(name)”?"
        alert.informativeText = "\(sql);\n\nEverything in it is deleted. This can’t be undone."
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: picker.window) { [weak self, weak picker] response in
            guard response == .alertFirstButtonReturn, let self, let picker else { return }
            Task {
                // The confirmation above was the question; password levels still ask for it.
                guard await self.runDatabaseStatement(sql, title: "Drop the database \(name)?", confirm: "Drop",
                                                      on: picker.window, showError: nil, alreadyConfirmed: true) else { return }
                self.reloadDatabases(in: picker)
                if !self.isPostgres { self.sidebar.reloadSchemas() }
            }
        }
    }

    /// Runs a CREATE, ALTER or DROP DATABASE as safe mode allows, asking over `sheetWindow`.
    /// Errors go to `showError`, else an alert. False when it didn't run or failed.
    private func runDatabaseStatement(_ sql: String, title: String, confirm: String, on sheetWindow: NSWindow,
                                      showError: ((String) -> Void)?, alreadyConfirmed: Bool = false) async -> Bool {
        let requirement = safety.requirement(for: [sql])
        if requirement == .password || (requirement == .confirmation && !alreadyConfirmed) {
            let prompt = SafetyPrompt(
                title: title, message: safety.level.detail, sql: sql + ";",
                credential: requirement == .password ? safety.credential : nil, connectionName: config.displayName,
                confirm: confirm)
            guard await prompt.run(on: sheetWindow) else { return false }
        }
        do {
            _ = try await connection.execute(SQLStatement(sql))
            return true
        } catch {
            let message = (error as? DatabaseError)?.message ?? error.localizedDescription
            if let showError { showError(message) } else { present(error, title: "Couldn't run \(sql)", in: sheetWindow) }
            return false
        }
    }
}
