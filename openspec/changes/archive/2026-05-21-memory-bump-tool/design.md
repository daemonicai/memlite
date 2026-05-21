## Context

`last_accessed` is a per-memory unix-epoch timestamp on the `memories` table (`schema` spec). v1's authors picked "every memory returned by `memory_search` gets bumped" as the engagement signal, paired with "all administrative reads (`memory_list`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_status`, `memory_history`) leave it alone."

That made sense before we observed how `memory_search` actually flows in practice: the search response carries the **full memory content** plus the per-chunk match text. Agents have no reason to follow `memory_search` with `memory_get` — everything they need is in the search result. So `memory_search` becomes the de facto access path, and `last_accessed` ends up tracking exposure rather than engagement.

Trying to fix this by "only `memory_get` bumps" fails because the data flow makes `memory_get` rare. The two viable shapes are: (a) accept the noise and document it (v1's choice), or (b) make engagement explicit by giving the agent a tool to record it.

## Goals / Non-Goals

**Goals:**

- `last_accessed` becomes a deliberate "I used this memory" signal — bumped by `memory_get` (deliberate fetch by id/slug) and by a new explicit `memory_bump(target)` (post-hoc "search result was useful").
- `memory_search` becomes side-effect-free. Probe / search-before-add queries no longer pollute the timestamp.
- The `instructions.md` handshake text teaches the agent the new pattern: search → use result → bump.

**Non-Goals:**

- Adding a usage **count** (`use_count`, `search_hit_count`, etc.). Timestamps are enough; counters belong in a separate v2-shaped change if they're needed.
- A second timestamp column (`last_searched_at`). Considered and rejected — schema growth without a concrete consumer.
- Truncating `memory_search` response to snippets. The full-content-in-search shape is useful and orthogonal to this change.
- Bulk-bump (`memory_bump([targets…])`). Defer until single-target bump shows real usage and bulk is justified.

## Decisions

### D1 — Single-target `memory_bump(target)`, not bulk

`memory_bump` takes one `target` (id or slug), matching every other targeted v1 tool. Bulk-bump (`bump_targets: [...]` on `memory_search`, or a separate `memory_bump_many([target,...])`) is a tempting follow-up but deferred. Reasons:

- We don't know yet whether agents will reliably call `memory_bump` at all. If they do, bulk can be retrofitted without breaking single-target callers. If they don't, neither bulk nor single solves the underlying signal problem.
- Single-target keeps the v1 tool surface uniform — every targeted tool takes one `target`.
- Bulk is hot-loop optimization, and bumps are not hot-loop work.

### D2 — Bump only "live" memories

A soft-deleted memory has a snapshot in `memories_history` but no row in `memories` (or, depending on the trigger choice in v1, a row with a sentinel that effectively makes it un-fetchable). `memory_bump` follows `memory_get`'s precedent: if `target` doesn't resolve to a live memory, return `NOT_FOUND`. We do not retroactively bump history rows.

### D3 — Tool name: `memory_bump`

Considered alternatives:

- `memory_touch` — Unix-y; "touch" overloads with file-touch in agent parlance.
- `memory_acknowledge` — verbose; agents may interpret it as social ack rather than engagement.
- `memory_use` — semantic but vague; could be misread as "use this memory in retrieval."
- `memory_mark_used` — explicit but long.
- `memory_access` — matches the column name but reads as a getter.

`memory_bump` is short, has no other plausible meaning in this surface, and the column it touches (`last_accessed`) is the only thing a "bump" could mean here. Instructions text carries the "when to call it" guidance.

### D4 — Response shape

`memory_bump` returns `{ "id": int, "last_accessed": int }`:

- `id` so the caller can confirm which numeric row was bumped (when `target` was a slug, this is the resolved id).
- `last_accessed` so the caller sees the new timestamp without a follow-up `memory_get`.
- No `slug` field — the caller already has it (or has the id and doesn't care).
- No `idempotent: bool` flag — calling `bump` twice in the same second just sets the timestamp to now() twice; same outcome.

### D5 — Side-effect-free `memory_search` is a hard invariant, not a soft default

The replaced requirement in `search` is `SHALL NOT`, not "SHOULD" or "by default." We do not add an opt-in bump parameter to `memory_search` — that would resurrect the noisy-signal problem under a flag, and the explicit `memory_bump` already gives agents a clean way to record engagement.

## Risks / Trade-offs

- **Agent reliability.** The signal quality of `last_accessed` now hinges on agents remembering to call `memory_bump` when they lean on a search result. Mitigations:
  - `instructions.md` includes a "Recording intent" subsection with concrete trigger language.
  - If observed bump rates in real use are low, follow-up change can add `bump_targets: [target,…]` to `memory_search` (single round-trip) without breaking single-target `memory_bump`.

- **Spec drift between code and v1-foundation.** v1-foundation's `search` capability had a specific Requirement that's now replaced. Captured here, not silently changed.

- **Test scope.** Existing tests that assert `memory_search` bumps `last_accessed` need to be inverted. If any test asserts `last_accessed` *changes* after a search, it needs to flip to *does not change*; manual sweep during implementation.

## Open Questions

- Should `memory_bump` accept multiple targets in v1.1 (bulk)? Deferred per D1 — measure first.
- Should there be a complementary `memory_unbump` to roll a `last_accessed` back? No — pruning by date is the use case, and there's no "I didn't actually use this after all" workflow worth building for.
