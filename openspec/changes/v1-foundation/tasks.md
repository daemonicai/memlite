## 1. Project skeleton

- [x] 1.1 `zig init` an executable project at the repo root; commit `build.zig`, `build.zig.zon`, `src/main.zig`
- [x] 1.2 Add `.gitignore` for `zig-cache/`, `zig-out/`, `~/.memlite` artifacts
- [x] 1.3 Pin Zig 0.16 in `build.zig.zon` (`minimum_zig_version`)
- [x] 1.4 Create `third_party/` directory and vendor SQLite amalgamation (`sqlite3.c`, `sqlite3.h`), sqlite-vec (`sqlite-vec.c`, `sqlite-vec.h`), and md4c
- [x] 1.5 Add a `b.addStaticLibrary` for each vendored C lib with the required defines (`SQLITE_THREADSAFE=1`, `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_JSON1`)

## 2. SQLite linkage smoke test

- [x] 2.1 Add SQLite as a static lib to the build, link it into the exe
- [x] 2.2 In `main.zig`, open an in-memory DB, run `SELECT sqlite_version()`, print result; verify FTS5 is compiled in
- [x] 2.3 Add sqlite-vec to the build; call `sqlite3_vec_init` from Zig; verify `vec0` virtual table can be created

## 3. MCP transport scaffold

- [x] 3.1 Implement a stdio JSON-RPC read/write loop in `src/mcp.zig` — newline-delimited UTF-8 on stdin/stdout
- [x] 3.2 Implement `tools/list` returning a static array with one placeholder tool (`echo`)
- [x] 3.3 Implement `tools/call` dispatch with `-32601` for unknown tools
- [x] 3.4 Verify against `claude` MCP host (or `npx @modelcontextprotocol/inspector`) that the server lists `echo` and handles a call

## 4. Schema & first-run DB init

- [x] 4.1 Implement schema creation in `src/db.zig`: `memories`, `tags`, `chunks`, `memories_history`, `settings` (per spec)
- [x] 4.2 Add all triggers: snapshot on `BEFORE DELETE` and `BEFORE UPDATE OF content`; FTS5 insert/delete; vec0 delete
- [x] 4.3 On startup, check if DB exists; if fresh, create schema with `vec_chunks` declared `FLOAT[768]` (hardcoded for now; will read from model in §6)
- [x] 4.4 Add settings table writes for `model_url` and `embedding_dim` on first init

## 5. llama.cpp linkage via diogok bindings

- [x] 5.1 Fork `diogok/llama.cpp.zig` into the repo's namespace, pin to a known-good commit
- [x] 5.2 Add the fork as a `build.zig.zon` dependency
- [x] 5.3 Configure the dep with `backend = .cpu` (no Metal in v1)
- [x] 5.4 Verify `zig build` produces a single executable with no `default.metallib`
- [x] 5.5 Confirm via `otool -L` / `ldd` that no llama dynamic library is loaded at runtime

## 6. Model lifecycle

- [x] 6.1 Implement strict HuggingFace URL parser in `src/model_url.zig` — accept `/resolve/` paths only, reject `/blob/` and non-`huggingface.co` hosts
- [x] 6.2 Implement cache path derivation `~/.memlite/models/{owner}/{repo}/{filename}`
- [x] 6.3 Implement HTTPS download via `std.http.Client` with system CA roots, atomic temp-file → rename, line-oriented stderr progress
- [x] 6.4 Implement GGUF model load via the bindings; query and return embedding dimension
- [x] 6.5 First-run path: parse `--model` (or default), check cache, download if missing, load model, write settings
- [x] 6.6 Subsequent-run path: compare `--model` against `settings('model_url')`; on mismatch, exit with `MODEL_MISMATCH` and remedial message
- [x] 6.7 Replace the hardcoded `FLOAT[768]` from §4.3 with dimension read from the loaded model

## 7. Embedding API

- [x] 7.1 Implement `embed(text: []const u8) ![]f32` in `src/embed.zig` — single-text embedding
- [x] 7.2 Surface embedding failures as `EMBEDDING_FAILED` to callers

## 8. Lifecycle tools (no embedding yet)

