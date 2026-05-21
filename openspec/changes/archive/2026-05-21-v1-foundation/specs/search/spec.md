## ADDED Requirements

### Requirement: memory_search performs hybrid retrieval over FTS5 and sqlite-vec

The `memory_search` operation SHALL embed the query text using the configured model and retrieve candidate chunks from both `vec_chunks` (by vector similarity) and `fts_chunks` (by FTS5 BM25 ranking). The two ranked lists MUST be combined using reciprocal rank fusion with `k = 60`:

```
score(chunk) = 1/(60 + vec_rank) + 1/(60 + fts_rank)
```

Chunks that appear in only one list receive zero contribution from the missing side.

#### Scenario: Query returns results from both indexes

- **WHEN** `memory_search(query: "what does the user prefer")` is called
- **THEN** the result MAY include chunks that ranked highly only in vec_chunks, only in fts_chunks, or in both — each chunk's score is the sum of its per-index RRF contributions

#### Scenario: No matches

- **WHEN** no chunk is retrievable from either index for the query
- **THEN** the response is the empty array `[]`

### Requirement: Tag filter is applied before scoring via EXISTS predicates

When `where` is supplied to `memory_search` or `memory_list`, the system SHALL restrict the candidate set to memories whose `tags` rows satisfy every key in the filter. For each key K with values V, the predicate is "there exists at least one `tags` row for the memory with `key = K` and `value ∈ V`". Multiple keys MUST be combined with AND.

#### Scenario: Single-key exact match

- **WHEN** `memory_search(query, where: {"kind": "preference"})` is called
- **THEN** only memories with at least one tag row `(id, 'kind', 'preference')` may appear in results

#### Scenario: Array value matches any (OR within key)

- **WHEN** `memory_search(query, where: {"source": ["claude", "pi"]})` is called
- **THEN** memories with `(id, 'source', 'claude')` OR `(id, 'source', 'pi')` may appear

#### Scenario: Multiple keys AND together

- **WHEN** `memory_search(query, where: {"kind": "preference", "source": "claude"})` is called
- **THEN** only memories that have BOTH a `kind=preference` tag AND a `source=claude` tag may appear

#### Scenario: Empty where matches everything

- **WHEN** `where` is omitted or supplied as `{}`
- **THEN** no tag filter is applied

### Requirement: Results are grouped by memory with all matching chunks surfaced

The system SHALL retrieve chunks with an oversampling factor (default `3`, configurable via `oversample`), group hits by `memory_id`, and rank memories by `max(score)` across the memory's matching chunks. The result array MUST contain at most `limit` memories (default `10`); each entry includes `matches: [{ord, text, score}, …]` sorted by chunk `score` descending.

#### Scenario: Multiple chunks of the same markdown memory match

- **WHEN** a markdown memory has three chunks that all rank in the query's top hits
- **THEN** the result contains exactly ONE entry for that memory, with `matches` length 3, sorted by score; the memory-level `score` equals `matches[0].score`

#### Scenario: limit bounds the number of memories, not chunks

- **WHEN** `memory_search(query, limit: 5)` is called and ten different memories each have one matching chunk
- **THEN** the result contains exactly 5 entries, ordered by their (chunk) score descending

#### Scenario: oversample controls candidate pool size

- **WHEN** `memory_search(query, limit: 10, oversample: 5)` is called
- **THEN** the system retrieves up to `10 * 5 = 50` candidate chunks from each index before grouping and trimming to 10 memories

### Requirement: Search results expose raw RRF scores

The system SHALL return raw RRF scores in result entries and `matches[*].score`. Scores MUST NOT be normalized within the response. Scores are documented to live in `(0, 0.033]` with `k = 60`.

#### Scenario: Scores are stable per query

- **WHEN** the same query is run twice against an unchanged DB
- **THEN** the returned scores are identical (deterministic ranking)

### Requirement: memory_search updates last_accessed for returned memories

For every memory present in a successful `memory_search` response, the system SHALL update its `last_accessed` to the current unix epoch, in the same transaction.

#### Scenario: last_accessed is bumped

- **WHEN** `memory_search` returns a memory in its results
- **THEN** that memory's `last_accessed` is now strictly greater than (or equal to, if the same second) its prior value

#### Scenario: Memories filtered out are not touched

- **WHEN** a memory is excluded by the tag filter or trimmed by `limit`
- **THEN** its `last_accessed` is NOT modified

