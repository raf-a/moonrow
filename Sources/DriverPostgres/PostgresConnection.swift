import DBKit
import Foundation
import WireSupport

/// A connection to one Postgres database. Statements run one at a time on a single backend,
/// which is opened again if the server drops it between statements.
public final class PostgresConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect: any Dialect = PostgresDialect()
    public let configuration: PostgresConfiguration
    /// `server_version` as reported at login, e.g. `18.0 (Debian 18.0-1.pgdg13+3)`.
    public let serverVersion: String
    public let statementLog: StatementLog?
    private let host: SessionHost<PGSession>

    private init(configuration: PostgresConfiguration, first: PGSession, log: StatementLog) {
        self.configuration = configuration
        self.serverVersion = first.parameters["server_version"] ?? ""
        self.statementLog = log
        self.host = SessionHost(first: first) { try await PGSession.open(configuration, log: log) }
    }

    public static func connect(_ configuration: PostgresConfiguration) async throws -> PostgresConnection {
        let log = StatementLog()
        return PostgresConnection(configuration: configuration, first: try await PGSession.open(configuration, log: log), log: log)
    }

    public func close() async {
        await host.close()
    }

    public func setKeepAlive(_ interval: Duration?) {
        host.setKeepAlive(interval)
    }

    /// The backend process serving this connection right now (`pg_backend_pid()`).
    public func backendProcessID() async throws -> Int32 {
        try await host.withSession { $0.processID }
    }

    public func stream(_ statement: SQLStatement, batchSize: Int) -> AsyncThrowingStream<ResultBatch, any Error> {
        host.stream(statement, batchSize: batchSize)
    }

    public func transaction(
        _ statements: [SQLStatement], verify: @Sendable (Int, Int) throws -> Void
    ) async throws -> [Int] {
        let dialect = dialect
        return try await host.withSession { session in
            try await session.query(dialect.beginTransaction)
            do {
                var counts: [Int] = []
                for (i, statement) in statements.enumerated() {
                    let n = try await session.query(statement.sql, statement.bindings).rowsAffected ?? 0
                    try verify(i, n)
                    counts.append(n)
                }
                try await session.query(dialect.commitTransaction)
                return counts
            } catch {
                if session.isAlive, session.transactionStatus != UInt8(ascii: "I") {
                    _ = try? await session.query(dialect.rollbackTransaction)
                }
                throw error
            }
        }
    }

    public func withTransaction<T: Sendable>(_ body: @Sendable (any TransactionScope) async throws -> T) async throws -> T {
        let dialect = dialect
        return try await host.withSession { session in
            try await session.query(dialect.beginTransaction)
            do {
                let value = try await body(PGScope(session: session))
                try await session.query(dialect.commitTransaction)
                return value
            } catch {
                if session.isAlive, session.transactionStatus != UInt8(ascii: "I") {
                    _ = try? await session.query(dialect.rollbackTransaction)
                }
                throw error
            }
        }
    }

    public func copyIn(_ sql: String, from source: @escaping CopySource) async throws -> Int {
        try await host.withSession { try await $0.copyIn(sql, from: source) }
    }

    private func rows(_ sql: String, _ bindings: [DBValue] = []) async throws -> [[DBValue]] {
        try await host.withSession { try await $0.query(sql, bindings).rows }
    }

    // MARK: - Introspection

    public func schemas() async throws -> [String] {
        try await rows("""
            SELECT nspname FROM pg_catalog.pg_namespace
            WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
            ORDER BY nspname
            """).compactMap { $0.first?.string }
    }

    public func currentSchema() async throws -> String? {
        try await rows("SELECT current_schema()").first?.first?.string
    }

    public func objects(schema: String?) async throws -> [DatabaseObject] {
        let namespace = schema.map { DBValue.text($0) } ?? .null
        // Relations, then routines: every overload, with the argument types that tell it apart.
        // Functions that belong to an extension are left out.
        let relations = try await rows("""
            SELECT n.nspname, c.relname, c.relkind::text
            FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = coalesce($1, current_schema()) AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
            ORDER BY c.relname
            """, [namespace])
        let routines = try await rows("""
            SELECT n.nspname, p.proname, p.prokind::text, pg_catalog.pg_get_function_identity_arguments(p.oid)
            FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = coalesce($1, current_schema()) AND p.prokind IN ('f', 'p')
              AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_depend d
                WHERE d.classid = 'pg_catalog.pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
            ORDER BY p.proname, 4
            """, [namespace])
        let kinds: [String: ObjectKind] = ["r": .table, "p": .table, "f": .table, "v": .view, "m": .materializedView]
        return relations.compactMap { row in
            guard let ns = row[0].string, let name = row[1].string, let kind = row[2].string.flatMap({ kinds[$0] })
            else { return nil }
            return DatabaseObject(TableRef(schema: ns, name), kind: kind)
        } + routines.compactMap { row in
            guard let ns = row[0].string, let name = row[1].string else { return nil }
            return DatabaseObject(TableRef(schema: ns, name), kind: row[2].string == "p" ? .procedure : .function,
                                  signature: row[3].string ?? "")
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let rows = try await rows("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                   CASE WHEN a.attgenerated = '' THEN pg_catalog.pg_get_expr(d.adbin, d.adrelid) END,
                   array_position(i.indkey::int2[], a.attnum) - array_lower(i.indkey::int2[], 1) + 1,
                   pg_catalog.col_description(a.attrelid, a.attnum), a.attidentity::text,
                   CASE WHEN a.attgenerated <> '' THEN pg_catalog.pg_get_expr(d.adbin, d.adrelid) END,
                   a.attgenerated::text
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_catalog.pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
            WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [.text(dialect.qualified(table))])
        return rows.map { row in
            var pk: Int?
            if case .integer(let n) = row[4] { pk = Int(n) }
            // attidentity: 'a' ALWAYS, 'd' BY DEFAULT. attgenerated: 's' STORED, 'v' VIRTUAL (18+).
            let identity = row[6].string ?? ""
            var generated: String?
            if identity == "a" { generated = "GENERATED ALWAYS AS IDENTITY" }
            if identity == "d" { generated = "GENERATED BY DEFAULT AS IDENTITY" }
            if let expression = row[7].string {
                generated = "GENERATED ALWAYS AS (\(expression)) \(row[8].string == "v" ? "VIRTUAL" : "STORED")"
            }
            return ColumnInfo(
                name: row[0].string ?? "", typeName: row[1].string ?? "",
                isNullable: row[2] == .bool(true), defaultExpression: row[3].string,
                primaryKeyPosition: pk, comment: row[5].string, isAutoIncrement: !identity.isEmpty,
                generated: generated)
        }
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        var s = TableStructure(
            table: table, columns: try await columns(of: table), indexes: try await indexes(of: table),
            foreignKeys: try await foreignKeys(of: table), triggers: try await triggers(of: table))
        s.comment = try await rows(
            "SELECT pg_catalog.obj_description($1::regclass, 'pg_class')", [.text(dialect.qualified(table))]
        ).first?.first?.string
        return s
    }

    public func definition(of object: DatabaseObject) async throws -> String {
        let name = dialect.qualified(object.ref)
        switch object.kind {
        case .view:
            // check_option and security_barrier are reloptions; WITH (…) restates them.
            let row = try await rows("""
                SELECT pg_catalog.pg_get_viewdef(c.oid, true), array_to_string(c.reloptions, ', ')
                FROM pg_catalog.pg_class c WHERE c.oid = $1::regclass
                """, [.text(name)]).first
            let options = row?[1].string.map { $0.isEmpty ? "" : " WITH (\($0))" } ?? ""
            return "CREATE OR REPLACE VIEW \(name)\(options) AS\n" + Self.statementBody(row?[0].string ?? "") + ";"
        case .materializedView:
            let row = try await rows("""
                SELECT pg_catalog.pg_get_viewdef(c.oid, true), c.relispopulated
                FROM pg_catalog.pg_class c WHERE c.oid = $1::regclass
                """, [.text(name)]).first
            let data = row?[1] == .bool(false) ? "WITH NO DATA" : "WITH DATA"
            var statements = ["CREATE MATERIALIZED VIEW \(name) AS\n" + Self.statementBody(row?[0].string ?? "") + "\n" + data]
            statements += try await indexes(of: object.ref).compactMap(\.definition)
            return statements.map { $0 + ";" }.joined(separator: "\n\n")
        case .function, .procedure:
            // One overload when the signature is known, else every routine of that name.
            // (regprocedure won't read argument names, so the signature is matched as listed.)
            let found = try await rows("""
                SELECT pg_catalog.pg_get_functiondef(p.oid)
                FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = coalesce($1, current_schema()) AND p.proname = $2 AND p.prokind IN ('f', 'p')
                  AND ($3::text IS NULL OR pg_catalog.pg_get_function_identity_arguments(p.oid) = $3)
                ORDER BY p.oid
                """, [object.ref.schema.map(DBValue.text) ?? .null, .text(object.ref.name),
                      object.signature.map(DBValue.text) ?? .null])
            return found.compactMap { $0.first?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        default:
            let s = try await structure(of: object.ref)
            var design = TableDesign(s)
            // Postgres keeps each index's own definition; constraint indexes come with the table.
            design.indexes = []
            var statements = dialect.createTable(design, schema: object.ref.schema).statements
            statements += s.indexes.filter { !$0.isConstraint }.compactMap(\.definition)
            statements += s.triggers.map(\.definition)
            return statements.map { $0 + ";" }.joined(separator: "\n\n")
        }
    }

    /// `pg_get_viewdef` text without its final `;` and surrounding blank space.
    static func statementBody(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        return body
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let rows = try await rows("""
            SELECT ic.relname, ix.indisunique, ix.indisprimary, am.amname,
                   pg_catalog.pg_get_indexdef(ix.indexrelid, k, true),
                   pg_catalog.pg_get_expr(ix.indpred, ix.indrelid, true),
                   EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.conindid = ix.indexrelid
                           AND c.conrelid = ix.indrelid AND c.contype IN ('p', 'u', 'x')),
                   pg_catalog.pg_get_indexdef(ix.indexrelid)
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class ic ON ic.oid = ix.indexrelid
            JOIN pg_catalog.pg_am am ON am.oid = ic.relam
            CROSS JOIN LATERAL generate_series(1, ix.indnkeyatts) AS k
            WHERE ix.indrelid = $1::regclass
            ORDER BY ic.relname, k
            """, [.text(dialect.qualified(table))])
        var out: [IndexInfo] = []
        for row in rows {
            let name = row[0].string ?? ""
            let column = row[4].string ?? ""
            if out.last?.name == name {
                out[out.count - 1].columns.append(column)
            } else {
                out.append(IndexInfo(
                    name: name, columns: [column], isUnique: row[1] == .bool(true), isPrimary: row[2] == .bool(true),
                    method: row[3].string, predicate: row[5].string, isConstraint: row[6] == .bool(true),
                    definition: row[7].string))
            }
        }
        return out
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let rows = try await rows("""
            SELECT con.conname, att.attname, fn.nspname, fc.relname, fatt.attname,
                   con.confupdtype::text, con.confdeltype::text
            FROM pg_catalog.pg_constraint con
            CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(col, fcol, pos)
            JOIN pg_catalog.pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = k.col
            JOIN pg_catalog.pg_class fc ON fc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace
            JOIN pg_catalog.pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = k.fcol
            WHERE con.conrelid = $1::regclass AND con.contype = 'f'
            ORDER BY con.conname, k.pos
            """, [.text(dialect.qualified(table))])
        let actions = ["a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"]
        var out: [ForeignKeyInfo] = []
        for row in rows {
            let name = row[0].string ?? ""
            let column = row[1].string ?? ""
            let referenced = row[4].string ?? ""
            if out.last?.name == name {
                out[out.count - 1].columns.append(column)
                out[out.count - 1].referencedColumns.append(referenced)
            } else {
                out.append(ForeignKeyInfo(
                    name: name, columns: [column],
                    referencedTable: TableRef(schema: row[2].string, row[3].string ?? ""),
                    referencedColumns: [referenced],
                    onUpdate: actions[row[5].string ?? "a"] ?? "NO ACTION",
                    onDelete: actions[row[6].string ?? "a"] ?? "NO ACTION"))
            }
        }
        return out
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        let rows = try await rows("""
            SELECT t.tgname, t.tgtype, pg_catalog.pg_get_triggerdef(t.oid, true)
            FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = $1::regclass AND NOT t.tgisinternal
            ORDER BY t.tgname
            """, [.text(dialect.qualified(table))])
        return rows.map { row in
            // tgtype bits, from pg_trigger.h: 2 BEFORE, 64 INSTEAD; 4 INSERT, 8 DELETE, 16 UPDATE, 32 TRUNCATE.
            var bits = 0
            if case .integer(let n) = row[1] { bits = Int(n) }
            let timing = bits & 2 != 0 ? "BEFORE" : bits & 64 != 0 ? "INSTEAD OF" : "AFTER"
            let events = [(4, "INSERT"), (16, "UPDATE"), (8, "DELETE"), (32, "TRUNCATE")]
                .filter { bits & $0.0 != 0 }.map(\.1)
            return TriggerInfo(name: row[0].string ?? "", timing: timing, events: events, definition: row[2].string ?? "")
        }
    }
}

extension DBValue {
    var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

extension PGSession {
    func query(_ sql: String) async throws {
        _ = try await query(sql, [])
    }
}

/// Statements inside `PostgresConnection.withTransaction`, on the session it holds.
struct PGScope: TransactionScope {
    let session: PGSession

    func execute(_ statement: SQLStatement) async throws -> Int {
        let signal = CancelSignal()
        let collector = Collector()
        try await withTaskCancellationHandler {
            try await session.run(statement, batchSize: 10_000, cancel: signal) { collector.add($0) }
        } onCancel: {
            signal.fire()
        }
        return collector.result.rowsAffected ?? 0
    }
}
