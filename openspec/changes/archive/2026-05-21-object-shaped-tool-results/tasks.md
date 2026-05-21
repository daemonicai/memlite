## 1. Wrap bare arrays in single-keyed objects

- [x] 1.1 In `src/mcp.zig`'s `emitResultPayload`, wrap the `.list_tags` branch in `beginObject() / objectField("tags") / beginArray() … endArray() / endObject()`
- [x] 1.2 Same for `.list_tag_values` under field name `values`
- [x] 1.3 Same for `.list_tag_siblings` under field name `siblings`
- [x] 1.4 Same for `.memory_history` under field name `history`

## 2. Verification

- [x] 2.1 `zig build test --summary all` passes (no regressions)
- [x] 2.2 Manual: run `memlite serve` against an existing DB and call each of the four tools via JSON-RPC; confirm `result.structuredContent` is a JSON object with the spec'd wrapper field and that `result.content[0].text` parses back to the same object
