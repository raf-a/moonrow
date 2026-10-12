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
    /// ⌘S works from every view; with nothing staged it does nothing.
    func commitStaged(then proceed: (() -> Void)?) {
        endAllEditing()
        guard !changes.isEmpty, !isCommitting else { return }
        let plan: CommitPlan
        do {
            plan = try changes.plan(dialect: connection.dialect)
        } catch {
            return showCommitError(error, title: "Can't apply these changes", staged: true)
        }
        previewSheet?.close()
        isCommitting = true
        updateChangesItem()
        let connection = connection
        Task {
            defer {
                isCommitting = false
                updateChangesItem()
            }
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

    /// Ends every edit in progress, so what's typed is staged: grid cells, and fields such as a
    /// table's Name or the right sidebar's.
    func endAllEditing() {
        for tab in tableTabs { tab.endEditing() }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
            window?.makeFirstResponder(nil)
        }
    }

    /// After a commit: tabs follow tables that were created, renamed or dropped; the rest reload.
    /// Undo starts over.
    private func committed() {
        var renamed: [TableRef: TableRef] = [:]
        for (table, editor) in changes.structures where editor.name != table.name {
            renamed[table] = TableRef(schema: table.schema, editor.name)
        }
        for a in changes.actions {
            if case .rename(let name) = a.kind { renamed[a.object.ref] = TableRef(schema: a.object.ref.schema, name) }
        }
        let created = Dictionary(uniqueKeysWithValues: changes.newTables.map { ($0.id, $0.editor.name) })
        let dropped = Set(changes.actions.filter { $0.kind == .drop }.map(\.object.ref))
        // Tabs of created tables become regular tabs before the new-table tabs would close.
        for tab in tableTabs {
            if let id = tab.newTableID, let name = created[id] { tab.becomeTable(TableRef(schema: tab.table.schema, name)) }
        }
        changes.clearAfterCommit()
        forgetHistory(of: dropped.union(renamed.keys))
        sidebar.reload()
        for tab in tableTabs {
            if dropped.contains(tab.table) {
                closeWithoutAsking(tab)
            } else if let new = renamed[tab.table] {
                tab.becomeTable(new)
            } else {
                tab.reload()
            }
        }
        tabChanged()
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

    /// ⇧⌘⌫: drops everything staged, as one undo step. Staged new tables close.
    @objc func discardChanges(_ sender: Any?) {
        endAllEditing()
        guard !changes.isEmpty else { return NSSound.beep() }
        previewSheet?.close()
        changes.perform("Discard All", at: .sidebar) { changes.discardAll() }
        for tab in tableTabs { tab.reload() }
    }

    /// ⇧⌘P: every staged statement, in the order a commit runs them.
    @objc func previewChanges(_ sender: Any?) {
        endAllEditing()
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
            return !isCommitting
        case #selector(discardChanges(_:)), #selector(previewChanges(_:)):
            return !changes.isEmpty && !isCommitting
        case #selector(toggleRightSidebar(_:)):
            item.state = isInspectorVisible ? .on : .off
            // Space is the shortcut only while a grid has the focus; anywhere else it's typing.
            if NSApp.currentEvent?.type == .keyDown { return window?.firstResponder is DataGrid }
            return true
        default:
            return true
        }
    }
}
