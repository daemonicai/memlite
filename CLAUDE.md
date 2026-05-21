# memlite — guide for future Claude sessions

memlite is a long-term memory engine for AI agents: a single static
Zig 0.16 binary that speaks MCP stdio, statically links SQLite +
[sqlite-vec](https://github.com/asg017/sqlite-vec) + a CPU-only
[llama.cpp](https://github.com/ggerganov/llama.cpp) + [md4c](https://github.com/mity/md4c),
runs a hybrid (vec0 + FTS5, RRF-fused) retrieval pipeline over a
soft-delete-with-history schema, and embeds locally via a HuggingFace
GGUF model resolved on first run.

## The spec is canonical, not the code

The v1 contract lives in `openspec/specs/`:

- `schema/spec.md` — tables, triggers, history semantics
- `mcp-server/spec.md` — transport, the 16-tool surface, handshake `instructions`, error vocabulary
- `ingest/spec.md` — markdown chunking and tag normalisation
- `search/spec.md` — hybrid vec0 + FTS5 retrieval, RRF fusion, tag filtering
- `embedding-engine/spec.md` — GGUF model lifecycle, download cadence, quiet-by-default loader

Anything about tool signatures, error codes, schema columns, or
retrieval semantics — answer from those specs, NOT from memory. If
you find a divergence between code and spec, the spec wins (or the
spec is wrong and we update it; never silently drift).

The original proposals + design notes + task checklists are preserved
under `openspec/changes/archive/` — read the dated directories there
when you need the *why* behind a requirement. v1 was assembled from
`v1-foundation` plus five follow-ups: `quiet-llama-logs`,
`download-progress`, `mcp-handshake-instructions`,
`object-shaped-tool-results`, and `memory-bump-tool`.

When adding NEW behavior, propose a new openspec change first
(proposal + design + spec delta + tasks) and apply it via the
`openspec` CLI rather than editing `openspec/specs/` directly. The
archive process applies the delta to the consolidated specs; bypassing
it loses the development history this project deliberately preserves.

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
zig build test --summary all               # Unit tests (~2 skip without MEMLITE_TEST_MODEL)
MEMLITE_TEST_MODEL=~/.memlite/models/.../*.gguf zig build test --summary all
                                           # All 25 tests, including the embed smoke test
                                           # and the memory_search no-bump test
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
src/main.zig          CLI dispatch (serve/init/dump), session setup, --verbose-llama flag
src/mcp.zig           JSON-RPC loop, tool list, dispatch, error envelopes, handshake instructions
src/instructions.md   @embedFile'd agent-facing handshake guidance (memlite usage)
src/tools.zig         All tool implementations + the SQL they touch
src/db.zig            Connection lifecycle, schema bootstrap, settings I/O
src/schema.sql        @embedFile'd schema (tables + triggers)
src/model.zig         llama_backend init, Model.loadFromFile (with .quiet opt), n_embd
src/model_url.zig     Strict HF URL parser + cache path derivation
src/download.zig      HTTPS download with atomic temp-file replace + 5%/5MiB progress
src/embed.zig         Embedder: pooled MEAN embedding, L2-normalized
src/chunk.zig         md4c-based markdown chunker (H1/H2 + soft-cap)
install.sh            Build-and-install helper (zig build + install to ~/.local/bin)
third_party/          Vendored C amalgamations (SQLite, sqlite-vec, md4c)
build.zig             Static lib per vendored C; ReleaseFast strips by default
.github/workflows/release.yml
                      Build matrix (3 targets) → all-pass gate → release publication;
                      workflow_dispatch for manual builds without a release
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
- **llama.cpp's loader chatter is silenced by default.** Model load
  runs with `STDERR_FILENO` redirected to `/dev/null` via the `.quiet`
  opt on `Model.loadFromFile`; `--verbose-llama` (or
  `MEMLITE_VERBOSE_LLAMA=1`) restores it for debugging. The callback
  path is independently silenced by `llama_log_set(null, null)` in
  `initBackend`. Both layers matter — direct `fprintf(stderr, …)` from
  the loader bypasses the callback hook.
- **Tool result payloads are always JSON objects.** The MCP
  `tools/call` result schema requires `structuredContent` to be an
  object — bare arrays violate the protocol. When adding a list-style
  tool, wrap the array in a single-keyed object (e.g.
  `{"tags": [...]}`, `{"history": [...]}`). The four list-style tools
  already do this with field names pinned in the `mcp-server` spec.
- **`last_accessed` is the explicit-engagement signal.** `memory_get`
  auto-bumps (deliberate single-memory fetch == engagement).
  `memory_search` is **side-effect-free** — agents record engagement
  with a result by calling `memory_bump(target)`. Administrative reads
  (`memory_list`, `memory_history`, `list_tag_*`, `memory_status`)
  never touch it. The handshake `instructions.md` coaches the agent on
  when to call `memory_bump`.
- **Embedder tests are gated.** The model file is ~99 MB; tests that
  need it set `$MEMLITE_TEST_MODEL` and skip otherwise. Two tests are
  gated today: the `embed.zig` smoke test and the `tools.zig`
  "memory_search leaves last_accessed unchanged" integration test.
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
- **Read the canonical specs before touching anything load-bearing.**
  `openspec/specs/<capability>/spec.md` is the current state. For the
  *why* behind a requirement, dig into the dated proposal under
  `openspec/changes/archive/`.
- **Don't drift the spec silently.** Behavior changes go through a new
  openspec change first — proposal + design + spec delta + tasks,
  applied via `openspec archive`. The archive operation is what
  updates `openspec/specs/`; never edit those files by hand.
