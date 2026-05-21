# Vendored third-party sources

These amalgamations are checked into the repo so a release build is
self-contained — no network fetch at build time, no submodules.

To refresh, see the URLs and version pins below.

## SQLite — 3.53.1

- Files: `sqlite/sqlite3.c`, `sqlite/sqlite3.h`, `sqlite/sqlite3ext.h`
- Source: <https://sqlite.org/2026/sqlite-amalgamation-3530100.zip>
- License: Public domain (declared in the file header of `sqlite3.c`)

## sqlite-vec — v0.1.9

- Files: `sqlite-vec/sqlite-vec.c`, `sqlite-vec/sqlite-vec.h`
- Source: <https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-amalgamation.zip>
- License: Apache-2.0 OR MIT (dual-licensed) — see `sqlite-vec/LICENSE-APACHE`
  and `sqlite-vec/LICENSE-MIT`

## md4c — release-0.5.3

- Files: `md4c/md4c.c`, `md4c/md4c.h`
- Source: <https://github.com/mity/md4c/archive/refs/tags/release-0.5.3.tar.gz>
  (`src/md4c.{c,h}` only — entity tables and the HTML renderer are not used)
- License: MIT — see `md4c/LICENSE.md`
