import DBKit
import DriverMySQL
import DriverPostgres
import Foundation

/// A collation New Database… offers: its name in the list, and what `CREATE DATABASE` takes.
public struct DatabaseCollation: Sendable, Hashable {
    public enum Provider: String, Sendable, Hashable {
        /// The operating system's locales (Postgres `libc`); MySQL's collations count as these.
        case libc
        /// Postgres's ICU collations.
        case icu
        /// Postgres 17+'s own (`builtin`): C, C.UTF-8, PG_UNICODE_FAST.
        case builtin
    }

    public var name: String
    public var provider: Provider
    /// Postgres: the locale `LOCALE` or `ICU_LOCALE` takes. MySQL: the name again.
    public var locale: String

    public init(name: String, provider: Provider = .libc, locale: String? = nil) {
        self.name = name
        self.provider = provider
        self.locale = locale ?? name
    }
}

/// What a new database is made with; nil leaves the clause out, so the server's default applies.
public struct NewDatabase: Sendable, Hashable {
    public var name: String
    public var encoding: String?
    public var collation: DatabaseCollation?

    public init(name: String, encoding: String? = nil, collation: DatabaseCollation? = nil) {
        self.name = name
        self.encoding = encoding
        self.collation = collation
    }
}

/// The server's databases, for Open Database (⌘K), New Database… and the Backup and Restore
/// windows, and the statements that create, rename and drop them.
public enum DatabaseCatalog {
    /// The databases ⌘K lists. Postgres: those that take connections, templates left out. MySQL:
    /// those the sidebar lists, without the system ones.
    public static func switchable(_ connection: any DatabaseConnection) async throws -> [String] {
        let names: [String]
        if connection.dialect is PostgresDialect {
            names = try await connection.execute(SQLStatement(
                "SELECT datname FROM pg_catalog.pg_database WHERE datallowconn AND NOT datistemplate"))
                .rows.compactMap { $0.first?.string }
        } else {
            names = try await connection.schemas()
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The database the connection is in now: Postgres's `current_database()`, MySQL's `DATABASE()`.
    public static func current(_ connection: any DatabaseConnection) async throws -> String? {
        let sql = connection.dialect is PostgresDialect ? "SELECT current_database()" : "SELECT DATABASE()"
        return try await connection.execute(SQLStatement(sql)).rows.first?.first?.string
    }

    /// Encodings (Postgres) or character sets (MySQL) the server has, by name.
    public static func encodings(_ connection: any DatabaseConnection) async throws -> [String] {
        let sql = connection.dialect is PostgresDialect
            // Server encodings are ids 0–34 (PG_ENCODING_BE_LAST); later ones are client-only.
            ? "SELECT pg_catalog.pg_encoding_to_char(i) FROM generate_series(0, 34) AS i WHERE pg_catalog.pg_encoding_to_char(i) <> ''"
            : "SELECT CHARACTER_SET_NAME FROM information_schema.CHARACTER_SETS"
        return try await connection.execute(SQLStatement(sql)).rows.compactMap { $0.first?.string }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Collations a database with `encoding` can use (any encoding when nil). Postgres: libc
    /// collations of that encoding (or of any), and ICU ones. MySQL: the character set's.
    public static func collations(_ connection: any DatabaseConnection, encoding: String?) async throws -> [DatabaseCollation] {
        let list: [DatabaseCollation]
        if connection.dialect is PostgresDialect {
            // ICU and builtin locales are `colllocale` from Postgres 17, `colliculocale` before.
            // Before 10 every collation is libc's and there's no `collprovider`.
            var sql = """
                SELECT c.collname, p.provider, COALESCE(c.collcollate, to_jsonb(c) ->> 'colllocale', to_jsonb(c) ->> 'colliculocale')
                FROM pg_catalog.pg_collation c, LATERAL (SELECT coalesce(to_jsonb(c) ->> 'collprovider', 'c') AS provider) p
                WHERE p.provider IN ('c', 'i', 'b')
                """
            var bindings: [DBValue] = []
            if let encoding {
                sql += " AND c.collencoding IN (-1, pg_catalog.pg_char_to_encoding($1))"
                bindings = [.text(encoding)]
            }
            list = try await connection.execute(SQLStatement(sql, bindings: bindings)).rows.compactMap { row in
                guard let name = row.first?.string, let locale = row[safe: 2]?.string, !locale.isEmpty else { return nil }
                let provider: DatabaseCollation.Provider = switch row[safe: 1]?.string {
                case "i": .icu
                case "b": .builtin
                default: .libc
                }
                return DatabaseCollation(name: name, provider: provider, locale: locale)
            }
        } else {
            var sql = "SELECT COLLATION_NAME FROM information_schema.COLLATIONS"
            var bindings: [DBValue] = []
            if let encoding {
                sql += " WHERE CHARACTER_SET_NAME = ?"
                bindings = [.text(encoding)]
            }
            list = try await connection.execute(SQLStatement(sql, bindings: bindings)).rows.compactMap { $0.first?.string }
                .map { DatabaseCollation(name: $0) }
        }
        // One entry per name (a libc name can exist for several encodings).
        var seen = Set<String>()
        return list.filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `CREATE DATABASE`. Postgres needs `TEMPLATE template0` for an encoding or locale other
    /// than template1's. A libc locale is spelled out as LC_COLLATE and LC_CTYPE, which every
    /// version takes (LOCALE came in 13).
    public static func createSQL(_ new: NewDatabase, dialect: any Dialect) -> String {
        var sql = "CREATE DATABASE \(dialect.quoteIdentifier(new.name))"
        let text = { (s: String) in dialect.literal(.text(s)) }
        if dialect is PostgresDialect {
            if let e = new.encoding { sql += " ENCODING \(text(e))" }
            if let c = new.collation {
                switch c.provider {
                case .libc: sql += " LC_COLLATE \(text(c.locale)) LC_CTYPE \(text(c.locale))"
                case .icu: sql += " LOCALE_PROVIDER icu ICU_LOCALE \(text(c.locale))"
                case .builtin: sql += " LOCALE_PROVIDER builtin BUILTIN_LOCALE \(text(c.locale))"
                }
            }
            if new.encoding != nil || new.collation != nil { sql += " TEMPLATE template0" }
        } else {
            if let e = new.encoding { sql += " CHARACTER SET \(dialect.quoteIdentifier(e))" }
            if let c = new.collation { sql += " COLLATE \(dialect.quoteIdentifier(c.name))" }
        }
        return sql
    }

    /// Postgres only: MySQL has no way to rename a database.
    public static func renameSQL(_ name: String, to new: String, dialect: any Dialect) -> String? {
        guard dialect is PostgresDialect else { return nil }
        return "ALTER DATABASE \(dialect.quoteIdentifier(name)) RENAME TO \(dialect.quoteIdentifier(new))"
    }

    public static func dropSQL(_ name: String, dialect: any Dialect) -> String {
        "DROP DATABASE \(dialect.quoteIdentifier(name))"
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension DatabaseCatalog {
    /// Whether ⌘K switches databases on this connection (Postgres reconnects, MySQL runs `USE`);
    /// SQLite has one database.
    public static func canSwitch(_ connection: any DatabaseConnection) -> Bool {
        connection is PostgresConnection || connection is MySQLConnection
    }

    /// Switches the connection to `name`: Postgres opens a session on that database in place of
    /// the current one, MySQL runs `USE`.
    public static func switchTo(_ name: String, on connection: any DatabaseConnection) async throws {
        if let pg = connection as? PostgresConnection {
            try await pg.switchDatabase(to: name)
        } else if let sql = connection.dialect.useSchema(name) {
            _ = try await connection.execute(SQLStatement(sql))
        }
    }
}

extension DatabaseCatalog {
    /// What a new database gets when Encoding is Default: template1's encoding (Postgres), the
    /// server's character set (MySQL). New Database… lists the collations for it.
    public static func defaultEncoding(_ connection: any DatabaseConnection) async throws -> String? {
        let sql = connection.dialect is PostgresDialect
            ? "SELECT pg_catalog.pg_encoding_to_char(encoding) FROM pg_catalog.pg_database WHERE datname = 'template1'"
            : "SELECT @@character_set_server"
        return try await connection.execute(SQLStatement(sql)).rows.first?.first?.string
    }
}
