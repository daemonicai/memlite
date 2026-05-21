## Context

memlite is a new project. The OpenSpec tree was empty when this change was authored; `reference/sqlite-memory/` is checked into the repo as a design comparison only, **not** as code to port. The existing `sqlmem` MCP server (built on sqlite-memory) is the user's current relationship-memory layer; v1 ships when memlite can fully replace it.

The dominant consumer is an LLM agent (Claude, Pi) speaking MCP over stdio. The single user is one human; the agents are lenses on the same relationship. There is no multi-tenancy, no cloud, no auth — local-first by design.

## Goals / Non-Goals

**Goals:**
- One static binary; macOS + Linux. Zero third-party dynamic dependencies.
- Correct MCP stdio (newline-delimited JSON-RPC). The current `sqlmem` server uses LSP-style Content-Length framing, which is incompatible with the MCP spec.
- Identity model that fits *facts that change*: agent-supplied logical `slug`, not content hash.
- Tag-first metadata model with discovery (`list_tags`, `list_tag_values`, `list_tag_siblings`).
- Soft delete via a history table — accidental deletes are recoverable, and "what did the user used to believe" is itself useful context.
- First-run UX: `memlite serve` works without prior `init` — auto-downloads the embedding model on first launch.

**Non-Goals:**
- File ingest / directory sync / watch mode. memlite is a fact store, not a docs index. Callers slurp files in their own code and pass content as `memory_add(content, …)`.
- Remote embeddings, multi-provider embedding, embedding cache. One model, locally evaluated.
- Multi-tenant / multi-user isolation. One DB per user.
- GPU acceleration. CPU is imperceptible for embedding workloads on Apple Silicon (Accelerate/AMX).
- Migration tooling from `sqlmem` databases. Data models diverge; cleanest path is a fresh DB.
- `memory_restore(history_id)`, bulk `memory_add_batch`, export/import tools. Read-only history (`memory_history`) is v1; mutation of history is v2+.

## Decisions

### D1 — Identity: agent-supplied slug + INTEGER PK, not content hash

The reference uses `hash INTEGER UNIQUE` (xxhash64 of content) as the dedup/identity key. For relationship memory, this is wrong: "user prefers tea" and "the user prefers tea" are the same fact, different hashes. memlite uses:

- `id INTEGER PRIMARY KEY AUTOINCREMENT` — opaque internal identity, never reused (AUTOINCREMENT prevents rowid recycling so history references remain unambiguous).
- `slug TEXT UNIQUE` — nullable, agent-chosen logical id (e.g., `user-beverage-preference`). When present, agents can update by slug without searching first.

Alternative considered: ULID/UUID as PK. Rejected — INTEGER PK is smaller, faster for joins, and the slug already carries the "stable user-facing identifier" role. Hash-as-id rejected because it conflates content equality with fact identity.

### D2 — Tags as an EAV side table, replacing the reference's `context` label

The reference has a single `context TEXT` column. memlite uses:

```sql
CREATE TABLE tags (
  memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  key       TEXT NOT NULL,
  value     TEXT NOT NULL,
  PRIMARY KEY (memory_id, key, value)
) WITHOUT ROWID;
CREATE INDEX tags_kv ON tags(key, value);
```

Alternatives considered:
- **JSON column on `memories`** — simpler reads, but no `SELECT DISTINCT key FROM tags` discovery query, full-table scan for filters, and `{"lang": ["zig","c"]}` vs `{"lang": "zig"}` is an awkward storage decision.
- **Generated columns + indexes on known keys** — rigid; demands choosing the tag vocabulary at schema time. Defeats the "agents discover their own vocabulary" property.

EAV wins on: discovery (`list_tags`, `list_tag_values`, `list_tag_siblings` are one query each), indexed filter performance, and natural multi-value handling (`{"lang": ["zig","c"]}` is two rows, no special case).

Trade-off: AND-across-keys filtering requires one `EXISTS` per predicate. Acceptable — the planner handles correlated `EXISTS` over the `(key, value)` index well.

### D3 — Soft delete via trigger, snapshotting to `memories_history`

`BEFORE DELETE` and `BEFORE UPDATE OF content` triggers move OLD rows to `memories_history`, including a JSON snapshot of the row's tags at the time. Chunks, vec0 rows, and FTS5 rows are **not** snapshotted — they're derived data, regenerable on restore (deferred to v2).

Tag-only mutations (`memory_tag` / `memory_untag`) do **not** create history rows. Only content changes and full deletes are historically meaningful. Otherwise re-tagging would balloon history.

Alternative considered: `deleted_at` flag with `WHERE deleted_at IS NULL` on every query. Rejected — it taxes every live query with a filter and complicates the SQL. The separate history table keeps live queries clean.

### D4 — Unified `format` column, one `memories` table for short text and markdown

Single table, `format TEXT NOT NULL DEFAULT 'text' CHECK(format IN ('text','markdown'))`. Short text → 1 chunk row with the entire content. Markdown → N chunk rows produced by md4c.

The `chunks` table is **always** present and is the unit vec0 / FTS5 are keyed by. Uniform keying means the search layer doesn't branch on format. The format column also leaves space to add `'transcript'`, `'json'`, `'code'` later without schema changes.

Alternative considered: two separate tables (one for short, one for markdown). Rejected — duplicates slug/tag/identity logic and doubles the union queries in search.

### D5 — Hybrid retrieval via reciprocal rank fusion (RRF), k=60

```
score = 1/(60 + vec_rank) + 1/(60 + fts_rank)
```

