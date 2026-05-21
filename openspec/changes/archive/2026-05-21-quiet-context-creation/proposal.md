## Why

The archived `quiet-llama-logs` change (2026-05-21) successfully suppressed `llama_model_loader:`, `print_info:`, `load_tensors:`, and `create_tensor:` output during model loading. However, it missed an equally noisy path: context creation. When `Embedder.init()` calls `llama_init_from_model()`, the llama.cpp context constructor writes ~50 lines of `llama_context:`, `sched_reserve:`, and `graph_reserve:` diagnostics directly to stderr via `fprintf`. These bypass `llama_log_set(null, null)` just like the loader output does.

Every `memlite serve` start dumps this wall of text to the MCP host's log pane:

```
llama_context: constructing llama_context...
llama_context: n_seq_max     = 1
llama_context: n_ctx         = 2048
llama_context: n_ctx_seq     = 2048
llama_context: n_batch       = 2048
llama_context: n_ubatch      = 2048
llama_context: causal_attn   = 0
llama_context: flash_attn    = auto
...
sched_reserve: reserving ...
sched_reserve: max_nodes = 1024
...
graph_reserve: reserving a graph for ubatch with n_tokens = 2048...
sched_reserve:        CPU compute buffer size =   114.03 MiB
sched_reserve: graph nodes  = 336
```

This is especially visible in the Pi extension (memlite-pi), which inherits memlite's stderr to the user's terminal.

## What Changes

- `Embedder.init()` SHALL accept a `quiet: bool` parameter.
- When `quiet` is `true`, stderr SHALL be redirected to `/dev/null` for the duration of `llama_init_from_model()`, using the same `dup2` pattern already established in `Model.loadFromFile`.
- `main.zig` SHALL pass `!cli.verbose_llama` as the `quiet` value, matching the existing wiring for model loading.
- The spec SHALL be updated to reflect that both model loading AND context creation are quiet by default.

## Capabilities

### Modified Capabilities

- `embedding-engine` — "Model load is quiet by default" requirement broadened to cover context creation as well.

## Impact

- **Code:** ~25 lines added to `src/embed.zig` (dup2 redirect + defer restore). One line changed in `src/main.zig` (pass `quiet` param). Embedded test updated.
- **CLI:** No new flags. `--verbose-llama` now re-enables both loader AND context-creation output.
- **No schema changes, no DB migration, no new dependencies.**
- **Back-compat:** API change — `Embedder.init(model)` gains a required `quiet: bool` parameter. Only caller is `main.zig`, which is updated.
