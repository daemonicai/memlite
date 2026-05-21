# mcp-server Specification

## Purpose
TBD - created by archiving change v1-foundation. Update Purpose after archive.
## Requirements
### Requirement: MCP transport is newline-delimited JSON-RPC over stdio

The system SHALL read MCP JSON-RPC requests from stdin and write responses to stdout, with each message a single UTF-8 line terminated by `\n`. The server MUST NOT use LSP-style Content-Length framing. All log output, progress, and errors MUST go to stderr.

#### Scenario: Request and response are line-delimited

- **WHEN** a client writes a JSON-RPC request as one line followed by `\n` on stdin
- **THEN** the server processes that request and writes a single JSON-RPC response on stdout terminated by `\n`

#### Scenario: stderr never contaminates the protocol channel

- **WHEN** the server logs progress (e.g., model download) or errors during a request
- **THEN** that output MUST be written to stderr, never to stdout

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

### Requirement: Standard error envelope and error codes

The system SHALL return tool errors using the standard JSON-RPC error object with a stable string `code` from the v1 vocabulary: `SLUG_EXISTS`, `NOT_FOUND`, `INVALID_TARGET`, `INVALID_PATH`, `EMBEDDING_FAILED`, `INVALID_FORMAT`, `INVALID_URL`, `MODEL_MISMATCH`. Each error MUST include a human-readable `message`.

#### Scenario: Slug collision

- **WHEN** `memory_add(slug: 'x')` is called and another live memory already uses slug `'x'`
- **THEN** the response MUST be a JSON-RPC error with `code: 'SLUG_EXISTS'` and a message that includes the conflicting slug

#### Scenario: Embedding failure

- **WHEN** llama.cpp fails to embed a chunk during `memory_add`
- **THEN** the entire add is rolled back (no partial chunks or vec rows persist) and the response MUST be a JSON-RPC error with `code: 'EMBEDDING_FAILED'`

### Requirement: Server is single-threaded and request-serial in v1

The system SHALL process MCP requests strictly serially in v1. There SHALL be no worker thread, no connection pool, and no concurrent request handling.

#### Scenario: Second request waits for first

- **WHEN** two requests arrive on stdin in rapid succession
- **THEN** the second response MUST NOT be emitted until the first request has fully completed (including embedding and DB writes)

### Requirement: Tool signatures match v1 contract

The system SHALL expose tool input schemas exactly as follows. Optional fields are omittable; required fields MUST be validated.

```
memory_add(content: string,
           format?: 'text'|'markdown' = 'text',
           slug?: string,
           tags?: object)
       → { id, slug, format, chunks_created, created }

memory_load(path: string,         # absolute path to a Markdown file
            slug?: string,
            tags?: object)
       → { id, slug, format, chunks_created, tags_created }
       # Markdown-only; passing `format` is a -32602 invalid-params error.

memory_update(target,
              content?: string,
              slug?:    string|null,
              format?:  'text'|'markdown',
              tags?:    object|null)
       → { id, slug, format, updated, chunks_created }

memory_get(target)
       → { id, slug, format, content, tags, created, updated,
           last_accessed, chunk_count }

memory_delete(target) → { id, history_id }
memory_clear(retain_history?: boolean = true)
       → { deleted_count, history_kept: boolean }

memory_tag(target, key: string, value: string) → { added: boolean }
memory_untag(target, key: string, value?: string)
       → { removed_count }

memory_search(query: string,
              where?:  object,
              limit?:  number = 10,
              oversample?: number = 3,
              format?: 'text'|'markdown')
       → [{ id, slug, format, tags, score,
            matches: [{ ord, text, score }],
            created, updated, last_accessed }]

memory_list(where?: object,
            since?: number,
            limit?: number = 50,
            offset?: number = 0,
            order_by?: 'created'|'updated'|'last_accessed' = 'updated')
       → [{ id, slug, format, content_preview, tags,
            created, updated, last_accessed }]

memory_status()
       → { total_memories, total_chunks, total_tags,
           history_entries, embedding_model, embedding_dim,
           database_size_bytes, by_format: { text, markdown } }

list_tags() → [{ key, memory_count }]
list_tag_values(key) → [{ value, memory_count }]
list_tag_siblings(key, value) → [{ key, value, co_occurrence_count }]

memory_history(target)
       → [{ history_id, memory_id, slug, format, content,
            tags_snapshot, created, updated, last_accessed,
            archived_at, archive_reason }]
```

#### Scenario: Required field missing

- **WHEN** any tool is invoked without a required parameter (e.g., `memory_add` without `content`)
- **THEN** the server MUST return a JSON-RPC error indicating the missing field, without performing any DB operation

#### Scenario: Tool returns documented shape

- **WHEN** `memory_add(content: "x")` succeeds
- **THEN** the response MUST contain exactly the fields `id`, `slug`, `format`, `chunks_created`, `created` and no others

### Requirement: Handshake includes agent instructions

The `initialize` JSON-RPC result SHALL include a top-level `instructions` field — a non-empty UTF-8 string — alongside `protocolVersion`, `capabilities`, and `serverInfo`.

The text SHALL describe at minimum:

- What memlite is for: a per-user durable memory store for facts, preferences, events, and relationship context — NOT documentation, code, or scratch notes.
- When to add a memory, including the search-before-add pattern.
- The `slug` convention (stable human-readable name for entities you may want to update later) and the tag conventions (`source: <agent-name>` for multi-agent attribution; `kind: …` for filterability).
- The read/list tool surface: `memory_search` (content recall), `memory_list` (administrative browse with limit / offset / order_by / since, suitable for "last N memories" queries), `memory_get` (single by id or slug, bumps `last_accessed`), and the `list_tags` / `list_tag_values` / `list_tag_siblings` family (discover existing tag vocabulary before inventing new keys).

The exact wording is implementation-defined and MAY iterate without a spec change. The text MUST be bundled into the binary at compile time (no runtime file dependency).

#### Scenario: initialize result carries instructions

- **WHEN** a client calls the MCP `initialize` method
- **THEN** the response `result` MUST include a non-empty `instructions` field of JSON type string

#### Scenario: Instructions cover the read/list vocabulary

- **WHEN** the `initialize` response is parsed
- **THEN** the `instructions` text MUST mention `memory_list`, `memory_search`, and at least one of `list_tags` / `list_tag_values` / `list_tag_siblings` by name

#### Scenario: Instructions cover the slug + tag conventions

- **WHEN** the `initialize` response is parsed
- **THEN** the `instructions` text MUST mention `slug` and the `source` tag convention by name

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

