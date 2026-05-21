## 1. CLI plumbing

- [x] 1.1 Add `--verbose-llama` to `Cli` in `src/main.zig` (default false)
- [x] 1.2 Honour `MEMLITE_VERBOSE_LLAMA=1` env var as a fallback when the flag is absent
- [x] 1.3 Document the flag in `--help` output and in README

## 2. Stderr redirect

- [x] 2.1 In `src/model.zig`, add `Model.loadFromFile(path, .{ .quiet = true })` (or an alternate constructor)
- [x] 2.2 When `quiet` is set, `dup` stderr to a saved FD, `dup2` `/dev/null` over stderr, run the load, restore the saved FD
- [x] 2.3 Ensure the restore path runs on every error branch (defer/errdefer) so a load failure doesn't leak the redirect into the rest of the process

## 3. Wiring

- [x] 3.1 `runServe` / `runInit` call the quiet variant unless `cli.verbose_llama` is true
- [x] 3.2 `llama_log_set(null, null)` stays in `initBackend` — covers the callback path for steady-state embed calls

## 4. Verification

- [x] 4.1 Manual test: `memlite serve` against a cached model + existing DB; stderr contains only memlite's `info:` lines, no `llama_model_loader:` / `print_info:` / `load_tensors:` output
- [x] 4.2 Manual test: `memlite serve --verbose-llama` against the same — stderr contains the full loader output
- [x] 4.3 Manual test: point `--model` at a deliberately broken URL after the DB is fresh — confirm memlite's own `error:` line still surfaces (model load fails after download but before redirect — verify ordering)
