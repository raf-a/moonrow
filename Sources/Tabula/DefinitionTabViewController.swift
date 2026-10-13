import AppCore
import AppKit
import DBKit

/// A tab that shows a database object: a table or view (`TableTabViewController`) or a routine
/// or new object (`DefinitionTabViewController`). Placement, Back / Forward and commits use it.
@MainActor
protocol ObjectTab: WorkspaceTab {
    /// The object shown; nil for an object that's only staged so far.
    var object: DatabaseObject? { get }
    var isPreview: Bool { get set }
    /// Stages what's being typed.
    func endEditing()
    /// Reads the object again; staged changes stay.
    func reload()
}

extension DefinitionKind {
    /// The sidebar's symbol for the kind.
    var symbol: String {
        switch self {
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .function: "function"
        case .procedure: "curlybraces"
        case .trigger: "bolt"
        }
    }
}

/// A routine's definition, or a new view, materialized view, function or procedure that exists
/// only as staged text until the commit creates it.
@MainActor
final class DefinitionTabViewController: NSViewController, ObjectTab {
    let editor: DefinitionEditorController
    private let databaseObject: DatabaseObject?
    /// Set while the tab shows a staged new object.
    let newDefinitionID: UUID?
    private let changes: StagedChanges
    let tabID = UUID()
    var onTabItemChange: (() -> Void)?
    var isPreview = false {
        didSet { if isPreview != oldValue { onTabItemChange?() } }
    }
    /// Committed: the tab waits for the object list to show what was created.
    var isAwaitingCommit = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    /// An existing routine.
    init(object: DatabaseObject, connection: any DatabaseConnection, changes: StagedChanges, readOnlyConnection: Bool) {
        let defined = DefinedObject(object)!
        databaseObject = object
        newDefinitionID = nil
        self.changes = changes
        editor = DefinitionEditorController(
            target: .existing(defined), kind: defined.kind, connection: connection, changes: changes,
            readOnlyReason: readOnlyConnection ? "The connection is read-only." : nil,
            place: EditPlace(side: .definition, objects: [object]))
        super.init(nibName: nil, bundle: nil)
        wire()
    }

    /// A new object, staged.
    init(newDefinition id: UUID, kind: DefinitionKind, connection: any DatabaseConnection, changes: StagedChanges) {
        databaseObject = nil
        newDefinitionID = id
        self.changes = changes
        editor = DefinitionEditorController(
            target: .new(id), kind: kind, connection: connection, changes: changes, readOnlyReason: nil,
            place: EditPlace(newDefinition: id, side: .definition))
        super.init(nibName: nil, bundle: nil)
        wire()
    }

    private func wire() {
        editor.onStage = { [weak self] in
            self?.updateTitle()
            self?.onTabItemChange?()
        }
        editor.onUse = { [weak self] in self?.isPreview = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var object: DatabaseObject? { databaseObject }
    var kind: DefinitionKind { editor.kind }

    override func loadView() {
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        icon.contentTintColor = newDefinitionID == nil ? .systemOrange : .systemGreen
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, titleLabel])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let line = NSBox()
        line.boxType = .separator
        addChild(editor)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for v in [header, line, editor.view] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            editor.view.topAnchor.constraint(equalTo: line.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editor.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateTitle()
    }

    /// The name the staged text gives, else the object's.
    var name: String {
        editor.staged?.name ?? databaseObject?.ref.name ?? kind.title
    }

    private func updateTitle() {
        guard isViewLoaded else { return }
        var text = (newDefinitionID == nil ? "" : "New ") + kind.title.capitalized + "  "
        if let o = databaseObject {
            text += (o.ref.schema.map { $0 + "." } ?? "") + o.displayName
            if name != o.ref.name { text += "  →  \(name)" }
        } else {
            text += name
        }
        titleLabel.stringValue = text
    }

    // MARK: - ObjectTab

    var tabItem: TabStrip.Item {
        let symbol = newDefinitionID == nil ? kind.symbol : "plus.rectangle"
        let tip = isPreview ? "\(name) — preview tab; double-click to keep it" : databaseObject.map {
            ($0.ref.schema.map { $0 + "." } ?? "") + $0.displayName
        } ?? "New \(kind.title), created on Commit"
        return TabStrip.Item(title: name, symbol: symbol, toolTip: tip, italic: isPreview)
    }

    var preferredResponder: NSView { editor.editor }

    func prepareToClose(then proceed: @escaping () -> Void) {
        endEditing()
        proceed()
    }

    func tabDidClose() {
        editor.stop()
    }

    func endEditing() { editor.stageNow() }

    func reload() { editor.reload() }
}
