import DBKit
import Foundation
import Testing
@testable import AppCore

/// A database of a few tables that answers each table's search from canned rows and records
/// what it was sent. `slow` tables wait until the search is stopped.
private final class SearchConnection: DatabaseConnection, @unchecked Sendable {
    let dialect: any Dialect
    let tables: [String: (columns: [ColumnInfo], rows: [[DBValue]])]
    let slow: Set<String>
    private let lock = NSLock()
    private var log: [String] = []
    private var stopped: [String] = []

    init(_ dialect: any Dialect = PostgresDialect(), tables: [String: (columns: [ColumnInfo], rows: [[DBValue]])],
         slow: Set<String> = []) {
        self.dialect = dialect
        self.tables = tables
        self.slow = slow
    }

    var sent: [String] { lock.withLock { log } }
    var stoppedTables: [String] { lock.withLock { stopped } }

    func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        lock.withLock { log.append(statement.sql) }
        let name = tables.keys.first { statement.sql.contains(dialect.quoteIdentifier($0)) }
        let isSlow = name.map(slow.contains) ?? false
        let rows = name.flatMap { tables[$0]?.rows } ?? []
        return AsyncThrowingStream { continuation in
            let task = Task {
                if isSlow {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    self.lock.withLock { self.stopped.append(name!) }
                    return continuation.finish()
                }
                continuation.yield(ResultBatch(columns: [], rows: rows))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func transaction(_ statements: [SQLStatement], verify: @Sendable (Int, Int) throws -> Void) async throws -> [Int] { [] }
    func schemas() async throws -> [String] { [] }
    func currentSchema() async throws -> String? { nil }
    func objects(schema: String?) async throws -> [DatabaseObject] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        guard let t = tables[table.name] else { throw DatabaseError("no such table: \(table.name)") }
        return t.columns
    }
    func indexes(of table: TableRef) async throws -> [IndexInfo] { [] }
    func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] { [] }
    func triggers(of table: TableRef) async throws -> [TriggerInfo] { [] }
    func close() async {}
}

@Suite struct SearchInDatabaseTests {
    private let people: [ColumnInfo] = [
        ColumnInfo(name: "id", typeName: "integer", isNullable: false, primaryKeyPosition: 1),
        ColumnInfo(name: "name", typeName: "text"),
    ]

    @Test func countsWithTheFilterBarsAnyColumnCondition() throws {
        let pg = PostgresDialect()
        let request = DatabaseSearch.Request(term: "ann", tables: [])
        #expect(request.condition == FilterCondition(.anyColumn, .contains, "ann"))
        let sql = try #require(DatabaseSearch.statement(request, table: TableRef(schema: "s", "people"), columns: ["id", "name"], dialect: pg))
        #expect(sql.inlined(for: pg) == #"SELECT COUNT(*) FROM "s"."people" WHERE ("id"::text ILIKE '%ann%' OR "name"::text ILIKE '%ann%')"#)
        // The tab a result opens filters with the same predicate, so it shows the rows counted.
        let filter = try #require(pg.predicate(for: Filter([request.condition]), columns: ["id", "name"]))
        #expect(sql.inlined(for: pg) == #"SELECT COUNT(*) FROM "s"."people" WHERE "# + filter.inlined(for: pg))
        // Wildcards in the term are matched literally.
        let my = MySQLDialect()
        let percent = DatabaseSearch.Request(term: "5%_", op: .hasPrefix, tables: [])
        #expect(DatabaseSearch.statement(percent, table: TableRef("t"), columns: ["a"], dialect: my)!.inlined(for: my)
            .contains(#"LIKE LOWER('5\\%\\_%')"#))
        // "Doesn't contain" holds for every column; "=" compares the text form.
        let not = DatabaseSearch.Request(term: "x", op: .notContains, tables: [])
        #expect(DatabaseSearch.statement(not, table: TableRef("t"), columns: ["a", "b"], dialect: pg)!.inlined(for: pg)
                == #"SELECT COUNT(*) FROM "t" WHERE ("a"::text NOT ILIKE '%x%' AND "b"::text NOT ILIKE '%x%')"#)
        #expect(DatabaseSearch.Request(term: "Ann", op: .equals, tables: []).condition == FilterCondition(.anyColumn, .equal, "Ann"))
        #expect(DatabaseSearch.statement(DatabaseSearch.Request(term: "", tables: []), table: TableRef("t"), columns: ["a"],
                                         dialect: pg) == nil)
    }

    @Test func reportsCountsTableByTable() async throws {
        let connection = SearchConnection(tables: [
            "people": (people, [[.integer(3)]]),
            "notes": ([ColumnInfo(name: "body", typeName: "text")], [[.integer(0)]]),
        ])
        let request = DatabaseSearch.Request(term: "ann", tables: [TableRef("people"), TableRef("notes"), TableRef("gone")])
        var searched: [String] = []
        var found: [DatabaseSearch.Hit] = []
        var failed: [String] = []
        for await event in DatabaseSearch.run(request, on: connection) {
            switch event {
            case .searching(let t, let i, let n): searched.append("\(t.name) \(i + 1)/\(n)")
            case .found(let hit): found.append(hit)
            case .failed(let t, _): failed.append(t.name)
            }
        }
        #expect(searched == ["people 1/3", "notes 2/3", "gone 3/3"])
        // Tables without a match aren't listed; a missing table is reported and the search goes on.
        #expect(found == [DatabaseSearch.Hit(table: TableRef("people"), count: 3)])
        #expect(failed == ["gone"])
        #expect(connection.sent.count == 2 && connection.sent.allSatisfy { $0.hasPrefix("SELECT COUNT(*)") })
    }

    @Test func stoppingCancelsTheRunningStatement() async throws {
        let connection = SearchConnection(
            tables: ["big": ([ColumnInfo(name: "t", typeName: "text")], []), "after": ([ColumnInfo(name: "t", typeName: "text")], [])],
            slow: ["big"])
        let request = DatabaseSearch.Request(term: "x", tables: [TableRef("big"), TableRef("after")])
        let task = Task {
            var events = 0
            for await _ in DatabaseSearch.run(request, on: connection) { events += 1 }
            return events
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(connection.stoppedTables == ["big"])
        #expect(connection.sent.count == 1)
    }
}

