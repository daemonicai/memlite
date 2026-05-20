# memlite

A long-term memory engine for AI agents — a shared, persistent fact store that lets Claude, Pi, and any other MCP-stdio host build a continuous relationship with a single user across conversations and across agents.

memlite is **not** a docs or content index. It's a store for facts, preferences, events, and the small pieces of context that make an assistant feel like it knows you.

## Status

Pre-implementation. The v1 contract — schema, MCP tools, search behavior, embedding lifecycle — is fully specified in [`openspec/changes/v1-foundation/`](openspec/changes/v1-foundation/). Start there:

- [`proposal.md`](openspec/changes/v1-foundation/proposal.md) — what v1 is and why
- [`design.md`](openspec/changes/v1-foundation/design.md) — design decisions and rationale
- [`specs/`](openspec/changes/v1-foundation/specs/) — capability specs (schema, mcp-server, ingest, search, embedding-engine)
- [`tasks.md`](openspec/changes/v1-foundation/tasks.md) — implementation plan

## What it is

- **One static binary.** Zig 0.16, statically linking SQLite, [sqlite-vec](https://github.com/asg017/sqlite-vec), [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [diogok/llama.cpp.zig](https://github.com/diogok/llama.cpp.zig)), and [md4c](https://github.com/mity/md4c). CPU-only. No dynamic third-party dependencies.
- **MCP stdio, done right.** Newline-delimited JSON-RPC, per the MCP spec.
- **Relationship-shaped data model.** Agent-supplied `slug` as logical identity (not a content hash), JSON-key/value tags in an EAV side table, soft-delete with history snapshots, unified `format` column for short text and markdown.
- **Hybrid retrieval.** FTS5 + sqlite-vec, fused with reciprocal rank fusion, with tag pre-filtering and results grouped per memory.
- **Local embeddings.** GGUF models loaded via llama.cpp; pass any HuggingFace `/resolve/` URL with `--model`; first-run download cached under `~/.memlite/models/`.

## CLI surface (planned)

```
memlite serve     # default — MCP server on stdio
memlite init      # explicit setup
memlite dump      # read-only inspector
```

## MCP tools (planned)

`memory_add`, `memory_update`, `memory_get`, `memory_delete`, `memory_clear`, `memory_tag`, `memory_untag`, `memory_search`, `memory_list`, `memory_status`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history`.

## Data location

`~/.memlite/` — SQLite database and downloaded GGUF models. Single-user; multi-agent via a shared namespace with `source: <agent>` attribution tags.

## License

Mozilla Public License 2.0. See [`LICENSE`](LICENSE).
