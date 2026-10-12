import DBKit

/// What a grid cell shows.
public enum CellContent: Sendable, Hashable {
    case value(DBValue)
    /// An inserted row's cell that will take the column default.
    case defaultValue
    /// The row hasn't loaded yet.
    case pending

    /// The value, when there is one.
    public var value: DBValue? {
        if case .value(let v) = self { return v }
        return nil
    }
}

/// One field of the right sidebar's form: a data column of the selected rows, or an attribute of
/// the selected structure columns or indexes.
public struct InspectorField: Sendable, Hashable {
    public enum Key: Sendable, Hashable {
        /// A data column, by its index in the table's columns.
        case cell(Int)
        case column(StructureEditor.ColumnAttribute)
        case index(StructureEditor.IndexAttribute)
    }

    public enum Kind: Sendable, Hashable {
        /// Free text; the field grows for long or multi-line values.
        case text
        /// A yes/no pop-up.
        case flag
        /// Binary data: read-only, shown as its size.
        case blob
    }

    public var key: Key
    public var label: String
    /// The column's type, under the label.
    public var detail: String
    public var kind: Kind
    /// The value every selected item shares; nil when they differ ("Multiple values").
    public var value: CellContent?
    /// Some selected item has a staged change here.
    public var isStaged: Bool
    public var isEditable: Bool
}

/// Builds the right sidebar's fields from the selection.
public enum InspectorForm {
    /// The shared value, or nil when the values differ (or there are none).
    public static func merge<V: Equatable>(_ values: some Sequence<V>) -> V? {
        var it = values.makeIterator()
        guard let first = it.next() else { return nil }
        while let next = it.next() { if next != first { return nil } }
        return first
    }

    /// One field per column for the selected rows. `shown[i][c]` is what row `i` shows in column
    /// `c` (staged changes included); `staged[i]` holds the columns with a staged change.
    public static func rows(
        columns: [ColumnInfo], shown: [[CellContent]], staged: [Set<Int>], editable: Bool
    ) -> [InspectorField] {
        guard !shown.isEmpty else { return [] }
        return columns.indices.map { c in
            let values = shown.map { c < $0.count ? $0[c] : .pending }
            let isBlob = values.contains { if case .value(.blob) = $0 { true } else { false } }
            let generated = columns[c].generated?.hasPrefix("GENERATED ALWAYS") == true
            return InspectorField(
                key: .cell(c), label: columns[c].name, detail: columns[c].typeName, kind: isBlob ? .blob : .text,
                value: merge(values), isStaged: staged.contains { $0.contains(c) },
                isEditable: editable && !isBlob && !generated && !values.contains(.pending))
        }
    }

    /// The selected structure columns' attributes. Names must stay unique, so the name is only
    /// editable for a single column.
    public static func columns(_ editor: StructureEditor, rows: [Int], editable: Bool) -> [InspectorField] {
        let rows = rows.filter { editor.columns.indices.contains($0) && !editor.columns[$0].isDeleted }
        guard !rows.isEmpty else { return [] }
        let values = rows.map { editor.columns[$0].value }
        let changed = rows.map { editor.changedFields(ofColumn: $0) }
        func field(_ a: StructureEditor.ColumnAttribute, _ label: String, kind: InspectorField.Kind = .text,
                   _ value: (ColumnInfo) -> CellContent, changedAs: StructureEditor.ColumnField, editable more: Bool = true) -> InspectorField {
            InspectorField(key: .column(a), label: label, detail: "", kind: kind, value: merge(values.map(value)),
                           isStaged: changed.contains { $0.contains(changedAs) }, isEditable: editable && more)
        }
        let inKey = values.contains { editor.primaryKey.contains($0.name) }
        return [
            field(.name, "Name", { .value(.text($0.name)) }, changedAs: .name, editable: rows.count == 1),
            field(.type, "Type", { .value(.text($0.typeName)) }, changedAs: .type),
            field(.nullable, "Nullable", kind: .flag, { .value(.bool($0.isNullable)) }, changedAs: .nullable, editable: !inKey),
            field(.defaultValue, "Default", { .value(.text($0.defaultExpression ?? "")) }, changedAs: .defaultValue,
                  editable: !values.contains { $0.generated != nil && !$0.isAutoIncrement }),
            field(.comment, "Comment", { .value(.text($0.comment ?? "")) }, changedAs: .comment),
        ]
    }