@Suite struct SchemaDiagramTests {
    private func table(_ name: String, references: [String] = []) -> SchemaDiagram.Table {
        SchemaDiagram.Table(
            ref: TableRef(schema: "s", name), columns: [ColumnInfo(name: "id", typeName: "int")],
            foreignKeys: references.map {
                ForeignKeyInfo(name: "", columns: ["\($0)_id"], referencedTable: TableRef(schema: "s", $0), referencedColumns: ["id"])
            })
    }

    @Test func referencedTablesSitLeftOfTheirChildren() {
        let d = SchemaDiagram(tables: [
            table("order_items", references: ["orders", "products"]),
            table("orders", references: ["customers"]),
            table("customers"),
            table("products"),
            table("logs"),
            table("audit", references: ["audit"]),
            table("elsewhere", references: ["missing"]),
        ])
        #expect(d.edges.count == 4)  // self-reference kept as an edge, missing parent dropped
        let size = CGSize(width: 120, height: 80)
        let p = d.layout(sizes: Array(repeating: size, count: d.tables.count))
        let at = Dictionary(uniqueKeysWithValues: d.tables.enumerated().map { ($1.ref.name, p[$0]) })
        #expect(at["customers"]!.x < at["orders"]!.x)
        #expect(at["orders"]!.x < at["order_items"]!.x)
        #expect(at["products"]!.x < at["order_items"]!.x)
        // Tables without keys go below the group, in a row by name.
        let loose = ["audit", "elsewhere", "logs"].map { at[$0]! }
        #expect(loose.allSatisfy { $0.y > at["order_items"]!.y })
        #expect(loose.map(\.x) == loose.map(\.x).sorted())
        // No two boxes overlap.
        let frames = p.map { CGRect(origin: $0, size: size) }
        for i in frames.indices { for j in frames.indices where i < j { #expect(!frames[i].intersects(frames[j])) } }
        // The same input lays out the same way.
        #expect(d.layout(sizes: Array(repeating: size, count: d.tables.count)) == p)
    }

    @Test func cyclesStillLayOut() {
        let d = SchemaDiagram(tables: [table("a", references: ["b"]), table("b", references: ["a"])])
        let p = d.layout(sizes: [CGSize(width: 50, height: 50), CGSize(width: 50, height: 50)])
        #expect(p[0] != p[1])
    }
}
