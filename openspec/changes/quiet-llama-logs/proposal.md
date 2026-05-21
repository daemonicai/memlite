## Why

In v1, `memlite serve` loading the GGUF model on startup writes ~100 lines of `llama_model_loader:`, `print_info:`, `load_tensors:`, and `create_tensor:` output to stderr — output that comes from `fprintf(stderr, …)` calls inside llama.cpp and ggml that the `llama_log_set(null, null)` callback hook does not intercept. MCP hosts surface stderr to users; the result is that every server start dumps an unreadable wall of internal logs into the host's log pane, hiding memlite's own progress lines and any real errors.

The v1 embedding-engine spec already commits to "Progress MUST be reported as plain text lines on stderr" — it implicitly assumes that stderr stays a useful channel. Today it isn't.

## What Changes

- `memlite` MUST silence direct `fprintf(stderr, …)` chatter from llama.cpp and ggml during model load by default, while preserving its own `info:` / `error:` lines.
- A `--verbose-llama` flag (and `MEMLITE_VERBOSE_LLAMA=1` env var) MUST re-enable the suppressed output for debugging, including all llama.cpp logging paths.
- The default-quiet mode MUST NOT mask actual errors: if `llama_model_load_from_file` returns null, memlite's own `error: failed to load model …` line MUST still appear on stderr.

## Capabilities

### Modified Capabilities

- `embedding-engine` — adds a "Model load is quiet by default" requirement; `--verbose-llama` is the documented escape hatch.

### New Capabilities

None.

## Impact

- **Code:** Wrap the model-load call in a temporary stderr redirect (e.g. `dup2` the FD to `/dev/null`) for the duration of `llama_model_load_from_file`, restore afterwards. Or, equivalently, link a stub `fprintf` impl — but FD redirect is simpler and keeps the third-party amalgamation untouched.
- **CLI:** new `--verbose-llama` flag in `src/main.zig`; documented in README.
- **No schema changes, no DB migration, no new dependencies.**
- **Tests:** snapshot test that `memlite serve` startup stderr (after model is cached) contains only the four `info:` lines memlite emits, no `llama_model_loader:` or `print_info:` lines.
- **No back-compat risk:** existing users see less noise. Anyone debugging a model-load problem gets the old behavior back with one flag.
