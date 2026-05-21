# memlite

[![Latest release](https://img.shields.io/github/v/release/daemonicai/memlite?label=latest&color=brightgreen)](https://github.com/daemonicai/memlite/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/daemonicai/memlite/release.yml?label=build)](https://github.com/daemonicai/memlite/actions/workflows/release.yml)
[![License](https://img.shields.io/github/license/daemonicai/memlite)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-F7A41D?logo=zig&logoColor=white)](https://ziglang.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20arm64%20%7C%20Linux%20x86__64%20%7C%20Linux%20arm64-lightgrey)](https://github.com/daemonicai/memlite/releases/latest)

A long-term memory engine for AI agents — a shared, persistent fact store that lets Claude, Pi, and any other MCP-stdio host build a continuous relationship with a single user across conversations and across agents.

memlite is **not** a docs or content index. It's a store for facts, preferences, events, and the small pieces of context that make an assistant feel like it knows you.

## What it is

- **One static binary.** Zig 0.16, statically linking SQLite, [sqlite-vec](https://github.com/asg017/sqlite-vec), [llama.cpp](https://github.com/ggerganov/llama.cpp), and [md4c](https://github.com/mity/md4c). CPU-only. No dynamic third-party dependencies — `otool -L` shows only `libSystem.B.dylib` on macOS.
- **MCP stdio, done right.** Newline-delimited JSON-RPC, per the MCP spec.
- **Relationship-shaped data model.** Agent-supplied `slug` as logical identity, JSON-key/value tags in an EAV side table, soft-delete with history snapshots, unified `format` column for short text and markdown.
- **Hybrid retrieval.** FTS5 + sqlite-vec, fused with reciprocal rank fusion (k=60), with tag pre-filtering and results grouped per memory.
- **Local embeddings.** GGUF models loaded via llama.cpp; pass any HuggingFace `/resolve/` URL with `--model`; first-run download cached under `~/.memlite/models/`.

## Status

v1-foundation is implemented end-to-end. The full v1 contract — schema, MCP tools, search behavior, embedding lifecycle — lives in [`openspec/changes/v1-foundation/`](openspec/changes/v1-foundation/):

- [`proposal.md`](openspec/changes/v1-foundation/proposal.md) — what v1 is and why
- [`design.md`](openspec/changes/v1-foundation/design.md) — decisions and rationale
- [`specs/`](openspec/changes/v1-foundation/specs/) — five capability specs (schema, mcp-server, ingest, search, embedding-engine)
- [`tasks.md`](openspec/changes/v1-foundation/tasks.md) — task checklist

## Install

### Pre-built binaries (recommended)

Statically linked tarballs for macOS arm64, Linux x86_64, and Linux arm64 are attached to every tagged [release](https://github.com/daemonicai/memlite/releases/latest). Pick the archive that matches your machine, extract, and drop the binary onto your `PATH`:

```sh
# Replace ARCH with one of: aarch64-macos, x86_64-linux, aarch64-linux.
VERSION=$(curl -fsSL https://api.github.com/repos/daemonicai/memlite/releases/latest | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p')
curl -fsSL "https://github.com/daemonicai/memlite/releases/download/${VERSION}/memlite-${VERSION}-ARCH.tar.gz" | tar -xz
install -m 0755 "memlite-${VERSION}-ARCH/memlite" ~/.local/bin/memlite
```

Each tarball contains the `memlite` binary plus `README.md` and `LICENSE`. The binaries are fully self-contained — `otool -L` / `ldd` shows only the libc.

### Build from source

Zig 0.16 is required. For a `~/.local/bin/memlite` install, the bundled helper does both steps:

```sh
./install.sh
```

That's a one-liner over `zig build -Doptimize=ReleaseFast && install -m 0755 zig-out/bin/memlite ~/.local/bin/memlite`.

The first build pulls in llama.cpp and compiles it for CPU — expect several minutes. Subsequent builds are cached.

If you'd rather drop the binary somewhere else (or skip the install step entirely), build manually:

```sh
zig build -Doptimize=ReleaseFast
sudo install -m 0755 zig-out/bin/memlite /usr/local/bin/memlite
```

## First run

```sh
memlite init
```

This:

1. Creates `~/.memlite/` if absent.
2. Downloads the default embedding model — `nomic-embed-text-v1.5-Q5_K_M.gguf` (~99 MB) — to `~/.memlite/models/nomic-ai/nomic-embed-text-v1.5-GGUF/` if not already cached.
3. Creates the SQLite database at `~/.memlite/memlite.db` and pins the model URL + embedding dimension into its `settings` table.

After `init` completes, run the server:

```sh
memlite serve
```

It reads MCP JSON-RPC requests from stdin, writes responses to stdout, and logs to stderr.

Both `init` and `serve` will do the same setup on first run, so `memlite serve` directly against a clean machine works too — `init` just makes that step explicit.

## MCP host configuration

### Claude Code

Register memlite via the `claude mcp` CLI. The `--scope user` flag makes the server available across every Claude Code project on your machine, which matches memlite's role as a shared per-user memory store:

```sh
claude mcp add memlite --scope user -- /Users/you/.local/bin/memlite serve
```

Verify the server is registered and reachable:

```sh
claude mcp list
```

Omit `--scope user` (or pass `--scope local`) to register memlite for the current project only.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) and add:

```json
{
  "mcpServers": {
    "memlite": {
      "command": "/Users/you/.local/bin/memlite",
      "args": ["serve"]
    }
  }
}
```

Restart Claude Desktop.

### Anything else MCP-stdio

memlite reads JSON-RPC from stdin, one request per newline-terminated line, and writes JSON-RPC responses to stdout the same way. Any MCP host that speaks plain stdio (no LSP-style `Content-Length` framing) will work.

## CLI

```
memlite [serve|init|dump] [options]
```

| Subcommand | Purpose |
|---|---|
| `serve` (default) | Open the DB, ensure the model, and run the MCP loop. |
| `init`            | Same setup as `serve`, but exit immediately. Useful for separating first-run download from running the server. |
| `dump`            | Read the DB and write all rows as NDJSON to stdout (one JSON object per line, with a `_table` discriminator). |

Options:

| Flag | Meaning |
|---|---|
| `--db PATH`       | Override the DB path. Precedence: `--db` > `$MEMLITE_DB` > `~/.memlite/memlite.db`. |
| `--model URL`     | HuggingFace `/resolve/` URL for the GGUF embedding model. Pinned on first init; changing this against an existing DB raises `MODEL_MISMATCH`. |
| `--verbose-llama` | Re-enable the llama.cpp model-loader chatter on stderr. Off by default so MCP host log panes stay readable. `MEMLITE_VERBOSE_LLAMA=1` is an env-var fallback; the flag (including `--verbose-llama=false`) wins. |
| `-h`, `--help`    | Show help. |

## MCP tools

| Tool | Purpose |
|---|---|
| `memory_add` | Insert a memory with optional slug, format, tags. |
| `memory_load` | Read an absolute-path Markdown file and add it as a memory (`format='markdown'`; size capped at 1 MiB). |
| `memory_get` | Fetch a memory by id or slug. Bumps `last_accessed`. |
| `memory_update` | Partial update: any of content / format / slug / tags. Re-chunks + re-embeds on content or format change. |
| `memory_delete` | Soft-delete; a snapshot lands in `memories_history` via trigger. |
| `memory_clear` | Delete all memories; `retain_history=false` also wipes the history table. |
| `memory_tag` / `memory_untag` | Surgical tag mutations. |
| `memory_search` | Hybrid semantic + full-text retrieval, RRF-fused, with optional tag filter. |
| `memory_list` | Administrative listing with `where`, `since`, `limit`, `offset`, `order_by`. Doesn't bump `last_accessed`. |
| `memory_history` | Snapshots for a target (slug or id), most recent first. |
| `memory_status` | Aggregate counts + embedding settings + DB byte size. |
| `list_tags` / `list_tag_values` / `list_tag_siblings` | Tag discovery. |

Tool errors use the v1 string-code vocabulary (`SLUG_EXISTS`, `NOT_FOUND`, `INVALID_TARGET`, `INVALID_PATH`, `INVALID_FORMAT`, `EMBEDDING_FAILED`, `INVALID_URL`, `MODEL_MISMATCH`) inside the standard JSON-RPC error envelope.

## Data location

`~/.memlite/` — SQLite database (`memlite.db`) and downloaded GGUF models (`models/{owner}/{repo}/{filename}`). Single-user; multi-agent via a shared namespace with `source: <agent>` attribution tags.

## License

Mozilla Public License 2.0. See [`LICENSE`](LICENSE).
