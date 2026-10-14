# Moonrow

A native macOS database client for SQLite, PostgreSQL, MySQL and MariaDB, written in Swift and AppKit.

## Build

Run `swift build` and `swift test` from the repo root, with the Bash sandbox disabled; SwiftPM fails inside the sandbox.
- Swift 6 language mode with strict concurrency. Targets macOS 14.
- Tests use Swift Testing (`import Testing`).
- Server tests (Postgres, MySQL, MariaDB) skip unless their env vars are set: `scripts/test-servers.sh up`, then `eval "$(scripts/test-servers.sh env)" && swift test`. Only touch the `moonrow-test-*` containers; others on this machine are the user's.

Layout:
- `Sources/SQLScript`: lexer, statement splitter, current statement.
- `Sources/DBKit`: driver contract, dialects, filters, change sets.
- `Sources/Driver*`: one module per database. Postgres and MySQL are our own wire-protocol clients over `Sources/WireSupport` (SwiftNIO + NIOSSL).
- `Sources/SSHTunnel` + `Sources/moonrow-ssh-helper`: SSH tunnels over the system's `/usr/bin/ssh` (ControlMaster, `-W` per socket, askpass relay). Tests never touch `~/.ssh`.
- `Sources/AppCore`: app logic without AppKit (connection store, connection factory, row cache). Tested.
- `Sources/Moonrow`: the AppKit app, UI built in code. `scripts/build-app.sh` bundles it into `build/Moonrow.app`. Icon: `Assets/AppIcon.icon` (Icon Composer, Liquid Glass on macOS 26+, compiled by actool into `Assets.car`) plus `Assets/AppIcon.iconset` (the `.icns` fallback). Layer sources live in the Figma board "macOS app icon · Liquid Glass".
  - The sandbox can't screenshot. To check UI, use the harness in `DevHarness.swift` (`MOONROW_SNAPSHOTS`, `MOONROW_BENCH`, `MOONROW_DEMO`, which commits, so use a copy; `MOONROW_QUERY`, which drives the query editor; `MOONROW_CONNECT` + `MOONROW_OPEN` for a server workspace; `MOONROW_FORM`; `MOONROW_SAFETY`, `MOONROW_PREFS`, `MOONROW_EXPORT`, `MOONROW_IMPORT`, which commits; `MOONROW_STAGED`, the staged-changes model, which never commits; `MOONROW_EDITING`, undo, the sidebar's delete keys, the right sidebar and ⌘S, which commits; `MOONROW_NAVIGATE`, preview tabs, Quick Open, Back / Forward, panes and workspaces, then `MOONROW_SESSION=check` relaunches and compares the restored session; `MOONROW_OPENDB` with `MOONROW_CONNECT`, Quick Open across schemas and ⌘K; `MOONROW_WELCOME`, connection groups and tags, on an empty store; `MOONROW_POWER`, M9's grid and query features, which never commits; `MOONROW_OBJECTS`, M10's views, routines, triggers, clones, search and diagram, which commits; `MOONROW_TRANSFER`, M11's export, import, backup and restore, which commits and writes files to `MOONROW_SNAPSHOTS`; `MOONROW_SHOW`, saved connections and tables opened by name and left running). Pass `MOONROW_STORE` so it never touches the real connections file.
  - Snapshots don't show Liquid Glass. To see the real look, launch hidden with `open -g -j -n --env MOONROW_BACKGROUND=1 --env MOONROW_STORE=… --env MOONROW_SHOW=… build/Moonrow.app` and capture its windows with the computer-use `app_screenshot` tool, which doesn't take over the screen. Don't click around the user's screen.

## Releases

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`; see `docs/RELEASING.md`. `scripts/build-app.sh` and `scripts/package-release.sh` do the same steps locally.
