## Context

`llama_log_set(callback, userdata)` intercepts the callback-routed logging in modern llama.cpp, but a sizeable slice of loader output predates that callback: `llama_model_loader`, `print_info`, `load_tensors`, `create_tensor` all `fprintf(stderr, …)` directly. They're noisy by design (loader transparency for power users) and there is no compile-time switch in upstream to disable them without forking.

For memlite running under an MCP host, this output is wrong-shaped: the host surfaces stderr to its user, so a single `memlite serve` start dumps ~100 unreadable lines of tensor names + model metadata into the user-visible log.

## Goals / Non-Goals

**Goals:**
- Default-quiet startup. Stderr after model load contains only memlite's own `info:` / `error:` lines.
- One-flag escape hatch for diagnosing model-load problems.
- Zero patches to the vendored amalgamation or to the llama.cpp.zig fork.

**Non-Goals:**
- Suppressing memlite's own logging.
- Capturing the suppressed output for later replay. If you want it, use the flag.
- Long-term: upstreaming a quiet-mode flag to llama.cpp. Out of scope for this change.

## Decisions

### D1 — FD-level redirect over symbol-replacement

We considered two implementation paths:

(a) Linker-level: replace `fprintf` with a stub that filters by FILE*. Touches the static-lib link surface, requires platform-specific tricks for weak symbols, and risks accidentally swallowing libc's own diagnostics elsewhere.

(b) FD redirect: open `/dev/null`, `dup2` its FD onto `STDERR_FILENO` immediately before `llama_model_load_from_file`, restore the original FD immediately after. The redirect window is ~1 second of loader chatter; nothing else memlite cares about runs during that interval.

We picked (b). It's ~20 lines of Zig, has no link-surface effect, and doesn't depend on any llama.cpp internals.

### D2 — Scope: model load only

The redirect covers `Model.loadFromFile` only. Subsequent embed calls go through `llama_decode` which uses the callback-routed log path, which `llama_log_set(null, null)` already silences. Verified empirically: the second invocation of `memlite serve` against a cached model + initialized DB produces zero loader output even today.

### D3 — Flag name + env var

`--verbose-llama` is unambiguous and won't collide with future `--verbose` flags for memlite's own logging. `MEMLITE_VERBOSE_LLAMA=1` mirrors the existing `MEMLITE_DB` env-var pattern.

## Risks / Trade-offs

- **Loader errors during model load.** If the loader writes a useful error to stderr immediately before crashing, the FD redirect swallows it. Mitigation: `llama_model_load_from_file` returns null on failure, which memlite already turns into its own `error:` line; we lose the loader's pre-failure diagnostic. Acceptable cost for the noise reduction; users who hit it get the diagnostic back via `--verbose-llama`.
- **Windows.** v1 doesn't target Windows, but if it ever does, `dup2` is POSIX-only. We'll need a Windows path (`SetStdHandle`) at that time.

## Open Questions

- Should the env var support a numeric level (`0` quiet, `1` loader, `2` everything) or stay binary? Binary for v1, level for v2+ if anyone asks.
