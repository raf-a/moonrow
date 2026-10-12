import AppCore
import AppKit
import DBKit

// One commit, preview and discard for everything staged in the workspace: row edits on any
// table, structure edits, new tables, truncates and drops.

extension WorkspaceWindowController: NSMenuItemValidation {
    @objc func commitChanges(_ sender: Any?) {
        commitStaged(then: nil)
    }

    /// Commits everything staged, then runs `proceed`. A failure leaves everything staged (or,
    /// when MySQL had already applied part of it, reloads what's open) and doesn't proceed.
    func commitStaged(then proceed: (() -> Void)?) {
        for tab in tableTabs { tab.endEditing() }
        guard !changes.isEmpty else { return NSSound.beep() }
        guard !isCommitting else { return }
        let plan: CommitPlan
        do {
            plan = try changes.plan(dialect: connection.dialect)
        } catch {
            return showCommitError(error, title: "Can't apply these changes", staged: true)
        }
        previewSheet?.close()
        isCommitting = true
        let connection = connection
        Task {
            defer { isCommitting = false }
            guard await safety.approve(plan.statements) else { return }
            do {
                try await connection.run(plan)
                committed()
                proceed?()
            } catch let partial as PartialCommitError {
                committed()
                showCommitError(partial, title: "Couldn't apply every change", staged: false)
            } catch {
                showCommitError(error, title: "Couldn't commit changes", staged: true)
            }
        }
    }

    /// After a commit: tabs follow tables that were created, renamed or dropped; the rest reload.
    private func committed() {
        var renamed: [TableRef: TableRef] = [:]
        for (table, editor) in changes.structures where editor.name != table.name {
            renamed[table] = TableRef(schema: table.schema, editor.name)
        }
        let created = Dictionary(uniqueKeysWithValues: changes.newTables.map { ($0.id, $0.editor.name) })
        let dropped = Set(changes.actions.filter { $0.kind == .drop }.map(\.object.ref))
        changes.discardAll()
        sidebar.reload()
        for tab in tableTabs {
            if let id = tab.newTableID {
                if let name = created[id] { tab.becomeTable(TableRef(schema: tab.table.schema, name)) }
            } else if dropped.contains(tab.table) {
                closeWithoutAsking(tab)
            } else if let new = renamed[tab.table] {
                tab.becomeTable(new)
            } else {
                tab.reload()
            }
        }
        tabChanged()
    }

    private func closeWithoutAsking(_ tab: TableTabViewController) {
        if let i = content.tabs.firstIndex(where: { $0 === tab }) { content.close(i) }
    }

    private func showCommitError(_ error: any Error, title: String, staged: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var info = "\(error)"
        let underlying = (error as? PartialCommitError)?.error ?? error
        if let sql = (underlying as? DatabaseError)?.sql { info += "\n\n\(sql)" }
        info += staged ? "\n\nNothing was changed. Your changes are still staged."
            : "\n\nWhat was applied is kept; the rest was dropped. Open tables have been reloaded."
        alert.informativeText = info
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// ⇧⌘⌫: drops everything staged. Staged new tables close.
    @objc func discardChanges(_ sender: Any?) {
        for tab in tableTabs { tab.endEditing() }
        guard !changes.isEmpty else { return NSSound.beep() }
        previewSheet?.close()
        changes.discardAll()
        for tab in tableTabs where tab.newTableID != nil { closeWithoutAsking(tab) }
        for tab in tableTabs { tab.reload() }
    }

    /// ⇧⌘P: every staged statement, in the order a commit runs them.
    @objc func previewChanges(_ sender: Any?) {
        for tab in tableTabs { tab.endEditing() }
        guard !changes.isEmpty, let window else { return NSSound.beep() }
        let plan: CommitPlan
        do {
            plan = try changes.plan(dialect: connection.dialect)
        } catch {
            return showCommitError(error, title: "Can't apply these changes", staged: true)
        }
        let controller = ChangesPreviewController(statements: [plan.preview], note: nil, summary: plan.summary)
        let sheet = NSWindow(contentViewController: controller)
        sheet.setContentSize(NSSize(width: 680, height: 380))
        let holder = NSWindowController(window: sheet)
        controller.onCommit = { [weak self] in
            self?.closePreview()
            self?.commitStaged(then: nil)
        }
        controller.onDiscard = { [weak self] in
            self?.closePreview()
            self?.discardChanges(nil)
        }
        controller.onCancel = { [weak self] in self?.closePreview() }
        previewSheet = holder
        window.beginSheet(sheet)
    }

    private func closePreview() {
        guard let sheet = previewSheet?.window else { return }
        window?.endSheet(sheet)
        previewSheet = nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(commitChanges(_:)):
            item.title = "Commit Changes"
            return !changes.isEmpty && !isCommitting
        case #selector(discardChanges(_:)), #selector(previewChanges(_:)):
            return !changes.isEmpty && !isCommitting
        default:
            return true
        }
    }
}
