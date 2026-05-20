## ADDED Requirements

### Requirement: Core memories table with opaque integer identity and optional logical slug

The system SHALL persist each memory as a row in a `memories` table with an opaque `INTEGER PRIMARY KEY AUTOINCREMENT` and an optional `TEXT UNIQUE` slug. AUTOINCREMENT MUST be used so that deleted ids are never reused, ensuring history references remain unambiguous.

#### Scenario: Memory created without slug

- **WHEN** content is inserted with no slug supplied
- **THEN** a new row exists with a unique `id`, `slug IS NULL`, and `created`/`updated` set to current unix epoch

#### Scenario: Memory created with slug

- **WHEN** content is inserted with `slug = 'user-tea-pref'` and no other row uses that slug
- **THEN** a new row exists with that slug and a unique `id`

#### Scenario: Duplicate slug rejected

- **WHEN** an insert is attempted with a slug already in use on a live row
- **THEN** the operation MUST fail with a uniqueness constraint violation surfaced as `SLUG_EXISTS`

#### Scenario: Deleted id is not reused

- **WHEN** memory `id = N` is deleted and a subsequent memory is created
- **THEN** the new memory MUST receive an `id > N`, never equal to `N`

### Requirement: Format flag distinguishes content shapes

The `memories` table SHALL include a `format TEXT NOT NULL DEFAULT 'text'` column constrained to one of `'text'` or `'markdown'`. The format determines whether the application chunks content into a single chunk (text) or multiple chunks (markdown).

#### Scenario: Default format

- **WHEN** a memory is inserted without specifying format
- **THEN** the format MUST be `'text'`

#### Scenario: Invalid format rejected

- **WHEN** an insert specifies a format outside the allowed set
- **THEN** the operation MUST fail (CHECK constraint) and the error MUST surface as `INVALID_FORMAT`

### Requirement: Tags stored as EAV side table

The system SHALL store tags in a separate `tags` table with composite primary key `(memory_id, key, value)`, declared `WITHOUT ROWID`, with `ON DELETE CASCADE` from `memories.id`. An index `(key, value)` MUST exist to support both key-only and key+value lookups.

#### Scenario: Tag with array value expands to multiple rows

- **WHEN** a memory is added with `tags = {"lang": ["zig", "c"]}`
- **THEN** the `tags` table MUST contain two rows for that memory: `(memory_id, 'lang', 'zig')` and `(memory_id, 'lang', 'c')`

#### Scenario: Duplicate tag triple is idempotent

- **WHEN** an insert attempts to add `(memory_id, 'kind', 'preference')` and that triple already exists
- **THEN** the operation MUST succeed without creating a duplicate row (composite PK enforces uniqueness)

#### Scenario: Cascade on memory delete

- **WHEN** a memory is deleted
- **THEN** all rows in `tags` with that `memory_id` MUST be removed by the FK cascade

### Requirement: Chunks table is the unit of embedding and full-text indexing

The system SHALL store one or more `chunks` rows per memory, with `memory_id` FK to `memories.id`, an `ord INTEGER` for in-memory order, and the chunk `text`. `chunks.id` is the rowid that `vec_chunks` and `fts_chunks` are keyed by. `(memory_id, ord)` MUST be unique.

#### Scenario: Text-format memory has one chunk

- **WHEN** a memory with `format = 'text'` is added
- **THEN** exactly one `chunks` row exists for it with `ord = 0` and `text` equal to the memory's content

#### Scenario: Markdown-format memory has N chunks

- **WHEN** a memory with `format = 'markdown'` is added and the markdown parser emits N chunks
- **THEN** N `chunks` rows exist for it, each with a distinct `ord` from `0` to `N-1`

#### Scenario: Cascade on memory delete

- **WHEN** a memory is deleted
- **THEN** all `chunks` for that memory MUST be removed by the FK cascade, which in turn fires triggers that remove rows from `vec_chunks` and `fts_chunks`

### Requirement: Vector index via sqlite-vec virtual table

The system SHALL create a `vec_chunks` virtual table using sqlite-vec's `vec0` module, declared with an `embedding FLOAT[N]` column where N is the embedding dimension discovered from the configured model at first DB initialization. The `vec_chunks.rowid` MUST equal `chunks.id` for joined retrieval.

#### Scenario: Virtual table created at first init

- **WHEN** memlite initializes a new database
- **THEN** `vec_chunks` is created with `FLOAT[N]` where N matches the discovered embedding dimension, and N is also stored in `settings('embedding_dim', …)`

#### Scenario: Vector row is removed when its chunk is deleted

- **WHEN** a `chunks` row is deleted
- **THEN** the corresponding `vec_chunks` row (matched by rowid) MUST also be deleted, via an `AFTER DELETE ON chunks` trigger

### Requirement: Full-text index via FTS5 external content virtual table

The system SHALL create an `fts_chunks` FTS5 virtual table with `content='chunks'` and `content_rowid='id'`. The text column MUST be auto-populated by trigger on `chunks` insert and cleaned up on `chunks` delete.

#### Scenario: FTS row created on chunk insert

- **WHEN** a new `chunks` row is inserted
- **THEN** an `AFTER INSERT ON chunks` trigger MUST insert a matching row into `fts_chunks` with the same rowid and text

#### Scenario: FTS row removed on chunk delete

- **WHEN** a `chunks` row is deleted
- **THEN** an `AFTER DELETE ON chunks` trigger MUST delete the matching `fts_chunks` row

### Requirement: History table preserves deleted and updated memories

The system SHALL maintain a `memories_history` table that records the prior state of any memory before deletion or content update. The table MUST snapshot: `memory_id`, `slug`, `format`, `content`, a JSON snapshot of the memory's tags at the time, `created`, `updated`, `last_accessed`, `archived_at` (set to current unix epoch on snapshot), and `archive_reason` constrained to `'deleted'` or `'updated'`.

#### Scenario: Delete snapshots the row

- **WHEN** a memory is deleted
- **THEN** a `BEFORE DELETE ON memories` trigger MUST insert a row into `memories_history` with `archive_reason = 'deleted'` and `tags_snapshot` containing a JSON object of the form `{key: [values…]}` reconstructed from the live `tags` table for that memory

#### Scenario: Content update snapshots the prior content

- **WHEN** a memory's `content` is updated via `UPDATE memories SET content = ? WHERE id = ?`
- **THEN** a `BEFORE UPDATE OF content ON memories` trigger MUST insert a row into `memories_history` with `archive_reason = 'updated'` capturing the OLD content and tag state

#### Scenario: Tag-only mutation does not create history

- **WHEN** tags are added or removed via the `tags` table only, with no change to `memories.content`
- **THEN** no row is inserted into `memories_history`

#### Scenario: History does not snapshot chunks or embeddings

- **WHEN** a memory is deleted or updated
- **THEN** `memories_history` MUST NOT include chunk-level text, embeddings, or FTS rows; only the memory-level metadata, content, and tag snapshot are retained

### Requirement: Settings table records configuration that pins the schema

The system SHALL maintain a `settings(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID` table that records, at minimum, `model_url` and `embedding_dim` on first initialization. The values MUST be set during `memlite init` or during the implicit init phase of `memlite serve` on a fresh database.

#### Scenario: First-run writes settings

- **WHEN** memlite is started against a fresh DB with `--model URL` (or the default)
- **THEN** after initialization, `settings('model_url') = URL` and `settings('embedding_dim') = <N>` where N is the dimension reported by the loaded GGUF model
