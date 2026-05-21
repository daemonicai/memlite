## ADDED Requirements

### Requirement: memory_add creates a memory, chunks, tags, and embeddings atomically

The `memory_add` operation SHALL execute within a single SQLite transaction. Either all of the following land or none: insert into `memories`; chunking and inserts into `chunks`; FTS5 row creation (via trigger); embedding of every chunk and insert into `vec_chunks`; tag inserts.

#### Scenario: Successful add persists everything

- **WHEN** `memory_add(content: "x", tags: {kind: "preference"})` succeeds
- **THEN** the database contains exactly one new `memories` row, one or more `chunks` rows, matching `vec_chunks` rows, matching `fts_chunks` rows, and the corresponding `tags` rows

#### Scenario: Embedding failure leaves no partial state

- **WHEN** llama.cpp fails to embed any chunk during the add
- **THEN** the transaction MUST roll back: no new rows in `memories`, `chunks`, `vec_chunks`, `fts_chunks`, or `tags`

### Requirement: Text format produces exactly one chunk equal to content

For memories with `format = 'text'`, the system SHALL create exactly one `chunks` row whose `text` equals the memory's full `content`, with `ord = 0`.

#### Scenario: Short text becomes one chunk

- **WHEN** `memory_add(content: "User prefers tea", format: "text")` is called
- **THEN** there is exactly one new `chunks` row with `ord = 0` and `text = "User prefers tea"`

### Requirement: memory_load reads a Markdown file from disk and forwards to memory_add

The `memory_load(path, slug?, tags?)` operation SHALL read a Markdown file from an absolute filesystem path and add it as a memory with `format = 'markdown'`. The operation MUST NOT accept a `format` argument — `memory_load` is markdown-only by design.

The implementation MUST:

