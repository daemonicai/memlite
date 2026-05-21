## Why

Four MCP tools — `list_tags`, `list_tag_values`, `list_tag_siblings`, and `memory_history` — emit bare JSON arrays as their `tools/call` result payload, both in `structuredContent` and (mirrored) in `content[0].text`. The MCP protocol requires `structuredContent` to be a JSON **object**; hosts that validate the protocol reject the response with errors like `expected: "record", received: "array", path: ["structuredContent"]`. Lax hosts silently mishandle the payload.

This was first observed when calling `list_tags` against a freshly populated DB during a memlite-as-MCP-server smoke test (session of 2026-05-21). The other 11 tools already emit objects and are unaffected.

The v1-foundation `mcp-server` spec pins tool input schemas but is silent on response shapes — so the bug is a conformance gap against the upstream MCP protocol, not a v1 behavior change.

## What Changes

- The `tools/call` result for `list_tags`, `list_tag_values`, `list_tag_siblings`, and `memory_history` MUST be a JSON object with a single named array field — `tags`, `values`, `siblings`, and `history` respectively.
- The `content[0].text` mirror string MUST be the JSON encoding of that same object (already automatic — both share one serialized payload buffer).
- A general "all tool result payloads are JSON objects" requirement is added to the `mcp-server` capability so future tools can't regress.

## Capabilities

### Modified Capabilities

- `mcp-server` — adds two requirements:
  - All tool result payloads (`structuredContent` + the mirrored `content[0].text`) MUST be JSON objects.
  - The four list-style tools name their array field explicitly.

### New Capabilities

None.

## Impact

- **Code:** ~16 lines in `src/mcp.zig` — wrap four `beginArray()` blocks in `beginObject() + objectField(name) + … + endObject()`.
- **Wire format:** breaking change for any client that was indexing into the bare array. Zero practical cost since validating hosts couldn't consume the response before, and lax hosts already needed special-case handling.
- **No schema changes, no DB migration, no new dependencies.**
- **Tests:** none added in v1; manual `tools/call` invocations against `memlite serve` confirm each of the four responses is now an object.
- **Docs:** README MCP-tools table needs no change (it describes purpose, not shape).
