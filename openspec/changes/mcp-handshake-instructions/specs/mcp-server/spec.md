## ADDED Requirements

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
