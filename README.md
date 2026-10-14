# Moonrow

A native macOS database client for SQLite, PostgreSQL, MySQL and MariaDB, written in Swift and AppKit.

## Features

- **Connections:** SQLite files, PostgreSQL, MySQL and MariaDB, over TLS and SSH tunnels (through the system's OpenSSH, so `~/.ssh/config`, keys and the agent just work). Passwords live in the Keychain. Connections can be grouped, coloured and tagged.
- **Data grid:** fast paging through millions of rows, sorting, filters and quick filters, and cell, row and multi-row editing. Edits are staged per workspace, with undo, a SQL preview and a single commit.
- **Query editor:** tabs, run current or all, autocomplete, history, saved queries in folders, a formatter, query parameters, pinned results and charts.
- **Structure:** columns, indexes, foreign keys, views, functions and triggers, all edited with a DDL preview, plus a schema diagram.
- **Transfer:** export to CSV, JSON, SQL and XLSX; import CSV, JSON and SQL; back up and restore with `pg_dump` and `mysqldump`.
- **Safety:** per-connection safe modes that confirm or ask for a password before writes, and a log of every statement sent.

## Install

Download the latest `Moonrow-<version>.dmg` from [Releases](../../releases) and drag Moonrow to Applications. It needs macOS 14 or later and runs natively on Apple silicon and Intel.

## Build from source

You need Xcode 26 or later (Swift 6).

```bash
swift build
swift test
scripts/build-app.sh          # writes build/Moonrow.app
```

To work in Xcode, open `Package.swift`.

The PostgreSQL, MySQL, MariaDB and SSH tests run against throwaway Docker containers and are skipped otherwise:

```bash
scripts/test-servers.sh up
eval "$(scripts/test-servers.sh env)" && swift test
scripts/test-servers.sh down
```

## Layout

| Path | What's there |
|---|---|
| `Sources/SQLScript` | SQL lexer, statement splitter, current statement |
| `Sources/DBKit` | Driver contract, dialects, filters, change sets |
| `Sources/WireSupport` | Sockets, TLS and framing (SwiftNIO) for the network drivers |
| `Sources/DriverSQLite`, `DriverPostgres`, `DriverMySQL` | One module per database; Postgres and MySQL are our own wire-protocol clients |
| `Sources/SSHTunnel`, `Sources/moonrow-ssh-helper` | SSH tunnels over `/usr/bin/ssh` |
| `Sources/AppCore` | App logic without AppKit, covered by `swift test` |
| `Sources/Moonrow` | The AppKit app |

Releases are built by GitHub Actions; see [docs/RELEASING.md](docs/RELEASING.md).

## License

[MIT](LICENSE)