Alternatives considered:
- **Weighted normalized score** (`α * vec_sim + (1-α) * fts_bm25_norm`). Rejected — requires normalizing BM25 (varies by query) and cosine into the same range; brittle, needs per-query tuning. The reference exposes `vector_weight` as a config knob, which is friction we don't need.
- **Vector-only or FTS-only**. Rejected — hybrid consistently outperforms either alone on relationship-memory recall in published benchmarks; the cost is minor.

RRF returns raw scores in `(0, 0.033]`. Documented; not normalized within response (normalizing within response makes scores incomparable across queries).

### D6 — Search results grouped by memory; max-chunk-score aggregate

A long markdown memory can have multiple matching chunks. The pipeline retrieves at the chunk level with oversampling (default 3× requested limit), groups by `memory_id`, and ranks memories by `max(chunk.score)` within memory. The result surfaces every matching chunk as `matches: [{ord, text, score}, ...]` per memory.

Aggregate = `max` (not `sum` or `mean`) is the standard RAG "dedupe by parent" pattern. `sum` over-rewards long docs; `mean` penalizes a long doc with one perfect match.

### D7 — Build via [diogok/llama.cpp.zig](https://github.com/diogok/llama.cpp.zig), CPU-only on all platforms

The hardest engineering risk is llama.cpp inside a Zig build. The diogok bindings solve this: pure-zig build of llama.cpp (no CMake), targets Zig 0.16, vendors llama.cpp through `build.zig.zon` pinned to a commit. Risk-mitigation: fork the bindings into a memlite-owned namespace so the dep doesn't break on us.

CPU-only is a deliberate revision from an earlier CPU+Metal plan. For *embedding* workloads (not generative LLMs) on Apple Silicon, llama.cpp's CPU path uses Accelerate/AMX and runs at ~15–80ms per chunk. Metal is ~3–4× faster, but the dominant use case is interactive single-fact `memory_add` and `memory_search`, where the difference is imperceptible. Metal would also reintroduce a sidecar `default.metallib` (diogok ships it as a separate file, not embedded), breaking the single-binary property.

### D8 — Model selection via `--model <hf_url>`; one model per DB

Flag accepts a HuggingFace URL of the form `https://huggingface.co/{owner}/{repo}/resolve/{branch}/{filename}[?query]`. Cache layout: `~/.memlite/models/{owner}/{repo}/{filename}`. Strict URL parsing in v1 — HF only, `/resolve/` only.

The `model_url` and `embedding_dim` are stored in a `settings` table on first init. On subsequent runs, memlite refuses to start if the requested model differs, with a clear error pointing at `memlite reindex` (v2) or DB deletion. Per-row model attribution (mixed embedding spaces) is out of scope.

Default model: `nomic-embed-text-v1.5-Q5_K_M.gguf` (~99 MB, 768-dim).

## Risks / Trade-offs

- **diogok/llama.cpp.zig is a single-maintainer, v0.0.1 project** → Fork into a memlite-controlled namespace and pin to a tested commit. Upstream divergence is opt-in, not forced.
- **`memory_clear()` deletes via trigger** — for 10k+ memories this issues 10k history inserts (slow on large stores) → Add `retain_history: false` flag to truncate both tables without firing triggers when the user really wants a clean slate.
- **CPU-only means slow bulk reindex** (~3–4 min on 5000 memories) → Acceptable because reindex is rare (only on model change) and the alternative (Metal) costs the single-binary property. If profiling shows real pain, Metal is a clean future addition.
- **No file ingest in v1** — agents that want to "remember this README" must read the file themselves and call `memory_add(content, tags: {source: …})` → Tradeoff for keeping the surface tight. File ingest can be a thin client-side wrapper, not a memlite tool.
- **Strict slug uniqueness can collide across agents in shared namespace** — `pi` and `claude` both writing `user-beverage-preference` will fight → Mitigated by suggested tag convention `source: claude|pi|user`; agents should namespace their slugs (`claude:user-tea-pref`) if collision becomes a real problem. Slug format is unenforced text; agents converge on conventions.
- **Embedding dim hardcoded at `vec0` creation time** — `CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding FLOAT[768])` literally bakes 768 into the schema → On first init we discover dim from the model and create the virtual table with the discovered value. Model switch with different dim then trips the refusal in D8.
- **RRF requires both indexes to return ranked results, even if one side has no hits** → Each side falls back to "no rank" (effectively rank = ∞, contribution ≈ 0). Edge case for queries that match no chunks in FTS but match in vec (e.g., misspelled queries): vector side still works.

## Migration Plan

memlite v1 replaces the `sqlmem` MCP server entry in the user's MCP configs. Data migration from the existing `sqlmem` DB is **not** in scope — the schemas diverge (different identity model, no `context` column, EAV tags). Users start fresh on v1.

Rollback: keep the old `sqlmem` binary and its DB until memlite has been in active use for some sensible interval. MCP configs can flip back via a single edit if memlite is found wanting.

## Open Questions

- **Slug naming convention** — recommended in MCP tool descriptions, not enforced. Worth checking after a few weeks of real use whether agents converge naturally or whether enforcement is needed.
- **`vector_weight` as a search-time knob** — defaulting to RRF (unparameterized) for v1; revisit only if recall feels off in practice.
- **Markdown chunking thresholds** — md4c gives us a parse tree; the heuristic for splitting (size cap, heading boundaries, paragraph atomicity) is an implementation call that may need iteration once we see real markdown inputs.
