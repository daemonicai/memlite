## ADDED Requirements

### Requirement: memory_search does not modify last_accessed

The system SHALL NOT modify `last_accessed` for any memory as a side effect of a `memory_search` call. Search responses still emit the current `last_accessed` value for each returned memory; the value just does not change because of the call.

Agents that want to record deliberate engagement with a search result SHALL call `memory_bump(target)` after using that memory in a reply. See `memory_bump` in the `mcp-server` capability.

#### Scenario: Search leaves last_accessed alone

- **WHEN** `memory_search(query)` returns a memory whose prior `last_accessed = T0`
- **THEN** that memory's `last_accessed` is exactly `T0` after the call (no in-transaction bump)

#### Scenario: Search response carries the unchanged timestamp

- **WHEN** `memory_search(query)` returns a memory in its results
- **THEN** the `last_accessed` field in the response MUST be the same value `memory_get(target)` would return when called immediately before the search

#### Scenario: Explicit engagement via memory_bump

- **WHEN** the agent calls `memory_bump(target)` after a search result is used in a reply
- **THEN** that memory's `last_accessed` is updated to the current unix epoch; no other memories are touched

## REMOVED Requirements

### Requirement: memory_search updates last_accessed for returned memories

**Reason**: Because `memory_search` returns the full `content` and per-chunk match text for every hit, agents rarely need `memory_get` as a follow-up — search became the de facto access path and `last_accessed` collapsed into "anything any search has ever brushed past". This destroyed the signal's value for pruning ("never engaged with") and recency-aware ranking ("what's been top of mind"). Engagement is now recorded explicitly by the agent via `memory_bump(target)`.

**Migration**: Callers that depended on the search-side bump to keep `last_accessed` current SHOULD call `memory_bump(target)` for each memory they actually rely on after a search. `memory_get` continues to auto-bump for deliberate single-memory fetches by id or slug.
