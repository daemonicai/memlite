## Why

MCP hosts inject the optional `instructions` field from the `initialize` response into the model's system prompt before any user message. memlite's current handshake omits it (`src/mcp.zig:255`), so the agent receives no server-level usage guidance — only the per-tool one-liners in `tools/list`, which describe individual tool semantics but never tell the agent **when** to reach for memlite or **how** to think about its data model.

The practical effect: agents add duplicate memories instead of searching first, miss the `last_accessed` semantics that distinguish `memory_get` from `memory_list`, never use the `list_tag_*` discovery tools, and treat memlite as a scratch pad rather than a durable per-user memory store.

## What Changes

- The `initialize` JSON-RPC result MUST include a top-level `instructions` field — a non-empty UTF-8 string — covering what memlite is for, when to add a memory, the `slug` + tag conventions, and the read/list tool vocabulary.
- The instructions text MUST live in `src/instructions.md` (human-editable markdown) and be embedded into the binary via `@embedFile`, preserving the single-binary distribution model.

## Capabilities

### Modified Capabilities

- `mcp-server` — adds a "Handshake includes agent instructions" requirement. The presence and minimum topic coverage of the field are normative; the exact wording is implementation-defined and may iterate.

### New Capabilities

None.

## Impact

- **Code:** new file `src/instructions.md`; ~3 lines added to `src/mcp.zig` (`@embedFile` constant + one `objectField` pair in `writeInitialize`).
- **No schema changes, no DB migration, no new dependencies.**
- **Tests:** none added in v1; manual verification via an `initialize` request against `memlite serve`.
- **Cost:** ~1.5 KB UTF-8 added to every session's system prompt for hosts that inject `instructions`. The trade-off — avoiding duplicate memories and unused tools — is worth the token cost for a memory server specifically.
- **No back-compat risk:** the field is additive; clients that ignore unknown fields keep working.
