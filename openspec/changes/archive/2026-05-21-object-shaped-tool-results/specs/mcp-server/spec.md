## ADDED Requirements

### Requirement: Tool result payloads are JSON objects

For every tool registered on the v1 MCP surface, a successful `tools/call` response SHALL place a JSON **object** (not an array, string, number, or scalar) in `result.structuredContent`. The mirrored `result.content[0].text` string SHALL be the JSON encoding of that same object.

#### Scenario: structuredContent is an object for every v1 tool

- **WHEN** any tool in the v1 surface is called successfully (`memory_add`, `memory_load`, `memory_update`, `memory_get`, `memory_delete`, `memory_clear`, `memory_tag`, `memory_untag`, `memory_search`, `memory_list`, `memory_status`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history`)
- **THEN** `result.structuredContent` is a JSON object (i.e. `{...}`), never a bare array, string, number, or boolean

#### Scenario: content text mirrors structuredContent

- **WHEN** any tool in the v1 surface is called successfully
- **THEN** `result.content[0].type == "text"` and `result.content[0].text` parses back to the same object as `result.structuredContent`

### Requirement: List-style tool payloads name their array field

The four list-style tools SHALL wrap their result array in a single-keyed object using the field names below:

| Tool                | Object shape                                                          |
|---------------------|-----------------------------------------------------------------------|
| `list_tags`         | `{ "tags": [{ "key": string, "memory_count": int }, ...] }`           |
| `list_tag_values`   | `{ "values": [{ "value": string, "memory_count": int }, ...] }`       |
| `list_tag_siblings` | `{ "siblings": [{ "key": string, "value": string, "co_occurrence_count": int }, ...] }` |
| `memory_history`    | `{ "history": [{ "history_id": int, "memory_id": int, "slug": string\|null, "format": string, "content": string, "tags_snapshot": object, "created": int, "updated": int, "last_accessed": int\|null, "archived_at": int, "archive_reason": string }, ...] }` |

The wrapper field name is part of the v1 contract — clients MAY rely on it.

#### Scenario: list_tags wraps its array under `tags`

- **WHEN** `list_tags` is called
- **THEN** `result.structuredContent` is an object with exactly one key `tags`, whose value is an array of `{key, memory_count}` rows

#### Scenario: list_tag_values wraps its array under `values`

- **WHEN** `list_tag_values(key)` is called
- **THEN** `result.structuredContent` is an object with exactly one key `values`, whose value is an array of `{value, memory_count}` rows

#### Scenario: list_tag_siblings wraps its array under `siblings`

- **WHEN** `list_tag_siblings(key, value)` is called
- **THEN** `result.structuredContent` is an object with exactly one key `siblings`, whose value is an array of `{key, value, co_occurrence_count}` rows

#### Scenario: memory_history wraps its array under `history`

- **WHEN** `memory_history(target)` is called
- **THEN** `result.structuredContent` is an object with exactly one key `history`, whose value is an array of history-row objects most-recent-first
