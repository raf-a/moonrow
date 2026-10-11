public enum SQLKeywords {
    /// Reserved and common words shared by SQLite, PostgreSQL and MySQL.
    public static let common: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE",
        "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE",
        "DESC", "DISTINCT", "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXISTS", "EXPLAIN",
        "FALSE", "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING", "IF", "IN",
        "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE",
        "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES",
        "RENAME", "REPLACE", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "SAVEPOINT", "SCHEMA",
        "SELECT", "SET", "TABLE", "TEMP", "TEMPORARY", "THEN", "TO", "TRANSACTION", "TRIGGER",
        "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW", "WHEN",
        "WHERE", "WITH",
    ]

    /// Built-in functions common to SQLite, PostgreSQL and MySQL, offered by autocomplete.
    public static let functions: [String] = [
        "abs", "avg", "cast", "coalesce", "count", "date", "group_concat", "ifnull", "instr", "length",
        "lower", "ltrim", "max", "min", "now", "nullif", "random", "replace", "round", "rtrim", "substr",
        "substring", "sum", "trim", "upper",
    ]
}
