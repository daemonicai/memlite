## MODIFIED Requirements

### Requirement: Server exposes exactly the v1 tool surface

The MCP server SHALL register the following tools at initialization: `memory_add`, `memory_load`, `memory_update`, `memory_get`, `memory_delete`, `memory_clear`, `memory_tag`, `memory_untag`, `memory_search`, `memory_bump`, `memory_list`, `memory_status`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history`.

#### Scenario: Tool list response

- **WHEN** a client calls the MCP `tools/list` method
- **THEN** the response MUST include all 16 tool names above, each with a JSON Schema for its inputs

#### Scenario: Unknown tool name is rejected

- **WHEN** a client invokes `tools/call` with a name not in the v1 set
- **THEN** the server MUST return a JSON-RPC error with code `-32601` (Method not found) and a message naming the unknown tool

### Requirement: Target parameter accepts id (number) or slug (string)

For every tool that operates on an existing memory (`memory_update`, `memory_get`, `memory_delete`, `memory_tag`, `memory_untag`, `memory_bump`, `memory_history`), the system SHALL accept a `target` parameter that is either a JSON number (interpreted as `memories.id`) or a JSON string (interpreted as `memories.slug`).

#### Scenario: Numeric target resolves by id

- **WHEN** `target = 42` is passed
- **THEN** the operation MUST act on the memory with `id = 42`

#### Scenario: String target resolves by slug

- **WHEN** `target = "user-tea-pref"` is passed
- **THEN** the operation MUST act on the memory whose slug equals that string

#### Scenario: Unresolvable target

- **WHEN** the target does not correspond to any live memory
- **THEN** the tool MUST return error code `NOT_FOUND` with a message naming the missing target

## ADDED Requirements

### Requirement: memory_bump tool signature

The `memory_bump` tool SHALL accept exactly one argument:

```
memory_bump(target: int | string)
```

`target` is required and follows the universal addressing convention (id or slug; see "Target parameter accepts id (number) or slug (string)").

The successful response SHALL be a JSON object with exactly the fields:

| Field           | Type      | Meaning                                                  |
|-----------------|-----------|----------------------------------------------------------|
| `id`            | int       | The resolved live `memories.id` whose `last_accessed` was set |
| `last_accessed` | int       | The new `last_accessed` value (unix epoch, post-bump)    |

#### Scenario: Successful bump returns the new timestamp

- **WHEN** `memory_bump(target)` is called and `target` resolves to a live memory whose prior `last_accessed = T0`
- **THEN** the call returns `{ id: <resolved>, last_accessed: T1 }` where `T1 >= T0` and `T1 == current unix epoch at call time`

#### Scenario: Bump leaves all other fields untouched

- **WHEN** `memory_bump(target)` is called
- **THEN** `content`, `format`, `slug`, `tags`, `created`, and `updated` for the targeted memory MUST be unchanged

#### Scenario: Bump on a non-existent or deleted memory

- **WHEN** `memory_bump(target)` is called with a `target` that does not resolve to a live memory
- **THEN** the response MUST be a JSON-RPC error with `code: 'NOT_FOUND'` and a message naming the target

#### Scenario: Bump argument type validation

- **WHEN** `memory_bump` is called with `target` that is neither an integer nor a string
- **THEN** the response MUST be a JSON-RPC error with `code: 'INVALID_TARGET'`
