#!/bin/sh
# Creates a throwaway SQLite database for trying the grid.
# Usage: scripts/make-sample-db.sh [path] [rows]   (defaults: build/sample.sqlite, 1000000)
set -eu
path="${1:-build/sample.sqlite}"
rows="${2:-1000000}"
mkdir -p "$(dirname "$path")"
rm -f "$path"
sqlite3 "$path" >/dev/null <<SQL
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  happened_at TEXT NOT NULL,
  kind TEXT NOT NULL,
  user_id INTEGER,
  amount REAL,
  note TEXT,
  payload BLOB
);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < $rows)
INSERT INTO events (id, happened_at, kind, user_id, amount, note, payload)
SELECT i,
       datetime('2024-01-01', '+' || (i * 37 % 31536000) || ' seconds'),
       CASE i % 4 WHEN 0 THEN 'signup' WHEN 1 THEN 'login' WHEN 2 THEN 'purchase' ELSE 'logout' END,
       CASE WHEN i % 11 = 0 THEN NULL ELSE i % 5000 END,
       CASE WHEN i % 4 = 2 THEN round((i % 10000) / 7.0, 2) END,
       CASE WHEN i % 7 = 0 THEN 'multi-line' || char(10) || 'note ' || i ELSE 'note ' || i END,
       CASE WHEN i % 13 = 0 THEN randomblob(16) END
FROM n;
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000)
INSERT INTO users SELECT i, 'User ' || i, 'user' || i || '@example.com' FROM n;
CREATE TABLE empty_table (id INTEGER PRIMARY KEY, label TEXT);
CREATE VIEW purchases AS SELECT id, happened_at, user_id, amount FROM events WHERE kind = 'purchase';
SQL
echo "Wrote $path ($rows events)"
