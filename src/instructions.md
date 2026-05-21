memlite is a per-user long-term memory store shared across agents and conversations. Use it for durable facts, preferences, events, and relationship context about THIS user that future-you (or another agent) will benefit from remembering. NOT for documentation, code snippets, or scratch notes that only matter to the current turn.

## When to add a memory

Add a memory when the user shares a stable preference or fact about themselves ("I take my coffee black", "my partner is Sam", "I work on the data team at Acme"), mentions something that will matter later (a deadline, a recurring meeting, an upcoming trip), or you discover something through interaction worth remembering next time.

Before adding, call `memory_search` to avoid duplicates. If a close match exists, prefer `memory_update` over a fresh `memory_add`.

## Identity and tags

- `slug` is a stable human-readable name. Use one for entities you may want to update later (`current-job`, `partner-name`, `morning-routine`); skip it for one-off observations.
- Tags are a JSON key→value(s) map. ALWAYS set `source: <your-agent-name>` so multi-agent attribution survives. Use `kind: preference | fact | event | …` to enable filtering. `memory_tag` / `memory_untag` are surgical edits that don't re-embed the memory.

## Reading

- `memory_search` — hybrid semantic + full-text retrieval, optionally tag-filtered. Use for content recall ("what does the user prefer for X?"). **Side-effect-free**: does NOT bump `last_accessed`. If you actually use a hit in your reply, call `memory_bump(target)` to record it (see below).
- `memory_list` — administrative browse. Filter by tags (`where`) and `since`, order by `created` | `updated` | `last_accessed`, with `limit` and `offset`. Use for "the N most recently updated memories", "everything tagged `kind=event` in the last week", etc. Does NOT bump `last_accessed`.
- `memory_get` — fetch one memory by id or slug. DOES bump `last_accessed` automatically (deliberate fetch is treated as engagement).
- `list_tags`, `list_tag_values`, `list_tag_siblings` — discover the existing tag vocabulary before inventing new keys or values. Prefer reusing established tags.
- `memory_history` — snapshots from prior versions and soft-deletes; the user can recover or audit here.
- `memory_status` — aggregate counts, embedding model + dimension, on-disk DB size. Use for sanity checks.

## Recording intent

`last_accessed` is meant to track *engagement* — memories you actually leaned on, not memories you brushed past while exploring. Two tools update it:

- `memory_get` — auto-bumps. Any deliberate fetch by id or slug counts as engagement.
- `memory_bump(target)` — the explicit signal. Call it after using a `memory_search` result in a reply. Bump only the memories you actually relied on; do not bump every hit. Skipping `memory_bump` is fine if a search result didn't end up shaping your response.