    /// The selected indexes' attributes. Constraint indexes can only be deleted, so their fields
    /// are read-only.
    public static func indexes(_ editor: StructureEditor, rows: [Int], editable: Bool) -> [InspectorField] {
        let rows = rows.filter { editor.indexes.indices.contains($0) && !editor.indexes[$0].isDeleted }
        guard !rows.isEmpty else { return [] }
        let values = rows.map { editor.indexes[$0].value }
        let changed = rows.map { editor.changedFields(ofIndex: $0) }
        let fixed = rows.contains { editor.indexes[$0].value.isConstraint && !editor.indexes[$0].isNew }
        func field(_ a: StructureEditor.IndexAttribute, _ label: String, kind: InspectorField.Kind = .text,
                   _ value: (IndexInfo) -> CellContent, changedAs: StructureEditor.IndexField, single: Bool = false) -> InspectorField {
            InspectorField(key: .index(a), label: label, detail: "", kind: kind, value: merge(values.map(value)),
                           isStaged: changed.contains { $0.contains(changedAs) },
                           isEditable: editable && !fixed && (!single || rows.count == 1))
        }
        return [
            field(.name, "Name", { .value(.text($0.name)) }, changedAs: .name, single: true),
            field(.columns, "Columns", { .value(.text($0.columns.joined(separator: ", "))) }, changedAs: .columns),
            field(.unique, "Unique", kind: .flag, { .value(.bool($0.isUnique)) }, changedAs: .unique),
            field(.method, "Method", { .value(.text($0.method ?? "")) }, changedAs: .method),
            field(.condition, "Condition", { .value(.text($0.predicate ?? "")) }, changedAs: .predicate),
        ]
    }
}

// MARK: - Editing several at once

extension TableEdits {
    /// Stages one value for a column in several rows at once: loaded rows by their values, new
    /// rows by their index in `inserts`. Rows marked for deletion are left alone.
    public mutating func set(_ change: CellChange, column: Int, loaded rows: [[DBValue]], inserted: [Int]) {
        for row in rows where state(of: row) != .deleted { set(change, column: column, in: row) }
        for row in inserted { setInserted(change, row: row, column: column) }
    }
}

extension StructureEditor {
    /// What the structure grid and the inspector edit on a column.
    public enum ColumnAttribute: String, Sendable, Hashable, CaseIterable {
        case name, type, nullable, defaultValue, comment
    }

    public enum IndexAttribute: String, Sendable, Hashable, CaseIterable {
        case name, columns, unique, method, condition
    }

    /// Sets an attribute from text (yes/no for `nullable`) on several columns. Text that changes
    /// nothing, an empty name, or an empty type outside SQLite is ignored. A primary-key column
    /// stays NOT NULL.
    public mutating func set(_ attribute: ColumnAttribute, to text: String, columns rows: [Int], dialect: any Dialect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for r in rows where columns.indices.contains(r) && !columns[r].isDeleted {
            let current = columns[r].value
            switch attribute {
            case .name:
                guard !trimmed.isEmpty, trimmed != current.name else { continue }
                setColumn(r) { $0.name = trimmed }
            case .type:
                guard !trimmed.isEmpty || dialect is SQLiteDialect, trimmed != current.typeName else { continue }
                setColumn(r) { $0.typeName = trimmed }
            case .nullable:
                let wanted = Self.flag(trimmed)
                guard let wanted, wanted != current.isNullable, !(wanted && primaryKey.contains(current.name)) else { continue }
                setColumn(r) { $0.isNullable = wanted }
            case .defaultValue:
                let sql = DefaultInput.sql(from: text, dialect: dialect)
                guard sql != current.defaultExpression else { continue }
                setColumn(r) { $0.defaultExpression = sql }
            case .comment:
                let comment = trimmed.isEmpty ? nil : trimmed
                guard comment != current.comment else { continue }
                setColumn(r) { $0.comment = comment }
            }
        }
    }

    /// Sets an attribute from text (yes/no for `unique`) on several indexes.
    public mutating func set(_ attribute: IndexAttribute, to text: String, indexes rows: [Int]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for r in rows where indexes.indices.contains(r) && !indexes[r].isDeleted {
            let current = indexes[r].value
            switch attribute {
            case .name:
                guard trimmed != current.name else { continue }
                setIndex(r) { $0.name = trimmed }
            case .columns:
                let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard names != current.columns else { continue }
                setIndex(r) { $0.columns = names }
            case .unique:
                guard let wanted = Self.flag(trimmed), wanted != current.isUnique else { continue }
                setIndex(r) { $0.isUnique = wanted }
            case .method:
                guard trimmed != (current.method ?? "") else { continue }
                setIndex(r) { $0.method = trimmed.isEmpty ? nil : trimmed }
            case .condition:
                guard trimmed != (current.predicate ?? "") else { continue }
                setIndex(r) { $0.predicate = trimmed.isEmpty ? nil : trimmed }
            }
        }
    }

    private static func flag(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }
}
