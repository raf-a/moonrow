import AppCore
import AppKit
import DBKit

// The sidebar's Rename, Truncate, Delete and Copy Script As. Truncate's and Delete's dialogs
// show the SQL, updated as their options change. All three are staged with the workspace's other
// changes, each as one undo step; ⌫ marks items for deletion without a
// dialog.

extension WorkspaceWindowController {
    func connectSidebarActions() {
        sidebar.onOpenStructure = { [weak self] object in self?.open(object, intent: .regular, mode: .structure) }
        sidebar.onNewTable = config.readOnly ? nil : { [weak self] in self?.newTable(nil) }
        sidebar.onRename = { [weak self] object in self?.rename(object) }
        sidebar.onRenameNewTable = { [weak self] id in self?.renameNewTable(id) }
        sidebar.onTruncate = { [weak self] object in self?.truncate(object) }
        sidebar.onDelete = { [weak self] object in self?.delete(object) }
        sidebar.onMarkForDeletion = config.readOnly ? nil : { [weak self] deletion in self?.markForDeletion(deletion) }
        sidebar.onCopyScript = { [weak self] object, script in self?.copyScript(object, script) }
        let dialect = connection.dialect
        sidebar.supportsDefinition = { dialect.supportsDefinitions(of: $0) }
        sidebar.onNewDefinition = config.readOnly ? nil : { [weak self] kind in self?.newDefinition(kind) }
        sidebar.onOpenNewDefinition = { [weak self] id in self?.openNewDefinition(id) }
        sidebar.stagedNewDefinitions = { [weak self] in
            self?.changes.definitions.filter { $0.isNew && $0.kind != .trigger }.map { ($0.id, $0.kind, $0.name) } ?? []
        }
        sidebar.stagedClones = { [weak self] in self?.changes.clones.map(\.name) ?? [] }
        sidebar.onClone = config.readOnly ? nil : { [weak self] object in self?.clone(object) }
        sidebar.onRefreshMaterializedView = config.readOnly ? nil : { [weak self] object in self?.refresh(object) }
    }

    /// Tabs showing `object`.
    func tabs(showing object: DatabaseObject) -> [TableTabViewController] {
        tableTabs.filter { $0.newTableID == nil && $0.table == object.ref && $0.kind == object.kind }
    }

