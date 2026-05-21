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

The MCP server SHALL register the following tools at initialization: `memory_add`, `memory_load`, `memory_update`, `memory_get`, `memory_delete`, `memory_clear`, `memory_tag`, `memory_untag`, `memory_search`, `memory_list`, `memory_status`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_history`.

#### Scenario: Tool list response

- **WHEN** a client calls the MCP `tools/list` method
- **THEN** the response MUST include all 15 tool names above, each with a JSON Schema for its inputs

#### Scenario: Unknown tool name is rejected

- **WHEN** a client invokes `tools/call` with a name not in the v1 set
- **THEN** the server MUST return a JSON-RPC error with code `-32601` (Method not found) and a message naming the unknown tool

### Requirement: Target parameter accepts id (number) or slug (string)

For every tool that operates on an existing memory (`memory_update`, `memory_get`, `memory_delete`, `memory_tag`, `memory_untag`, `memory_history`), the system SHALL accept a `target` parameter that is either a JSON number (interpreted as `memories.id`) or a JSON string (interpreted as `memories.slug`).

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

