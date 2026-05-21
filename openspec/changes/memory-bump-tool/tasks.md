## 1. Drop the search-side bump

- [x] 1.1 In `src/tools.zig`'s `memorySearch`, remove the `BEGIN IMMEDIATE` / `COMMIT` wrapping and the `self.bumpLastAccessed(entry.memory_id)` call; read `last_accessed` directly off the live `memories` row instead of post-bump
- [x] 1.2 If `bumpLastAccessed` is left with no other callers, leave it in place (it'll be the implementation of `memory_bump`); otherwise rename to a shared helper — left in place, also called by `memoryGet` and the new `memoryBump`

## 2. Add the memory_bump tool

- [x] 2.1 In `src/tools.zig`, add `pub const BumpResult = struct { id: i64, last_accessed: i64 };` and `pub fn memoryBump(self: *Tools, target: Target) Error!BumpResult` that resolves `target` to a live id (return `NotFound` otherwise), updates `last_accessed = unixepoch()`, and returns the new value
- [x] 2.2 In `src/mcp.zig`, add a tool table entry for `memory_bump` with input schema `{"target": <int|string>}` (required) and a one-line description
- [x] 2.3 Add `memory_bump` arm to `handleToolsCall` dispatch; new `callMemoryBump` helper that reuses `parseTarget`
- [x] 2.4 Add `memory_bump` variant to the `ToolResult` union with field `id: i64` and `last_accessed: i64`; add corresponding branch to `emitResultPayload`

## 3. Update agent guidance

- [x] 3.1 In `src/instructions.md`, add a "Recording intent" subsection: after using a memory in a reply, call `memory_bump(target)`. Note that `memory_search` is now side-effect-free and `memory_get` still bumps automatically.

## 4. Verification

- [x] 4.1 Unit test: `memory_search` against a fresh memory leaves `last_accessed` equal to its pre-search value (gated on `$MEMLITE_TEST_MODEL`)
- [x] 4.2 Unit test: `memory_bump(target)` updates `last_accessed` to roughly `unixepoch()` and returns the new value
- [x] 4.3 Unit test: `memory_bump` on a missing target returns `NotFound`
- [x] 4.4 `zig build test --summary all` passes
- [x] 4.5 Manual: round-trip `initialize` + `memory_search` + `memory_bump` over JSON-RPC; verified `tools/list` count is 16, search returns `last_accessed == created` (no bump), bump-by-slug returns `{id, last_accessed}` with the new timestamp, bump on unknown slug returns `NOT_FOUND`, bump with array target returns `INVALID_TARGET`
