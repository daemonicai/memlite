## Why

Existing options for agent long-term memory are either too narrow (Claude Code's per-project markdown files don't span agents) or wrong-shaped for relationship memory (sqlite-memory's `sqlmem` is a content/docs index — hash-as-identity, content-hash dedup, file-path sync). For a personal-assistant build that needs a single durable memory layer shared by Claude, Pi, and other agents, neither fits. memlite is a from-scratch SQLite-backed memory engine designed around the relationship-memory model, distributed as one static binary, speaking MCP cleanly.

## What Changes

- New project: Zig 0.16 binary `memlite`, statically linking SQLite, sqlite-vec, llama.cpp (via [diogok/llama.cpp.zig](https://github.com/diogok/llama.cpp.zig)), and md4c.
- New transport: MCP stdio with newline-delimited JSON-RPC. Replaces the current `sqlmem` MCP server, which uses LSP-style Content-Length framing and is incompatible with the MCP spec.
- New data model: agent-supplied `slug` as logical identity (not content hash); JSON-key/value tags in an EAV side table replacing the reference's single `context` label; soft-delete via trigger-driven `memories_history` table; unified `format` column for short text and markdown documents.
- New tool surface: 14 MCP tools — `memory_add`, `memory_update`, `memory_get`, `memory_delete`, `memory_clear`, `memory_tag`, `memory_untag`, `memory_search`, `memory_list`, `memory_status`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history`.
- New search behavior: hybrid FTS5 + sqlite-vec retrieval combined via reciprocal rank fusion (k=60), tag-pre-filter through `EXISTS` predicates, results grouped by memory with all matching chunks surfaced.
- New embedding lifecycle: `--model <hf_url>` flag accepts any HuggingFace `/resolve/` URL; cache layout `~/.memlite/models/{owner}/{repo}/{filename}`; first-run auto-download with progress on stderr; CPU-only inference (no Metal in v1 — Accelerate/AMX is already imperceptible for embedding workloads).
- New CLI: `memlite serve` (default — MCP server), `memlite init` (explicit setup), `memlite dump` (read-only inspector).

## Capabilities

### New Capabilities

- `schema`: SQLite data model — memories, tags (EAV side table), chunks, history, settings — including triggers for soft-delete snapshotting and FTS5/vec0 cascade cleanup.
- `mcp-server`: MCP stdio JSON-RPC transport, tool registration, dispatch, and error envelope for the 14 v1 tools.
- `ingest`: Add/update/delete/tag mutations, slug lifecycle, format-driven chunking (text=1 chunk, markdown=N chunks via md4c), interaction with history snapshots.
- `search`: Hybrid retrieval (FTS5 + sqlite-vec, RRF), tag-filter pre-pass, group-by-memory result shaping, plus the list/history/discovery read operations.
- `embedding-engine`: llama.cpp wrapper via the diogok bindings, GGUF model loading, model-URL parsing/cache layout, first-run download UX, and the model-switch refusal contract.

### Modified Capabilities

None — `openspec/specs/` is empty; this is the foundation change.

## Impact

- New repository contents: `src/`, `build.zig`, `build.zig.zon`, `third_party/{sqlite,sqlite-vec,md4c}/` (vendored amalgamations), Zig package dependency on the diogok llama.cpp bindings.
- New runtime data: `~/.memlite/` directory tree (DB and models). Migration from existing `sqlmem` data is **not** in scope for v1 — the data models diverge enough that a clean cutover is cleaner than a migration tool.
- Distribution: one binary, no third-party dynamic dependencies, depends only on macOS / Linux system libraries.
- External services: HuggingFace HTTPS for model download on first run only. No telemetry, no remote embeddings.
- MCP clients: Claude Desktop, Pi (`pi-coding-agent` harness), and any other MCP-stdio host. The current `sqlmem` MCP entry in MCP configs is replaced wholesale.