### Requirement: memory_list supports paging, ordering, and a since cutoff

`memory_list(where?, since?, limit?, offset?, order_by?)` SHALL return memories without scoring or embedding. `order_by` MUST be one of `'created'|'updated'|'last_accessed'` (default `'updated'`). When `since` is supplied, the system SHALL filter to memories whose `order_by` column is `>= since`. NULL values of the `order_by` column (possible for `last_accessed`) MUST be excluded when `since` is set.

#### Scenario: Default order is by updated descending

- **WHEN** `memory_list()` is called with no parameters
- **THEN** results are ordered by `updated` descending, limited to 50, offset 0

#### Scenario: since filters on the order_by column

- **WHEN** `memory_list(since: T, order_by: 'updated')` is called
- **THEN** every returned memory has `updated >= T`

#### Scenario: since on last_accessed excludes NULL rows

- **WHEN** `memory_list(since: T, order_by: 'last_accessed')` is called and some memories have never been accessed (`last_accessed IS NULL`)
- **THEN** those memories MUST NOT appear in the result

### Requirement: memory_list does not bump last_accessed

`memory_list` is an administrative read and SHALL NOT modify `last_accessed` for any returned memory. The same applies to `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_status`, and `memory_history`.

#### Scenario: Administrative read leaves timestamps alone

- **WHEN** any of `memory_list`, `list_tags`, `list_tag_values`, `list_tag_siblings`, `memory_status`, `memory_history` returns results
- **THEN** no memory's `last_accessed` is updated

### Requirement: Tag discovery operations

The system SHALL expose three tag discovery operations:

- `list_tags()` returns `[{key, memory_count}]` for every distinct key in the live `tags` table, sorted by `memory_count` descending.
- `list_tag_values(key)` returns `[{value, memory_count}]` for every distinct value of that key in the live `tags` table, sorted by `memory_count` descending.
- `list_tag_siblings(key, value)` returns `[{key, value, co_occurrence_count}]` for every `(key, value)` pair that appears on any memory also tagged `(key, value)`, EXCLUDING the input pair only. Multi-value-per-key memories MAY include other values of the same input key.

#### Scenario: list_tags counts distinct memories per key

- **WHEN** five memories are each tagged `kind=preference` (one of them additionally `kind=fact`) and three memories are tagged `topic=family`
- **THEN** `list_tags()` includes `{key: 'kind', memory_count: 5}` and `{key: 'topic', memory_count: 3}`

#### Scenario: list_tag_siblings excludes the input pair only

- **WHEN** memories tagged `project=memlite` also commonly carry `kind=note` and sometimes `project=other`
- **THEN** `list_tag_siblings('project', 'memlite')` MUST include `{key: 'project', value: 'other'}` (different value of same key — legitimate co-occurrence due to multi-value tags) and `{key: 'kind', value: 'note'}`, and MUST NOT include the input pair `{key: 'project', value: 'memlite'}`

### Requirement: memory_history returns the audit trail for a slug or id

`memory_history(target)` SHALL return all rows from `memories_history` matching the target, ordered by `archived_at` descending. When `target` is a string, the lookup MUST match `memories_history.slug` (so deleted memories' history is reachable by slug). When `target` is a number, the lookup MUST match `memories_history.memory_id`.

#### Scenario: History of a live memory after one update

- **WHEN** a memory is created, then its content is updated once
- **THEN** `memory_history(target)` returns exactly one row with `archive_reason = 'updated'` and the original content

#### Scenario: History of a deleted memory by slug

- **WHEN** a memory with slug `'x'` is created, updated once, then deleted; later `memory_history('x')` is called
- **THEN** the result contains the rows for the update AND the delete, ordered most-recent-first

### Requirement: memory_status reports aggregate counts and configuration

`memory_status()` SHALL return:

```
{ total_memories, total_chunks, total_tags, history_entries,
  embedding_model, embedding_dim, database_size_bytes,
  by_format: { text: N, markdown: M } }
```

`embedding_model` and `embedding_dim` MUST be read from the `settings` table; `database_size_bytes` MUST be the size of the SQLite database file on disk.

#### Scenario: Counts reflect live tables

- **WHEN** the DB contains 10 memories, 23 chunks, 48 tag rows, and 4 history rows
- **THEN** the response has `total_memories: 10`, `total_chunks: 23`, `total_tags: 48`, `history_entries: 4`