- Reject relative or empty paths with `INVALID_PATH` before any disk access.
- Read the file from the supplied absolute path, capped at 1 MiB; oversized files MUST be rejected with `INVALID_PATH` and a clear message.
- Treat a missing file as `NOT_FOUND` (the same code memory_get returns when a memory id/slug doesn't exist).
- After a successful read, perform the same atomic insert sequence as `memory_add(content: <file>, format: 'markdown', slug, tags)`, returning the same result shape `{id, slug, format, chunks_created, tags_created}`.

#### Scenario: Successful load creates a markdown memory

- **WHEN** `memory_load(path: "/Users/me/notes/tea.md", slug: "tea")` is called and the file exists
- **THEN** the response shape matches `memory_add` for that content with `format: "markdown"`; the database contains the corresponding `memories`, `chunks`, `vec_chunks`, and `fts_chunks` rows

#### Scenario: Relative path rejected before disk access

- **WHEN** `memory_load(path: "./tea.md")` is called
- **THEN** the response is a JSON-RPC error with `code: 'INVALID_PATH'` and the file is never opened

#### Scenario: Missing file surfaces as NOT_FOUND

- **WHEN** `memory_load(path: "/Users/me/nonexistent.md")` is called and no such file exists
- **THEN** the response is a JSON-RPC error with `code: 'NOT_FOUND'` and no rows are inserted

#### Scenario: Format argument is rejected

- **WHEN** `memory_load(path: "/abs/path.md", format: "text")` is called
- **THEN** the response is a JSON-RPC error with `code: -32602` (invalid params); memory_load is markdown-only

#### Scenario: Oversized file rejected

- **WHEN** `memory_load(path: "/abs/huge.md")` is called and the file exceeds 1 MiB
- **THEN** the response is a JSON-RPC error with `code: 'INVALID_PATH'` and the file is closed without being added

### Requirement: Markdown format produces N chunks via md4c-based chunker

For memories with `format = 'markdown'`, the system SHALL parse the content with md4c and emit chunks according to a documented chunking policy. The resulting chunks MUST have monotonically increasing `ord` starting at `0` and concatenate (in `ord` order) to a faithful reconstruction of the document semantics.

#### Scenario: Markdown is split into chunks

- **WHEN** `memory_add(content: <markdown with multiple H2 sections>, format: "markdown")` is called
- **THEN** more than one `chunks` row is created for that memory, each with `ord` starting at `0`

#### Scenario: Empty markdown still yields at least one chunk

- **WHEN** `memory_add(content: "", format: "markdown")` is called
- **THEN** exactly one chunk row with `ord = 0` and empty (or near-empty) `text` is created so that downstream search joins remain consistent

### Requirement: Tag input shape is normalized to EAV rows

Tag input on `memory_add` and `memory_update` accepts a JSON object where each value is either a string or an array of strings. The system SHALL normalize this to one `tags` row per `(memory_id, key, value)`, treating strings as length-1 arrays.

#### Scenario: String value becomes one row

- **WHEN** tags `{ "kind": "preference" }` are supplied
- **THEN** one row `(memory_id, 'kind', 'preference')` is inserted into `tags`

#### Scenario: Array value becomes multiple rows

- **WHEN** tags `{ "lang": ["zig", "c"] }` are supplied
- **THEN** two rows are inserted: `(memory_id, 'lang', 'zig')` and `(memory_id, 'lang', 'c')`

### Requirement: memory_update performs partial replacement and may trigger re-chunking

The `memory_update` operation SHALL accept any subset of `content`, `slug`, `format`, `tags`. Omitted fields leave the corresponding columns untouched. Whenever `content` or `format` changes, the system MUST delete the memory's existing `chunks` rows (cascading to vec and FTS), re-chunk the new content according to the new format, embed every new chunk, and insert. Whenever `tags` is supplied, it MUST fully replace the prior tag set; `tags: null` or `tags: {}` clears all tags.

#### Scenario: Content update re-chunks and re-embeds

- **WHEN** `memory_update(target, content: "<new content>")` succeeds
- **THEN** all prior `chunks` for that memory are gone (and their `vec_chunks`/`fts_chunks` rows), and new chunks/vectors/FTS rows exist matching the new content

#### Scenario: Tag-only update does not touch chunks

- **WHEN** `memory_update(target, tags: {…})` is called with no `content` or `format`
- **THEN** existing `chunks`, `vec_chunks`, and `fts_chunks` rows for that memory are NOT modified; only `tags` rows change

#### Scenario: Slug rename does not snapshot history

- **WHEN** `memory_update(target, slug: "new-slug")` is called with no content change
- **THEN** no row is inserted into `memories_history`

#### Scenario: Null slug clears slug

- **WHEN** `memory_update(target, slug: null)` is called
- **THEN** that memory's slug becomes NULL and remains queryable by id

### Requirement: memory_tag and memory_untag mutate a single tag entry

`memory_tag(target, key, value)` SHALL insert one row into `tags` if not already present. `memory_untag(target, key, value?)` SHALL delete the row(s) matching the given key (and value, if supplied), and SHALL return a count of rows removed. These operations MUST NOT create history rows.

#### Scenario: Tagging is idempotent

- **WHEN** `memory_tag(target, 'kind', 'preference')` is called twice in succession
- **THEN** there is exactly one `(target.id, 'kind', 'preference')` row after both calls; the second call's `added` flag is `false`

#### Scenario: Untag without value removes all values for that key

- **WHEN** `memory_untag(target, 'lang')` is called and that memory has tags `lang=zig` and `lang=c`
- **THEN** both rows are removed; `removed_count = 2`

#### Scenario: Untag with value removes only that pair

- **WHEN** `memory_untag(target, 'lang', 'zig')` is called and that memory has tags `lang=zig` and `lang=c`
- **THEN** only the `(target.id, 'lang', 'zig')` row is removed; `removed_count = 1`

### Requirement: memory_delete soft-deletes via trigger

`memory_delete(target)` SHALL execute `DELETE FROM memories WHERE id = ?`. The trigger defined in the schema spec MUST move the row to `memories_history` with `archive_reason = 'deleted'` before the live deletion completes.

#### Scenario: Delete creates a history row

- **WHEN** `memory_delete(target)` is called for a live memory
- **THEN** there is a new `memories_history` row with `memory_id = target.id`, `archive_reason = 'deleted'`, and a `tags_snapshot` matching the live tags at the time of deletion

#### Scenario: Response includes the history_id

- **WHEN** `memory_delete` succeeds
- **THEN** the response includes the integer `history_id` of the newly created history row

### Requirement: memory_clear is recoverable by default

`memory_clear(retain_history?: boolean = true)` SHALL delete every row from `memories`. When `retain_history` is `true` (default) the delete trigger MUST fire for every row so every live memory is preserved in `memories_history`. When `retain_history` is `false`, the system MAY use `DELETE` followed by truncation of `memories_history`, or otherwise bypass triggers, and the response MUST indicate `history_kept: false`.

#### Scenario: Default clear preserves history

- **WHEN** `memory_clear()` is called and the DB contains 100 live memories
- **THEN** after the call, `memories` is empty and `memories_history` contains at least 100 new rows with `archive_reason = 'deleted'`; `history_kept: true` is in the response

#### Scenario: Explicit non-retention wipes history

- **WHEN** `memory_clear(retain_history: false)` is called
- **THEN** both `memories` and `memories_history` are empty; `history_kept: false`

### Requirement: Slug uniqueness applies to live memories only

The `slug UNIQUE` constraint MUST apply only to the live `memories` table. The `memories_history` table MAY contain multiple rows with the same `slug` from historical versions, and slugs may be reused after a memory is deleted.

#### Scenario: Reusing a slug after delete

- **WHEN** a memory with slug `'x'` is deleted, then `memory_add(content: 'y', slug: 'x')` is called
- **THEN** the new memory is created with slug `'x'`; `memories_history` retains the old row with slug `'x'` and `archive_reason = 'deleted'`
