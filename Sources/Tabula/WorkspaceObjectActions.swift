import AppCore
import AppKit
import DBKit

// The sidebar's Rename, Truncate, Delete and Copy Script As. Each confirmation shows the SQL it
// will run, updated as its options change. Truncate and Delete are staged with the workspace's
// other changes; Rename runs at once.

extension WorkspaceWindowController {
    func connectSidebarActions() {
        sidebar.onOpenStructure = { [weak self] object in self?.open(object, newTab: false, mode: .structure) }
        sidebar.onNewTable = config.readOnly ? nil : { [weak self] in self?.newTable(nil) }
        sidebar.onRename = { [weak self] object in self?.rename(object) }
        sidebar.onTruncate = { [weak self] object in self?.truncate(object) }
        sidebar.onDelete = { [weak self] object in self?.delete(object) }
        sidebar.onCopyScript = { [weak self] object, script in self?.copyScript(object, script) }
    }

    /// Tabs showing `object`.
    func tabs(showing object: DatabaseObject) -> [TableTabViewController] {
        tableTabs.filter { $0.newTableID == nil && $0.table == object.ref }
    }

    /// For actions that run at once (rename, import): when `object` has staged changes, asks to
    /// commit everything staged or discard what's staged for it, then runs `proceed`.
    func resolveEdits(on object: DatabaseObject, before action: String, then proceed: @escaping () -> Void) {
        for tab in tableTabs { tab.endEditing() }
        guard changes.mark(for: object.ref) != nil, let window else { return proceed() }
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
            default: break
            }
        }
    }

    private func rename(_ object: DatabaseObject) {
        guard !config.readOnly else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Rename \(object.ref.name)"
        alert.informativeText = "New name:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = object.ref.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name != object.ref.name else { return }
            self.resolveEdits(on: object, before: "Renaming") {
                self.run({ try ObjectActions.renamePlan(object, to: name, on: self.connection) }, failure: "Couldn't rename \(object.ref.name)") {
                    let renamed = DatabaseObject(TableRef(schema: object.ref.schema, name), kind: object.kind)
                    for tab in self.tabs(showing: object) {
                        if let i = self.content.tabs.firstIndex(where: { $0 === tab }) {
                            self.content.replace(at: i, with: self.makeTab(renamed, mode: tab.mode))
                        }
                    }
                }
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
            self?.changes.stage(StagedAction(.truncate, object, plan: plan))
        }
    }

    private func delete(_ object: DatabaseObject) {
        guard !config.readOnly else { return NSSound.beep() }
        let d = connection.dialect
        let options: [(title: String, set: (inout DropOptions) -> Void)] = d is PostgresDialect
            ? [("Cascade (also drop what depends on it)", { $0.cascade = true })]
            : [("Ignore foreign key checks", { $0.ignoreForeignKeys = true })]
        let connection = connection
        let what = object.kind == .table ? "table" : "view"
        confirm(
            title: "Delete \(what) \(object.ref.name)?", button: "Delete",
            message: Self.stagedMessage, options: options.map(\.title)
        ) { chosen in
            var o = DropOptions()
            for (i, option) in options.enumerated() where chosen.contains(i) { option.set(&o) }
            return try await ObjectActions.dropPlan([object], options: o, on: connection)
        } then: { [weak self] plan in
            self?.changes.stage(StagedAction(.drop, object, plan: plan))
        }
    }

    private static let stagedMessage = "It's staged with your other changes: Commit (⌘S) runs it, Discard (⇧⌘⌫) drops it."

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

    func makeTab(_ object: DatabaseObject, mode: TableTabViewController.Mode) -> TableTabViewController {
        configure(TableTabViewController(
            connection: connection, changes: changes, object: object, readOnlyConnection: config.readOnly,
            pageSize: config.pageSize, mode: mode))
    }

    func configure(_ tab: TableTabViewController) -> TableTabViewController {
        tab.safety = environment.safety
        tab.knownTables = { [weak self] in
            self?.environment.catalog.objects.filter { $0.kind == .table }.map(\.ref) ?? []
        }
        return tab
    }

    /// Applies a plan, reloads the sidebar and runs `done`; shows the error otherwise.
    private func run(_ plan: @escaping () throws -> DDLPlan, failure: String, done: @escaping () -> Void) {
        let connection = connection
        let safety = environment.safety
        Task {
            do {
                let plan = try plan()
                guard await safety.approve(plan.setup + plan.statements + plan.teardown) else { return }
                try await connection.apply(plan)
                sidebar.reload()
                done()
            } catch {
                var e = error
                if var d = error as? DatabaseError, let sql = d.sql {
                    d.message += "\n\n\(sql)"
                    e = d
                }
                present(e, title: failure, in: window)
            }
        }
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
