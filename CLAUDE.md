# memlite — guide for future Claude sessions

memlite is a long-term memory engine for AI agents: a single static
Zig 0.16 binary that speaks MCP stdio, statically links SQLite +
[sqlite-vec](https://github.com/asg017/sqlite-vec) + a CPU-only
[llama.cpp](https://github.com/ggerganov/llama.cpp) + [md4c](https://github.com/mity/md4c),
runs a hybrid (vec0 + FTS5, RRF-fused) retrieval pipeline over a
soft-delete-with-history schema, and embeds locally via a HuggingFace
GGUF model resolved on first run.

## The spec is canonical, not the code

The v1 contract lives in `openspec/changes/v1-foundation/`:

- `proposal.md` — what and why
- `design.md` — decisions and their alternatives
- `specs/{schema,mcp-server,ingest,search,embedding-engine}/spec.md` — normative requirements
- `tasks.md` — the implementation checklist

Anything about tool signatures, error codes, schema columns, or
retrieval semantics — answer from those specs, NOT from memory. If
you find a divergence between code and spec, the spec wins (or the
spec is wrong and we update it; never silently drift).

Two post-v1 proposals are queued under `openspec/changes/`:
`quiet-llama-logs` (suppress llama.cpp loader chatter on stderr) and
`download-progress` (per-chunk progress lines during model download).
Both modify the same requirement in `embedding-engine`; whichever ships
second needs a small rebase.

## MCP tools you should use here

The user runs this project with three project-scoped MCPs that change
how you should work. If any of these are NOT in your tool list, ASK
THE USER TO INSTALL THEM before proceeding — don't fall back to raw
Bash/WebFetch/etc. without checking.

### `context-mode`

For shell commands and HTTP fetches. Bash and WebFetch are
discouraged here because their output enters the context window
verbatim and bloats it; `ctx_execute` and `ctx_fetch_and_index` keep
the raw output in a sandbox and only surface a summary.

- Shell: `mcp__plugin_context-mode_context-mode__ctx_execute` (single)
  or `mcp__plugin_context-mode_context-mode__ctx_batch_execute` (many)
- HTTP: `mcp__plugin_context-mode_context-mode__ctx_fetch_and_index`
- Search indexed content: `mcp__plugin_context-mode_context-mode__ctx_search`

Bash is still fine for git / mkdir / rm / mv / navigation — the
context-mode guidance lists those as exceptions. Use `Read` and
`Edit`/`Write` for file content (never `ctx_execute` for file writes).

If not installed: ask the user to install context-mode.

### `context7`

Use this for current docs on any library, framework, or CLI tool —
including ones whose docs you think you remember. Your training data
predates current llama.cpp / Zig / sqlite-vec / etc., and assumptions
based on it WILL be wrong in subtle ways. Prefer context7 over web
search for API surface questions.

- `mcp__context7__resolve-library-id` (search for a library)
- `mcp__context7__query-docs` (fetch docs once you have an ID)

When you'd previously have web-searched "how do I do X in Y", reach
for context7 instead. If not installed: ask the user to install it.

### `zig-mcp`

A Zig-aware MCP that wraps `zig build`, ZLS diagnostics, etc. with
clean structured output. Prefer it over raw `zig` invocations through
context-mode when both are available — its build/test reporting is
cleaner. (It disconnected mid-session during v1 development; the
context-mode `ctx_execute` fallback works fine if zig-mcp drops.)

If not installed: ask the user to install zig-mcp.

## Build, run, and test

```sh
zig build                                  # Debug build (default)
zig build -Doptimize=ReleaseFast           # Stripped 6.4 MB release binary
zig build test --summary all               # Unit tests (one skips without MEMLITE_TEST_MODEL)
MEMLITE_TEST_MODEL=~/.memlite/models/.../*.gguf zig build test --summary all
                                           # All 20+ tests including the embed smoke test
```

Run the server:

```sh
memlite serve                              # MCP stdio loop
memlite init                               # Setup-then-exit
memlite dump --db /path/to.db              # NDJSON dump of every table
memlite --help
```

DB path precedence: `--db` flag → `$MEMLITE_DB` env → `~/.memlite/memlite.db`.

## Code map

```
src/main.zig          CLI dispatch (serve/init/dump), session setup
src/mcp.zig           JSON-RPC loop, tool list, dispatch, error envelopes
src/tools.zig         All tool implementations + the SQL they touch
src/db.zig            Connection lifecycle, schema bootstrap, settings I/O
src/schema.sql        @embedFile'd schema (tables + triggers)
src/model.zig         llama_backend init, Model.loadFromFile, n_embd
src/model_url.zig     Strict HF URL parser + cache path derivation
src/download.zig      HTTPS download with atomic temp-file replace
src/embed.zig         Embedder: pooled MEAN embedding, L2-normalized
src/chunk.zig         md4c-based markdown chunker (H1/H2 + soft-cap)
third_party/          Vendored C amalgamations (SQLite, sqlite-vec, md4c)
build.zig             Static lib per vendored C; ReleaseFast strips by default
```

Convention: `tools.zig` owns the SQL surface. `db.zig` stays focused on
open/close/init/settings — don't drift CRUD helpers into it.

## Gotchas worth remembering

- **Zig 0.16 stdlib shape:** `std.fs.cwd()`, `std.fs.File`, and `std.time.timestamp()`
  do NOT exist. Use `std.Io.Dir.cwd()`, `std.Io.File`, and SQL
  `unixepoch()` (or query `last_accessed` back after an UPDATE) instead.
- **`takeDelimiterExclusive` leaves the delimiter in the buffer.** Use
  `takeDelimiter('\n')` for newline-delimited streams; the exclusive
  variant will stall the loop.
- **JSON-RPC error codes split:** transport errors (parse, method
  not found) use integer codes; v1 application errors
  (`SLUG_EXISTS`, `NOT_FOUND`, …) use **string** codes inside the same
  envelope. `writeError` is for the integer side, `writeAppError` for
  the strings. The mcp-server spec is explicit about this.
- **`sqlite3_last_insert_rowid` doesn't reliably reflect trigger inserts.**
  For `memory_delete` we query `SELECT MAX(id) FROM memories_history
  WHERE memory_id = ?` instead.
- **llama.cpp's loader chatter on stderr** is `fprintf(stderr, …)`
  direct, not the callback path that `llama_log_set(null, null)` covers.
  Working around this is what the `quiet-llama-logs` proposal is for —
  if a user complains about noisy stderr, that's the fix.
- **Embedder tests are gated.** The model file is ~99 MB; tests that
  need it set `$MEMLITE_TEST_MODEL` and skip otherwise. Don't unconditionally
  load a real model in tests.
- **Cross-arch builds** rely on the daemonicai/llama.cpp.zig fork. The
  upstream had `ggml/` missing from `.paths` in `build.zig.zon`; that's
  fixed in the fork (`606ed16`). If a tag fetch ever resurfaces this
  bug, check there.

## Commit style

One commit per task group (or per coherent change). Imperative
subject under ~70 chars. Body explains *why* and lists what changed.
End with the Co-Authored-By trailer the user uses. Look at recent
`git log` for the prevailing tone.

## When in doubt

- **Asking the user a question is cheap.** If a spec is ambiguous or
  you're about to make a non-trivial design choice, ask via
  `AskUserQuestion` rather than guessing.
- **Read the openspec proposal before touching anything load-bearing.**
  Especially for retrieval, schema, or the error vocabulary.
- **Don't drift the spec silently.** Update the openspec change
  alongside the code when behavior changes.