    /// For actions that run at once (CSV import): when `object` has staged changes, asks to
    /// commit everything staged or discard what's staged for it, then runs `proceed`.
    func resolveEdits(on object: DatabaseObject, before action: String, in sheetWindow: NSWindow? = nil,
                      then proceed: @escaping () -> Void, cancelled: @escaping () -> Void = {}) {
        for tab in tableTabs { tab.endEditing() }
        guard changes.mark(for: object.ref) != nil, let window = sheetWindow ?? window else { return proceed() }
        let alert = NSAlert()
        alert.messageText = "\(object.ref.name) has staged changes"
        alert.informativeText = "\(action) runs at once. Commit everything staged first, or discard what's staged for \(object.ref.name)?"
        alert.addButton(withTitle: "Commit All")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.commitStaged(then: proceed)
            case .alertSecondButtonReturn:
                self.changes.discard(object.ref)
                for tab in self.tabs(showing: object) { tab.reload() }
                proceed()
            default: cancelled()
            }
        }
    }

    /// Names of the schema's tables and views, for checking new names.
    var existingNames: [String] { environment.catalog.objects.map(\.ref.name) }

    /// Asks for a new name, checked against the schema and what's staged. `done` gets it.
    private func askName(title: String, current: String, check: @escaping (String) -> String?,
                         done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "New name:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)).singleLine()
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name != current else { return }
            if let problem = check(name) {
                DispatchQueue.main.async { present(DatabaseError(problem), title: "Can't rename to “\(name)”", in: self.window) }
                return
            }
            done(name)
        }
    }

    /// Stages a rename: a table's goes into its structure changes, a view's is its own action.
    private func rename(_ object: DatabaseObject) {
        guard !config.readOnly else { return NSSound.beep() }
        let current = changes.stagedName(for: object.ref) ?? object.ref.name
        askName(title: "Rename \(current)", current: current, check: { [weak self] name in
            guard let self else { return nil }
            // Back to its own name drops the rename.
            if name == object.ref.name { return nil }
            return self.changes.nameProblem(name, renaming: object.ref, existing: self.existingNames)
        }) { [weak self] name in
            self?.stageRename(object, to: name)
        }
    }

    private func stageRename(_ object: DatabaseObject, to name: String) {
        let place = EditPlace(side: .sidebar, objects: [object])
        let what = object.kind == .table ? "Table" : "View"
        if object.kind != .table {
            do {
                let plan = try ObjectActions.renamePlan(object, to: name, on: connection)
                changes.perform("Rename \(what)", at: place) {
                    if name == object.ref.name {
                        changes.removeRename(of: object.ref)
                    } else {
                        changes.stage(StagedAction(.rename(to: name), object, plan: plan))
                    }
                }
            } catch {
                present(error, title: "Couldn't rename \(object.ref.name)", in: window)
            }
            return
        }
        let connection = connection
        Task {
            do {
                var editor = if let staged = changes.structure(for: object.ref) { staged } else {
                    StructureEditor(try await connection.structure(of: object.ref))
                }
                editor.name = name
                changes.perform("Rename \(what)", at: place) { changes.setStructure(editor) }
            } catch {
                present(error, title: "Couldn't rename \(object.ref.name)", in: window)
            }
        }
    }

    private func renameNewTable(_ id: UUID) {
        guard let editor = changes.newTable(id) else { return }
        askName(title: "Rename \(editor.name)", current: editor.name, check: { [weak self] name in
            guard let self else { return nil }
            return self.changes.nameProblem(name, newTable: id, existing: self.existingNames)
        }) { [weak self] name in
            guard let self, var e = self.changes.newTable(id) else { return }
            e.name = name
            self.changes.perform("Rename New Table", at: EditPlace(newTable: id, side: .sidebar)) { self.changes.setNewTable(id, e) }
        }
    }

    /// ⌫ / ⌘⌫ in the sidebar: a plain DROP for each table, view and routine (no CASCADE,
    /// foreign-key checks kept), and staged new objects and clones removed, as one undo step.
    /// Items already marked are left as they are.
    func markForDeletion(_ deletion: SidebarViewController.Deletion) {
        let objects = deletion.objects.filter { changes.mark(for: $0) != .dropped }
        let (newTables, newDefinitions, clones) = (deletion.newTables, deletion.newDefinitions, deletion.clones)
        let count = objects.count + newTables.count + newDefinitions.count + clones.count
        guard count > 0 else { return }
        let single = objects.first.flatMap { DefinitionKind($0.kind)?.title.capitalized }
            ?? newDefinitions.first.flatMap { changes.definition($0)?.kind.title.capitalized } ?? "Table"
        let name = count > 1 ? "Delete Items" : "Delete \(single)"
        let place = EditPlace(newTable: newTables.first, side: .sidebar, objects: objects)
        let connection = connection
        Task {
            do {
                var plans: [(DatabaseObject, DDLPlan)] = []
                for object in objects {
                    plans.append((object, try await ObjectActions.dropPlan([object], options: DropOptions(), on: connection)))
                }
                changes.perform(name, at: place) {
                    for id in newTables { changes.removeNewTable(id) }
                    for id in newDefinitions { changes.removeDefinition(id) }
                    for clone in clones { changes.removeClone(named: clone) }
                    for (object, plan) in plans { changes.stage(StagedAction(.drop, object, plan: plan)) }
                }
            } catch {
                present(error, title: "Couldn't delete", in: window)
            }
        }
    }

    private func truncate(_ object: DatabaseObject) {
        guard !config.readOnly else { return NSSound.beep() }
        let d = connection.dialect
        let options: [(title: String, set: (inout TruncateOptions) -> Void)] =
            d is PostgresDialect ? [("Restart identity", { $0.restartIdentity = true }), ("Cascade", { $0.cascade = true })]
            : d is MySQLDialect ? [("Ignore foreign key checks", { $0.ignoreForeignKeys = true })]
            : [("Reset the AUTOINCREMENT counter", { $0.restartIdentity = true })]
        let connection = connection
        confirm(
            title: "Delete every row in \(object.ref.name)?", button: "Truncate",
            message: Self.stagedMessage, options: options.map(\.title)
        ) { chosen in
            var o = TruncateOptions()
            for (i, option) in options.enumerated() where chosen.contains(i) { option.set(&o) }
            return try await ObjectActions.truncatePlan([object.ref], options: o, on: connection)
        } then: { [weak self] plan in
            self?.changes.perform("Truncate Table", at: EditPlace(side: .sidebar, objects: [object])) {
                self?.changes.stage(StagedAction(.truncate, object, plan: plan))
            }
        }
    }

    private func delete(_ object: DatabaseObject) {
        guard !config.readOnly else { return NSSound.beep() }
        let d = connection.dialect
        let options: [(title: String, set: (inout DropOptions) -> Void)] = d is PostgresDialect
            ? [("Cascade (also drop what depends on it)", { $0.cascade = true })]
            : object.kind == .table ? [("Ignore foreign key checks", { $0.ignoreForeignKeys = true })] : []
        let connection = connection
        let what = DefinitionKind(object.kind)?.title ?? "table"
        confirm(
            title: "Delete \(what) \(object.displayName)?", button: "Delete",
            message: Self.stagedMessage, options: options.map(\.title)
        ) { chosen in
            var o = DropOptions()
            for (i, option) in options.enumerated() where chosen.contains(i) { option.set(&o) }
            return try await ObjectActions.dropPlan([object], options: o, on: connection)
        } then: { [weak self] plan in
            self?.changes.perform("Delete \(what.capitalized)", at: EditPlace(side: .sidebar, objects: [object])) {
                self?.changes.stage(StagedAction(.drop, object, plan: plan))
            }
        }
    }

    private static let stagedMessage = "It's staged with your other changes: Commit (⌘S) runs it, Discard (⇧⌘⌫) drops it."

    /// Clone…: a copy of the table under a new name, with or without its rows, staged. A table
    /// with staged structure changes or a staged delete can't be cloned until they're settled.
    private func clone(_ object: DatabaseObject) {
        guard !config.readOnly, let window else { return NSSound.beep() }
        if changes.structure(for: object.ref) != nil || changes.mark(for: object.ref) == .dropped {
            return present(DatabaseError("Commit or discard what's staged for \(object.ref.name)'s structure first."),
                           title: "Can't clone \(object.ref.name) yet", in: window)
        }
        let alert = NSAlert()
        alert.messageText = "Clone \(object.ref.name)"
        alert.informativeText = "A new table with the same columns, keys and indexes. " + Self.stagedMessage
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)).singleLine()
        field.stringValue = cloneName(for: object.ref.name)
        field.placeholderString = "Table name"
        let rows = NSButton(checkboxWithTitle: "Copy the rows too", target: nil, action: nil)
        rows.state = .on
        let stack = NSStackView(views: [field, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 54)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let withData = rows.state == .on
            if let problem = self.changes.nameProblem(name, existing: self.existingNames) {
                DispatchQueue.main.async { present(DatabaseError(problem), title: "Can't clone as “\(name)”", in: self.window) }
                return
            }
            self.stageClone(object, as: name, withData: withData)
        }
    }

    func stageClone(_ object: DatabaseObject, as name: String, withData: Bool) {
        let connection = connection
        Task {
            do {
                let plan = try await ObjectActions.clonePlan(object.ref, as: name, withData: withData, on: connection)
                changes.perform("Clone Table", at: EditPlace(side: .sidebar, objects: [object])) {
                    changes.stage(StagedAction(.clone(as: name, withData: withData), object, plan: plan))
                }
            } catch {
                present(error, title: "Couldn't clone \(object.ref.name)", in: window)
            }
        }
    }

    /// `people_copy`, `people_copy_2`, … past the names taken.
    private func cloneName(for name: String) -> String {
        var candidate = name + "_copy"
        var n = 2
        while changes.nameProblem(candidate, existing: existingNames) != nil {
            candidate = "\(name)_copy_\(n)"
            n += 1
        }
        return candidate
    }

    /// Refresh Materialized View: runs at once (it changes rows, not the schema), through safe
    /// mode, then reloads the view's tabs.
    private func refresh(_ object: DatabaseObject) {
        let sql = "REFRESH MATERIALIZED VIEW \(connection.dialect.qualified(object.ref))"
        let connection = connection
        Task {
            guard await safety.approve([sql]) else { return }
            do {
                _ = try await connection.execute(sql)
                for tab in tabs(showing: object) { tab.reload() }
            } catch {
                present(error, title: "Couldn't refresh \(object.ref.name)", in: window)
            }
        }
    }

    private func copyScript(_ object: DatabaseObject, _ script: SidebarViewController.Script) {
        let connection = connection
        let d = connection.dialect
        Task {
            do {
                let text: String = switch script {
                case .create: try await connection.definition(of: object)
                case .drop: try await ObjectActions.dropPlan([object], options: DropOptions(), on: connection).preview
                case .truncate: try await ObjectActions.truncatePlan([object.ref], options: TruncateOptions(), on: connection).preview
                case .select: d.select(BrowseRequest(object.ref, limit: 100), allColumns: []).inlined(for: d) + ";"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                present(error, title: "Couldn't copy the script", in: window)
            }
        }
    }

    // MARK: - Helpers

    /// A tab for the object: routines get a definition tab, tables and views a table tab.
    func makeTab(_ object: DatabaseObject, mode: TableTabViewController.Mode, preview: Bool = false) -> any ObjectTab {
        if object.kind.isRoutine {
            let tab = DefinitionTabViewController(object: object, connection: connection, changes: changes,
                                                  readOnlyConnection: config.readOnly)
            tab.isPreview = preview
            return tab
        }
        let mode = mode == .definition && !(object.kind == .view || object.kind == .materializedView) ? .data : mode
        let tab = configure(TableTabViewController(
            connection: connection, changes: changes, object: object, readOnlyConnection: config.readOnly,
            mode: mode))
        tab.isPreview = preview
        return tab
    }

    func configure(_ tab: TableTabViewController) -> TableTabViewController {
        tab.safety = environment.safety
        tab.columnLayouts = environment.columnLayouts
        tab.existingNames = { [weak self] in self?.existingNames ?? [] }
        tab.knownTables = { [weak self] in
            self?.environment.catalog.objects.filter { $0.kind == .table }.map(\.ref) ?? []
        }
        return tab
    }

    /// A destructive confirmation with checkboxes and the SQL they produce.
    private func confirm(
        title: String, button: String, message: String, options: [String],
        plan: @escaping @MainActor (Set<Int>) async throws -> DDLPlan,
        then proceed: @escaping (DDLPlan) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true

        let sql = NSTextField(wrappingLabelWithString: "")
        sql.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sql.textColor = .secondaryLabelColor
        sql.preferredMaxLayoutWidth = 340
        var current: DDLPlan?
        var chosen = Set<Int>()
        let checkboxes = options.enumerated().map { i, option in
            let box = NSButton(checkboxWithTitle: option, target: nil, action: nil)
            box.tag = i
            return box
        }
        let refresh: () -> Void = {
            Task { @MainActor in
                do {
                    let p = try await plan(chosen)
                    current = p
                    sql.stringValue = (p.setup + p.statements + p.teardown).map { $0 + ";" }.joined(separator: "\n")
                    alert.buttons[0].isEnabled = true
                } catch {
                    current = nil
                    sql.stringValue = "\(error)"
                    alert.buttons[0].isEnabled = false
                }
                alert.layout()
            }
        }
        let handler = CheckboxHandler { box in
            if box.state == .on { chosen.insert(box.tag) } else { chosen.remove(box.tag) }
            refresh()
        }
        for box in checkboxes {
            box.target = handler
            box.action = #selector(CheckboxHandler.toggled(_:))
        }
        let stack = NSStackView(views: checkboxes + [sql])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(checkboxes.count) * 22 + 60)
        alert.accessoryView = stack
        refresh()
        alert.beginSheetModal(for: window) { response in
            _ = handler
            if response == .alertFirstButtonReturn, let current { proceed(current) }
        }
    }
}

/// Target for checkboxes built in a closure.
@MainActor
private final class CheckboxHandler: NSObject {
    let action: (NSButton) -> Void
    init(_ action: @escaping (NSButton) -> Void) { self.action = action }
    @objc func toggled(_ sender: NSButton) { action(sender) }
}
