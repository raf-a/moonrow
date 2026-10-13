import DBKit
import Foundation

/// The text a new view, routine or trigger starts from: a small statement that runs as it is,
/// for the user to edit before committing.
public enum DefinitionTemplate {
    public static func text(
        _ kind: DefinitionKind, name: String, schema: String?, table: TableRef? = nil, dialect: any Dialect
    ) -> String {
        let q = dialect.quoteIdentifier
        let target = dialect is SQLiteDialect ? q(name) : dialect.qualified(TableRef(schema: schema, name))
        let on = table.map { dialect is SQLiteDialect ? q($0.name) : dialect.qualified($0) } ?? q("table_name")
        switch (kind, dialect) {
        case (.view, _):
            return "CREATE VIEW \(target) AS\nSELECT\n    1 AS \(q("id"));\n"
        case (.materializedView, _):
            return "CREATE MATERIALIZED VIEW \(target) AS\nSELECT\n    1 AS \(q("id"))\nWITH DATA;\n"
        case (.function, is PostgresDialect):
            return "CREATE OR REPLACE FUNCTION \(target)()\nRETURNS integer\nLANGUAGE sql\nAS $$\n    SELECT 1;\n$$;\n"
        case (.procedure, is PostgresDialect):
            return "CREATE OR REPLACE PROCEDURE \(target)()\nLANGUAGE plpgsql\nAS $$\nBEGIN\n    NULL;\nEND;\n$$;\n"
        case (.trigger, is PostgresDialect):
            // A Postgres trigger calls a function; the template brings one along.
            let function = dialect.qualified(TableRef(schema: schema, name + "_fn"))
            return """
                CREATE OR REPLACE FUNCTION \(function)()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    RETURN NEW;
                END;
                $$;

                CREATE TRIGGER \(q(name))
                BEFORE UPDATE ON \(on)
                FOR EACH ROW
                EXECUTE FUNCTION \(function)();

                """
        case (.function, _):
            return "CREATE FUNCTION \(target)()\nRETURNS INT\nDETERMINISTIC\nRETURN 1;\n"
        case (.procedure, _):
            return "CREATE PROCEDURE \(target)()\nBEGIN\n    SELECT 1;\nEND;\n"
        case (.trigger, is SQLiteDialect):
            return "CREATE TRIGGER \(target)\nAFTER UPDATE ON \(on)\nBEGIN\n    SELECT 1;\nEND;\n"
        case (.trigger, _):
            return "CREATE TRIGGER \(target)\nBEFORE UPDATE ON \(on)\nFOR EACH ROW\nBEGIN\nEND;\n"
        }
    }
}
