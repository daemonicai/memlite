## Context

The MCP `InitializeResult` schema includes an optional top-level `instructions: string` field — described in the MCP spec as a hint to the LLM about how to use this server. Some hosts (Claude Code, Claude Desktop) inject this verbatim into the assistant's system prompt before any user message; others may not. There is no per-host negotiation: the server either populates the field or it doesn't.

memlite's current handshake at `src/mcp.zig:255-277` writes only `protocolVersion`, `capabilities.tools = {}`, and `serverInfo { name, version }`.

## Goals / Non-Goals

**Goals:**

- A short, action-oriented preamble the agent sees once per session.
- Covers the four things missing from per-tool descriptions:
  1. memlite's data flavor (per-user durable facts about THIS user — not docs, not scratch).
  2. The search-before-add pattern.
  3. `slug` vs no-slug guidance + the `source` / `kind` tag conventions.
  4. The read/list tool vocabulary, including `memory_list` for "last N memories" and the `list_tag_*` family for discovering existing tag vocabulary.
- Editable as prose, not as a Zig string literal.
- Bundled into the single binary (no runtime file dependency).

**Non-Goals:**

- Per-host or per-client customization. v1 ships one string.
- Localization. English only.
- Spec-locking the exact wording. Wording will iterate as we observe agent behavior.

## Decisions

### D1 — `@embedFile` over inline string literal

Two alternatives:

(a) Inline `pub const INSTRUCTIONS = \\…`-style multiline string in `src/mcp.zig`. Trivial; co-locates string with the one call site.

(b) Markdown file in `src/` + `@embedFile`. Prose lives in a real markdown file (easier to edit, render, and review in PRs); still single-binary at runtime.

We picked (b) because the instructions are ~270 words of prose, not code, and we want them legible-as-markdown during edits. Same precedent as `src/schema.sql` (also `@embedFile`'d).

### D2 — Field presence is normative; content is not

The spec change requires the field to be present and non-empty, plus a short list of topics the text must cover (slug/tags, the `list_tag_*` family, etc.). The exact phrasing is implementation-defined. Locking exact wording in the spec would force a spec edit for every prose tweak — wrong granularity.

### D3 — One string, no fine-grained per-tool guidance

Per-tool descriptions in `tools/list` already cover semantics ("memory_get bumps last_accessed", etc.). The handshake `instructions` covers the higher-level layer above that: when to reach for memlite at all, and which tool to pick from the v1 surface. Duplication is acceptable for the most load-bearing patterns (`source:` tag convention, `memory_search` before `memory_add`).

## Risks / Trade-offs

- **Token cost.** ~1.5 KB UTF-8 added to every session's system prompt for hosts that inject `instructions`. The alternative — agents that miss the search-before-add pattern and accumulate duplicates — is worse for a memory server specifically.

- **Wording drift vs. tool descriptions.** If a tool is renamed or retired, `instructions.md` and the per-tool `description` in `mcp.zig` must change in lockstep. Mitigation for v1: manual review at tool-surface change time. A smoke test that all tool names mentioned in `instructions.md` appear in the v1 tool list is a candidate for v2.

## Open Questions

- Should the instructions text be exposed as an MCP resource (`resources/list` / `resources/read`) as well as the handshake field, so it's discoverable by hosts that don't surface `instructions`? Defer until we see a host that doesn't. v1 is handshake-only.
