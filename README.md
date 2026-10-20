<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="">
</p>

<h1 align="center">Moonrow</h1>

<p align="center">
  A native Mac app for SQLite, PostgreSQL, MySQL and MariaDB.
  <br>
  <a href="https://github.com/raf-a/moonrow/releases/latest">Download</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme-dark.png">
  <img src="docs/images/readme-light.png" alt="A Moonrow window on a sample shop database, with its tables in the sidebar, a query in the editor and the query’s results in a grid below.">
</picture>

## Features

- **Staged edits:** changes to rows, structure, views and functions wait until you commit them. You can read the SQL first, and undo any change.
- **Query editor:** completion for tables, columns and aliases, and a failed statement underlined where the server points.
- **Data grid:** scroll through millions of rows, filter and sort, and paste ranges of cells from a spreadsheet.
- **Saved queries as files:** each connection’s queries are `.sql` files in a folder, ready for any editor or version control.
- **SQLite, PostgreSQL, MySQL and MariaDB,** with no client libraries to install. SQLite databases can be encrypted with SQLCipher, or opened on a server over SSH.
- **SSH tunnels** through your Mac’s own OpenSSH, so your `~/.ssh/config` and keys work as they do in Terminal.
- **Safe mode:** a connection can ask for confirmation, its password or Touch ID before it sends changes. A Production tag shows in the window’s title.
- **Import, export, backup and restore:** CSV, JSON, SQL and Excel, files of any size, and whole databases backed up and restored with tools built into the app.
- **MCP server:** MCP clients such as Claude Code and Codex can run queries on your connections, each with its own access token, and wait for your approval before they change data.
- **Search:** open any table, view or saved query by name, and search for a value across every table.
- **Native Mac app:** Liquid Glass on macOS 26, editor themes, and custom keyboard shortcuts.

## Install

Download the [latest release](https://github.com/raf-a/moonrow/releases/latest). Moonrow needs macOS 14 or later, and updates itself.

## Build from source

With Xcode 26 or later:

```bash
swift build
scripts/build-app.sh
```

## Contributing

To report a bug or ask for a feature, [open an issue](https://github.com/raf-a/moonrow/issues). For a bug, say which database and version you use, the steps that cause it, and what you expected to happen.

Pull requests are welcome. For a larger change, open an issue first so we can agree on the approach.

## Licence

[MIT](LICENSE)
