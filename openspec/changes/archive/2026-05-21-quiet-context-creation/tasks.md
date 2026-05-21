## 1. Add quiet parameter to Embedder.init

- [x] 1.1 Add `quiet: bool` parameter to `Embedder.init()` signature in `src/embed.zig`
- [x] 1.2 Insert `dup2(/dev/null)` stderr redirect block before `llama_init_from_model()`, with `defer` restore — mirroring the exact pattern from `Model.loadFromFile` in `src/model.zig`
- [x] 1.3 Update the doc comment above `init()` to document the `quiet` parameter

## 2. Wire into main.zig

- [x] 2.1 Pass `!cli.verbose_llama` as the `quiet` argument in the `Embedder.init()` call in `setupSession()` (`src/main.zig`)

## 3. Update test

- [x] 3.1 Update the embed test at the bottom of `src/embed.zig` to pass `true` (quiet) as the second argument to `Embedder.init()`

## 4. Build and verify

- [x] 4.1 Run `zig build` — confirm clean compilation
- [x] 4.2 Test `memlite init` (quiet default): stderr contains only `info: memlite:` lines, no `llama_context:`, `sched_reserve:`, or `graph_reserve:` output
- [x] 4.3 Test `memlite init --verbose-llama`: stderr contains full llama.cpp output including context-creation diagnostics
- [x] 4.4 Test `memlite init --verbose-llama=false`: same quiet behavior as default

## 5. Spec update

- [x] 5.1 Update the embedding-engine spec's "Model load is quiet by default" requirement to also cover context creation output, adding `llama_context:`, `sched_reserve:`, and `graph_reserve:` to the suppressed output list
- [x] 5.2 Update the scenario titles to reflect the broader scope (e.g., "Default start has clean stderr" → already covers this case since the scenario is end-to-end)
