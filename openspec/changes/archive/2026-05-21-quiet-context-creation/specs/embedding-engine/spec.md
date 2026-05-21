## MODIFIED: Requirement — Model load and context creation are quiet by default

`Model.loadFromFile` and `Embedder.init` SHALL suppress all `fprintf(stderr, …)` output emitted by llama.cpp during their respective operations. This includes:

- **Model loading** (`Model.loadFromFile`): `llama_model_loader:`, `print_info:`, `load_tensors:`, `create_tensor:`
- **Context creation** (`Embedder.init` / `llama_init_from_model`): `llama_context:`, `sched_reserve:`, `graph_reserve:`

Memlite's own logging (`info:`, `error:`, etc.) MUST be unaffected.

The suppression is implemented by redirecting `STDERR_FILENO` to `/dev/null` for the duration of each llama.cpp call and restoring the original FD immediately after. Context creation suppression uses the same `dup2` pattern established in `Model.loadFromFile`. Llama.cpp output from `llama_decode` (steady-state embedding) goes through the `llama_log_set` callback path, which `initBackend` silences with `llama_log_set(null, null)`.

#### Scenario: Default start has clean stderr

- **WHEN** `memlite serve` is invoked with a cached model and an initialized DB
- **THEN** stderr contains only memlite's own `info:` and (if any) `error:` lines; no `llama_model_loader:` / `print_info:` / `load_tensors:` / `llama_context:` / `sched_reserve:` / `graph_reserve:` lines appear

#### Scenario: Model-load failure still surfaces

- **WHEN** `llama_model_load_from_file` returns null (corrupt file, dimension mismatch, etc.)
- **THEN** memlite writes its own `error: failed to load model {path}: …` line to stderr and exits nonzero

#### Scenario: Context-creation failure still surfaces

- **WHEN** `llama_init_from_model` returns null
- **THEN** memlite writes its own `error: context init failed` line to stderr and exits nonzero

## MODIFIED: Requirement — Verbose mode opt-in

Memlite SHALL accept a `--verbose-llama` flag and `MEMLITE_VERBOSE_LLAMA=1` env var; either re-enables ALL suppressed llama.cpp output (model loader + context creation) for the duration of `memlite serve` / `memlite init`. The flag takes precedence over the env var.

#### Scenario: Flag re-enables all llama.cpp output

- **WHEN** `memlite serve --verbose-llama` is invoked
- **THEN** stderr contains the full set of `llama_model_loader:` / `print_info:` / `load_tensors:` / `llama_context:` / `sched_reserve:` / `graph_reserve:` lines exactly as today

#### Scenario: Env var equivalent

- **WHEN** `MEMLITE_VERBOSE_LLAMA=1 memlite serve` is invoked (without the flag)
- **THEN** the behavior matches `--verbose-llama`

#### Scenario: Flag wins

- **WHEN** `MEMLITE_VERBOSE_LLAMA=1 memlite serve --verbose-llama=false` is invoked
- **THEN** all llama.cpp output is suppressed (the explicit flag overrides the env var)
