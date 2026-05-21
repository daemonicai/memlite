## 1. Prose

- [x] 1.1 Write `src/instructions.md` covering: what memlite is for, when to add a memory (search-before-add), slug + tag conventions (`source:` / `kind:`), and the read/list tool vocabulary (`memory_search`, `memory_list`, `memory_get`, `list_tag_*`, `memory_history`, `memory_status`)
- [x] 1.2 Keep total length under ~350 words to bound the session prompt cost

## 2. Plumb into handshake

- [x] 2.1 Add `const INSTRUCTIONS = @embedFile("instructions.md");` near the top of `src/mcp.zig`
- [x] 2.2 In `writeInitialize` (`src/mcp.zig:255`), emit the `instructions` field inside `result` alongside the existing `protocolVersion`, `capabilities`, `serverInfo`

## 3. Verification

- [x] 3.1 `zig build test --summary all` passes (no regressions)
- [x] 3.2 Manual: send an `initialize` request to `memlite serve` over stdin; confirm the response carries a non-empty `instructions` string that mentions `memory_list`, `memory_search`, `list_tags`, `slug`, and the `source` tag convention