- [ ] 8.1 Implement `memory_add` for `format='text'` — insert memory, insert single chunk, embed, insert into `vec_chunks`, insert tags; all in one transaction
- [ ] 8.2 Implement `memory_get` — return memory + reconstructed tags JSON; bump `last_accessed`
- [ ] 8.3 Implement `memory_delete` — single DELETE; verify history row created by trigger
- [ ] 8.4 Implement `memory_clear` with `retain_history` parameter
- [ ] 8.5 Implement `memory_update` — partial content/slug/format/tags update; re-chunk on content/format change; full-replace tags
- [ ] 8.6 Implement `memory_tag` / `memory_untag` for surgical tag mutations

## 9. Markdown chunking

- [ ] 9.1 Wire md4c via `src/chunk.zig` — Zig wrapper around md4c streaming parser
- [ ] 9.2 Implement a chunking policy: split at H1/H2 boundaries, soft-cap chunks at ~1500 chars, never split within a code block or list item
- [ ] 9.3 Plumb `format='markdown'` through `memory_add` and `memory_update` — N chunks per memory
- [ ] 9.4 Verify text-format memories still produce exactly one chunk with `ord=0` and `text == content`

## 10. Search

- [ ] 10.1 Implement query embedding in `memory_search`
- [ ] 10.2 Build the tag-filter `EXISTS` SQL generator for the `where` parameter
- [ ] 10.3 Implement chunk-level retrieval with oversampling: top `limit * oversample` from `vec_chunks` and from `fts_chunks`
- [ ] 10.4 Combine via RRF (`k=60`): chunks present in only one list get zero contribution from the other
- [ ] 10.5 Group by `memory_id`, sort `matches[]` by chunk score desc, set memory score to `max(matches[*].score)`
- [ ] 10.6 Trim to `limit` memories, build the response shape per spec
- [ ] 10.7 Bump `last_accessed` for every returned memory, in the same transaction

## 11. List & discovery operations

- [ ] 11.1 Implement `memory_list` with `where`, `since`, `limit`, `offset`, `order_by` (default `updated`)
- [ ] 11.2 Implement `list_tags`, `list_tag_values`, `list_tag_siblings` per spec SQL
- [ ] 11.3 Implement `memory_history` — union live and history table lookups for string targets; history-only for numeric targets
- [ ] 11.4 Implement `memory_status` — aggregate counts + settings + on-disk DB size

## 12. CLI surface

- [ ] 12.1 Implement argument parsing: `memlite serve` (default), `memlite init`, `memlite dump`
- [ ] 12.2 Add `--db <path>` and `--model <url>` flags shared across subcommands
- [ ] 12.3 `memlite init` performs the model download and DB init explicitly, then exits
- [ ] 12.4 `memlite dump` reads the DB read-only and prints rows as JSON to stdout (for debugging)

## 13. End-to-end verification

- [ ] 13.1 Manual test: build the binary, run `memlite init` on a clean `~/.memlite/` — verify model downloads and DB initializes
- [ ] 13.2 Manual test: connect Claude Desktop (or `pi-coding-agent` MCP harness) to the binary; call `memory_add` with a text and tags, then `memory_search` for it
- [ ] 13.3 Manual test: add a markdown doc; verify multiple chunks in `chunks`; search returns the relevant chunk via `matches[]`
- [ ] 13.4 Manual test: delete a memory, run `memory_history(slug)`, verify the deleted entry appears with `archive_reason='deleted'`
- [ ] 13.5 Manual test: start memlite with a different `--model` URL; verify `MODEL_MISMATCH` error and clean exit
- [ ] 13.6 Replace the existing `sqlmem` MCP server entry in the user's MCP config with `memlite serve`; use it for one real day of relationship-memory operations

## 14. Distribution

- [ ] 14.1 Add a `zig build -Doptimize=ReleaseFast` target that strips symbols
- [ ] 14.2 Document install: drop `memlite` into `~/.local/bin/` (or `/usr/local/bin/`); first run downloads model to `~/.memlite/models/`
- [ ] 14.3 Write a brief README at the repo root with install/run/MCP-config steps
