import DBKit
import Foundation
import Testing
@testable import AppCore

private let people = TableRef("people")
private let columns = [
    ColumnInfo(name: "id", typeName: "INTEGER", primaryKeyPosition: 1),
    ColumnInfo(name: "name", typeName: "TEXT"),
    ColumnInfo(name: "photo", typeName: "BLOB"),
    ColumnInfo(name: "upper_name", typeName: "TEXT", generated: "GENERATED ALWAYS AS (upper(name)) STORED"),
]

@Suite struct InspectorFieldTests {
    @Test func mergeKeepsOnlyASharedValue() {
        #expect(InspectorForm.merge([1, 1, 1]) == 1)
        #expect(InspectorForm.merge([1, 2]) == nil)
        #expect(InspectorForm.merge([Int]()) == nil)
    }

    @Test func rowFieldsMergeAcrossRows() {
        let shown: [[CellContent]] = [
            [.value(.integer(1)), .value(.text("Ann")), .value(.blob(Data([1, 2]))), .value(.text("ANN"))],
            [.value(.integer(2)), .value(.text("Ann")), .value(.null), .value(.text("ANN"))],
        ]
        let fields = InspectorForm.rows(columns: columns, shown: shown, staged: [[1], []], editable: true)
        #expect(fields.map(\.label) == ["id", "name", "photo", "upper_name"])
        #expect(fields[0].value == nil)  // Multiple values
        #expect(fields[1].value == .value(.text("Ann")))
        #expect(fields[1].isStaged && !fields[0].isStaged)
        #expect(fields[1].detail == "TEXT")
        // Blobs are read-only; so are ALWAYS-generated columns.
        #expect(fields[2].kind == .blob && !fields[2].isEditable)
        #expect(!fields[3].isEditable)
        #expect(fields[0].isEditable && fields[1].isEditable)
        // Nothing selected, no fields; a read-only grid, nothing editable.
        #expect(InspectorForm.rows(columns: columns, shown: [], staged: [], editable: true).isEmpty)
        #expect(!InspectorForm.rows(columns: columns, shown: shown, staged: [[], []], editable: false).contains { $0.isEditable })
    }

    @Test func oneEditStagesEverySelectedRow() {
        var e = TableEdits(table: people, columns: columns)
        let ann: [DBValue] = [.integer(1), .text("Ann"), .null, .text("ANN")]
        let bo: [DBValue] = [.integer(2), .text("Bo"), .null, .text("BO")]
        let cy: [DBValue] = [.integer(3), .text("Cy"), .null, .text("CY")]
        e.delete(cy)
        e.addRow()
        e.set(.value(.text("Same")), column: 1, loaded: [ann, bo, cy], inserted: [0])
        #expect(e.change(in: ann, column: 1) == .value(.text("Same")))
        #expect(e.change(in: bo, column: 1) == .value(.text("Same")))
        #expect(e.inserts[0][1] == .value(.text("Same")))
        // A row marked for deletion is left alone.
        #expect(e.change(in: cy, column: 1) == nil)
        #expect(e.updatedRowCount == 2)
    }

    @Test func structureFieldsMergeAcrossColumns() {
        var s = StructureEditor(TableStructure(table: people, columns: [
            ColumnInfo(name: "id", typeName: "integer", isNullable: false, primaryKeyPosition: 1),
            ColumnInfo(name: "a", typeName: "text"),
            ColumnInfo(name: "b", typeName: "text", defaultExpression: "'x'"),
        ]))
        var fields = InspectorForm.columns(s, rows: [1, 2], editable: true)
        #expect(fields.map(\.label) == ["Name", "Type", "Nullable", "Default", "Comment"])
        #expect(!fields[0].isEditable)  // one name can't go to two columns
        #expect(fields[1].value == .value(.text("text")))
        #expect(fields[2].value == .value(.bool(true)) && fields[2].kind == .flag)
        #expect(fields[3].value == nil)

        s.set(.type, to: "varchar(20)", columns: [1, 2], dialect: PostgresDialect())
        s.set(.nullable, to: "no", columns: [1, 2], dialect: PostgresDialect())
        fields = InspectorForm.columns(s, rows: [1, 2], editable: true)
        #expect(fields[1].value == .value(.text("varchar(20)")) && fields[1].isStaged)
        #expect(fields[2].value == .value(.bool(false)))
        #expect(s.change.alteredColumns.count == 2)

        // A key column stays NOT NULL, and its nullability is read-only.
        s.set(.nullable, to: "yes", columns: [0], dialect: PostgresDialect())
        #expect(!s.columns[0].value.isNullable)
        #expect(!InspectorForm.columns(s, rows: [0], editable: true)[2].isEditable)
        // Empty text means no default and no comment; an empty name is ignored.
        s.set(.defaultValue, to: "", columns: [2], dialect: PostgresDialect())
        s.set(.name, to: " ", columns: [2], dialect: PostgresDialect())
        #expect(s.columns[2].value.defaultExpression == nil && s.columns[2].value.name == "b")
    }

    @Test func indexFields() {
        var s = StructureEditor(TableStructure(table: people, columns: columns, indexes: [
            IndexInfo(name: "people_name_idx", columns: ["name"]),
            IndexInfo(name: "people_name_key", columns: ["name"], isUnique: true, isConstraint: true),
        ]))
        var fields = InspectorForm.indexes(s, rows: [0], editable: true)
        #expect(fields.map(\.label) == ["Name", "Columns", "Unique", "Method", "Condition"])
        #expect(fields.allSatisfy { $0.isEditable })
        s.set(.unique, to: "yes", indexes: [0])
        s.set(.columns, to: "name, id", indexes: [0])
        fields = InspectorForm.indexes(s, rows: [0], editable: true)
        #expect(fields[1].value == .value(.text("name, id")) && fields[1].isStaged)
        #expect(fields[2].value == .value(.bool(true)))
        // A constraint's index can only be deleted.
        #expect(!InspectorForm.indexes(s, rows: [0, 1], editable: true).contains { $0.isEditable })
    }
}
