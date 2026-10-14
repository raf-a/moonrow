import AppCore
import AppKit
import DBKit

// Restore on relaunch: what a workspace shows is written to `session.json` as it changes, and
// the workspaces open at quit come back at the next launch with their schema, panes and tabs
// (unsaved query text included). Staged changes and new tables aren't kept.

extension WorkspaceWindowController {
    /// What the window shows now.
    func sessionSnapshot() -> WorkspaceSession {
        let saved = panes.panes.map { pane -> WorkspaceSession.Pane in
            var tabs: [WorkspaceSession.Tab] = []
            var selected: Int?
            for (i, tab) in pane.tabs.enumerated() {
                guard let kept = sessionTab(tab) else { continue }
                if i == pane.selectedIndex { selected = tabs.count }
                tabs.append(kept)
            }
            return WorkspaceSession.Pane(tabs: tabs, selected: selected ?? (tabs.isEmpty ? nil : 0))
        }
        return WorkspaceSession(connectionID: config.id, schema: sidebar.schema, panes: saved, activePane: panes.activeIndex)
    }

    private func sessionTab(_ tab: any WorkspaceTab) -> WorkspaceSession.Tab? {
        if let table = tab as? TableTabViewController {
            guard let object = table.object else { return nil }  // a staged new table
            return .table(object, structure: table.mode == .structure, definition: table.mode == .definition,
                          isPreview: table.isPreview)
        }
        if let routine = tab as? DefinitionTabViewController {
            guard let object = routine.object else { return nil }  // a staged new object
            return .table(object, isPreview: routine.isPreview)
        }
        if let query = tab as? QueryEditorViewController {
            return .query(text: query.editor.string, savedQuery: query.savedQuery?.path, file: query.fileURL?.path)
        }
        return nil
    }

    /// Opens the panes and tabs of a saved session in this (new) window. The schema is picked
    /// once the sidebar has listed the schemas.
    func restore(_ session: WorkspaceSession) {
        if let schema = session.schema { sidebar.schemaToRestore = schema }
        for (n, saved) in session.panes.enumerated() {
            let pane = n == 0 ? panes.panes[0] : panes.addPane()
            for tab in saved.tabs {
                switch tab.kind {
                case .table:
                    guard let object = tab.object else { continue }
                    let mode: TableTabViewController.Mode = tab.definition ? .definition : tab.structure ? .structure : .data
                    pane.add(makeTab(object, mode: mode, preview: tab.isPreview), focus: false)
                case .query:
                    if let name = tab.savedQuery, let query = environment.savedQueries.query(path: name),
                       let text = try? environment.savedQueries.text(of: query) {
                        newQuery(text: text, saved: query)
                    } else {
                        // A file's tab comes back with its text as it was, edits included.
                        newQuery(text: tab.text ?? "", file: tab.file.map { URL(filePath: $0) })
                    }
                }
            }
            if let selected = saved.selected, pane.tabs.indices.contains(selected) { pane.select(selected, focus: false) }
        }
        panes.activate(min(session.activePane, panes.panes.count - 1), focus: true)
        tabChanged()
    }
}
