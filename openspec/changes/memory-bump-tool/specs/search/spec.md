## MODIFIED Requirements

### Requirement: memory_search does not modify last_accessed

The system SHALL NOT modify `last_accessed` for any memory as a side effect of a `memory_search` call. Search responses still emit the current `last_accessed` value for each returned memory; the value just does not change because of the call.

Agents that want to record deliberate engagement with a search result SHALL call `memory_bump(target)` after using that memory in a reply. See `memory_bump` in the `mcp-server` capability.

This replaces the prior v1-foundation requirement that bumped `last_accessed` for every memory returned by `memory_search`.

#### Scenario: Search leaves last_accessed alone

- **WHEN** `memory_search(query)` returns a memory whose prior `last_accessed = T0`
- **THEN** that memory's `last_accessed` is exactly `T0` after the call (no in-transaction bump)

#### Scenario: Search response carries the unchanged timestamp

- **WHEN** `memory_search(query)` returns a memory in its results
- **THEN** the `last_accessed` field in the response MUST be the same value `memory_get(target)` would return when called immediately before the search

#### Scenario: Explicit engagement via memory_bump

- **WHEN** the agent calls `memory_bump(target)` after a search result is used in a reply
- **THEN** that memory's `last_accessed` is updated to the current unix epoch; no other memories are touched
