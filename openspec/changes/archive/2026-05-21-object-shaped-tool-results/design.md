## Context

`emitResultPayload` in `src/mcp.zig` is the union-of-results serializer. Eleven of the fifteen v1 tools open with `s.beginObject()` and emit a record. The remaining four — `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history` — open with `s.beginArray()` and emit a bare top-level array:

```zig
.list_tags => |r| {
    try s.beginArray();
    for (r) |kc| { ... }
    try s.endArray();
},
```

`writeToolResult` writes this payload twice — once into `result.structuredContent` (raw), once into `result.content[0].text` (as a JSON-encoded string). Both inherit the bare-array shape.

The MCP `tools/call` result schema requires `structuredContent` to be a JSON object. The `content[0].text` field is just a string from MCP's perspective, but in practice clients expect it to parse to the same shape as `structuredContent`.

## Goals / Non-Goals

**Goals:**

- All four affected tools return JSON objects.
- The wrapping field name is human-readable and matches the resource concept (`tags`, `values`, `siblings`, `history`).
- A spec requirement that locks in "all tool payloads are JSON objects" so a future bare-array slip can be caught.

**Non-Goals:**

- Adding pagination metadata (`has_more`, `next_cursor`) to the list-style responses. Out of scope; can be added later by adding fields to the new wrapper object.
- Renaming any of the row-level fields (`key`, `memory_count`, `value`, `co_occurrence_count`, etc.). Those are unchanged.
- Restructuring the other 11 tools.

## Decisions

### D1 — Wrapper field names

Single-key wrappers per tool:

| Tool                | New shape                       |
|---------------------|---------------------------------|
| `list_tags`         | `{ "tags": [...] }`             |
| `list_tag_values`   | `{ "values": [...] }`           |
| `list_tag_siblings` | `{ "siblings": [...] }`         |
| `memory_history`    | `{ "history": [...] }`          |

Considered alternative: a uniform `{ "items": [...] }` for all four. Rejected because it loses the type information the natural noun carries, and we're not chasing structural uniformity here — just protocol conformance.

### D2 — Spec the requirement at the right level

Two requirements added to `mcp-server`:

1. A general "tool result payloads are JSON objects" rule, with a scenario asserting the per-tool serializer produces an object for every tool in the v1 surface.
2. A per-tool field-name pin for the four list-style tools, so the wrapper name itself becomes part of the contract.

(1) catches future regressions; (2) prevents the wrapper name from drifting silently in code reviews.

### D3 — Single payload buffer stays single

`writeToolResult` builds the payload once into an `Allocating` writer and emits it twice (raw into `structuredContent`, encoded-as-string into `content[0].text`). That structure is unchanged — the fix is at the per-variant emit level inside `emitResultPayload`, so the dual-emit machinery automatically picks up the new shape.

## Risks / Trade-offs

- **Wire breakage.** Any client coded against the bare-array shape needs to follow `.tags` / `.values` / `.siblings` / `.history`. Practical risk is low: validating MCP hosts couldn't consume the previous shape, and the four tools are administrative/discovery flavored (not in the hot agent loop).

- **`content[0].text` consumers.** Hosts that ignore `structuredContent` and parse the text mirror also see the new shape. Again — they parse the same JSON, so they'd hit the same key.

## Open Questions

- Should `memory_search` and `memory_list` get a unified "list_results" envelope (e.g. add a `count` field) as a follow-up? Defer until a concrete use case appears — premature now.
