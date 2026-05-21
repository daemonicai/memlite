## MODIFIED Requirements

### Requirement: First-run auto-download with progress on stderr

When `memlite serve` is invoked and the resolved model file is missing or has an unexpected size/integrity, the system SHALL download it via HTTPS using Zig's `std.http.Client` (`std.crypto.tls`, `std.crypto.Certificate.Bundle` for system CA roots). Progress MUST be reported as plain text lines on stderr; the protocol stream on stdout MUST remain inactive until the model is loaded. **Stderr SHALL NOT be polluted by third-party loader output by default — see "Model load is quiet by default" below.**

#### Scenario: stdout remains JSON-RPC clean

- **WHEN** a download is in progress
- **THEN** stdout receives NO output until the MCP server is initialized and ready to handle requests

#### Scenario: Memlite's own progress lines survive

- **WHEN** a download is in progress under default settings
- **THEN** memlite's `info: …` progress lines are visible on stderr; no third-party `llama_model_loader:` / `print_info:` lines are mixed in

## ADDED Requirements

### Requirement: Model load is quiet by default

`Model.loadFromFile` SHALL suppress all `fprintf(stderr, …)` output emitted by the llama.cpp loader (`llama_model_loader:`, `print_info:`, `load_tensors:`, `create_tensor:`) during the model-load window. Memlite's own logging (`info:`, `error:`, etc.) MUST be unaffected.

The suppression is implemented by redirecting `STDERR_FILENO` to `/dev/null` for the duration of `llama_model_load_from_file` and restoring the original FD immediately after. Subsequent llama.cpp output goes through the `llama_log_set` callback path, which `initBackend` already silences with `llama_log_set(null, null)`.

#### Scenario: Default start has clean stderr

- **WHEN** `memlite serve` is invoked with a cached model and an initialized DB
- **THEN** stderr contains only memlite's own `info:` and (if any) `error:` lines; no `llama_model_loader:` / `print_info:` / `load_tensors:` lines appear

#### Scenario: Model-load failure still surfaces

- **WHEN** `llama_model_load_from_file` returns null (corrupt file, dimension mismatch, etc.)
- **THEN** memlite writes its own `error: failed to load model {path}: …` line to stderr and exits nonzero

### Requirement: Verbose mode opt-in

Memlite SHALL accept a `--verbose-llama` flag and `MEMLITE_VERBOSE_LLAMA=1` env var; either re-enables the suppressed loader output for the duration of `memlite serve` / `memlite init`. The flag takes precedence over the env var.

#### Scenario: Flag re-enables loader output

- **WHEN** `memlite serve --verbose-llama` is invoked
- **THEN** stderr contains the full set of `llama_model_loader:` / `print_info:` / `load_tensors:` lines exactly as today

#### Scenario: Env var equivalent

- **WHEN** `MEMLITE_VERBOSE_LLAMA=1 memlite serve` is invoked (without the flag)
- **THEN** the behavior matches `--verbose-llama`

#### Scenario: Flag wins

- **WHEN** `MEMLITE_VERBOSE_LLAMA=1 memlite serve --verbose-llama=false` is invoked
- **THEN** loader output is suppressed (the explicit flag overrides the env var)
