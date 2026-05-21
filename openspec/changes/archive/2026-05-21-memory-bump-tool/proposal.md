## Why

v1 wires `memory_search` to update `last_accessed` for every memory it returns, in the same transaction as the search (`openspec/changes/v1-foundation/specs/search/spec.md:75-87`). The intent was a coarse "this memory still gets touched" signal for cleanup.

In practice that signal is noisy. `memory_search` returns the full `content` of every hit (plus per-chunk match text), so the agent already has everything it needs from a single search call — `memory_get` is almost never the natural follow-up. The result: every drive-by `search`-before-`add` query refreshes `last_accessed` on the matches, conflating "agent leaned on this memory in a reply" with "agent brushed past this memory while checking for duplicates."

That collapses the cleanest use cases for `last_accessed`:

- Pruning candidates ("never engaged with") loses precision — the signal is "ever returned by any search," which is too permissive.
- Recency-aware ranking / tiebreaking ("what's been top of mind") is hopeless, because the order shuffles on every search.

## What Changes

- `memory_search` MUST NOT modify `last_accessed` for any memory it returns. The Requirement in `search` is replaced.
- A new MCP tool `memory_bump(target)` is added. It updates `last_accessed` to the current unix epoch for the single live memory identified by `target` (id or slug). The v1 tool surface grows from 15 to 16.
- `memory_get` retains its existing bump behavior — fetching a single memory by id or slug is still a deliberate "I want this one" signal.
- `instructions.md` (the agent-facing handshake guidance) is updated with a "Recording intent" subsection that tells agents to call `memory_bump(target)` after they actually use a search result in a reply, and clarifies that `memory_search` is now side-effect-free.

## Capabilities

### Modified Capabilities

- `mcp-server` — adds `memory_bump` to the canonical tool list (grows from 15 to 16), pins its input schema, and pins its response shape.
- `search` — replaces the existing "memory_search updates last_accessed" requirement with the new "memory_search does NOT modify last_accessed" requirement, plus a cross-reference to `memory_bump`.

### New Capabilities

None.

## Impact

- **Code:**
  - `src/tools.zig`: remove the `bumpLastAccessed` call inside `memorySearch` (and the `BEGIN IMMEDIATE … COMMIT` wrapping that exists solely for it); add `pub fn memoryBump(target) Error!BumpResult`.
  - `src/mcp.zig`: new tool table entry for `memory_bump`, new dispatch arm in `handleToolsCall`, new union variant + `emitResultPayload` branch.
  - `src/instructions.md`: new "Recording intent" subsection.
- **Schema:** no migrations. `last_accessed` already exists.
- **Wire format:** `memory_search` response shape is unchanged (still emits `last_accessed` per memory; the value just stops moving on search calls). One new tool added to `tools/list`.
- **Tests:** unit tests for `memory_search` leaves `last_accessed` alone; new unit test for `memory_bump` updates it; `memory_bump` returns `NOT_FOUND` on missing target.
- **Back-compat:** clients that depended on search bumping `last_accessed` need to call `memory_bump` instead. v1 hasn't shipped a tagged release yet, so external impact is bounded.
- **Operational note:** the signal quality of `last_accessed` now depends on agents reliably calling `memory_bump`. If real-world bump rates turn out to be low, a follow-up change can add a `bump_targets: [target,…]` parameter to `memory_search` so the agent can declare "I'm about to lean on these N of them" in a single call. That's deliberately out of scope here — measure first.
