# embedding-engine Specification

## Purpose
TBD - created by archiving change v1-foundation. Update Purpose after archive.
## Requirements
### Requirement: Embeddings are produced by llama.cpp linked into the memlite binary

The system SHALL embed text using llama.cpp, linked statically into the memlite binary via the [diogok/llama.cpp.zig](https://github.com/diogok/llama.cpp.zig) build dependency declared in `build.zig.zon`. No external `llama.cpp` library is loaded at runtime, no `dlopen`, and no separate `sqlmem` / `sqlite-memory` extension is required.

#### Scenario: Binary has no dynamic llama dependency

- **WHEN** the built `memlite` binary is inspected for dynamic library dependencies (`otool -L` on macOS, `ldd` on Linux)
- **THEN** no `libllama`, `libggml`, or related third-party shared library is listed; only system libraries (libc, libSystem, etc.) appear

### Requirement: CPU-only inference in v1

The system SHALL configure llama.cpp's CPU backend (Accelerate/AMX on macOS, native CPU on Linux). The Metal backend MUST NOT be enabled in v1; the build MUST NOT produce a `default.metallib` sidecar.

#### Scenario: Built artifact is a single file

- **WHEN** `zig build` completes successfully
- **THEN** the output is one executable file (e.g., `zig-out/bin/memlite`) with no accompanying `default.metallib` or other resource sidecar

### Requirement: Model is specified by HuggingFace URL via --model flag

`memlite serve` and `memlite init` SHALL accept an optional `--model <url>` flag. The URL MUST match the form `https://huggingface.co/{owner}/{repo}/resolve/{branch}/{filename}[?query]`. When the flag is omitted, the system SHALL use a built-in default URL for `nomic-embed-text-v1.5-Q5_K_M.gguf`.

#### Scenario: Valid HF URL accepted

- **WHEN** `memlite serve --model https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf?download=true` is invoked
- **THEN** the URL is parsed into `{owner: 'nomic-ai', repo: 'nomic-embed-text-v1.5-GGUF', filename: 'nomic-embed-text-v1.5.Q5_K_M.gguf'}`; the query string is preserved for the HTTP fetch but ignored for the local cache path

#### Scenario: /blob/ URL rejected

- **WHEN** a URL of the form `https://huggingface.co/{owner}/{repo}/blob/...` is supplied
- **THEN** the system MUST exit with error `INVALID_URL` and a message stating that only `/resolve/` URLs are accepted

#### Scenario: Non-HuggingFace URL rejected in v1

- **WHEN** a URL with a host other than `huggingface.co` is supplied
- **THEN** the system MUST exit with error `INVALID_URL`

### Requirement: Cache layout under ~/.memlite/models mirrors HuggingFace namespace

Downloaded models SHALL be stored at `~/.memlite/models/{owner}/{repo}/{filename}`, where `{owner}`, `{repo}`, and `{filename}` are derived strictly from the URL path. Multiple downloaded models for different repos MUST coexist without collision.

#### Scenario: Model cached at derived path

- **WHEN** the default model is downloaded on first run
- **THEN** the file exists at `~/.memlite/models/nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q5_K_M.gguf`

#### Scenario: Two models from different repos coexist

- **WHEN** memlite has previously downloaded one model and is later invoked with `--model` pointing to a different repo
- **THEN** both files exist on disk in their respective `~/.memlite/models/{owner}/{repo}/{filename}` paths; neither is overwritten

### Requirement: First-run auto-download with progress on stderr

When `memlite serve` is invoked and the resolved model file is missing or has an unexpected size/integrity, the system SHALL download it via HTTPS using Zig's `std.http.Client` (`std.crypto.tls`, `std.crypto.Certificate.Bundle` for system CA roots). Progress MUST be reported as plain text lines on stderr; the protocol stream on stdout MUST remain inactive until the model is loaded. **Stderr SHALL NOT be polluted by third-party loader output by default — see "Model load is quiet by default" below.**

#### Scenario: stdout remains JSON-RPC clean

- **WHEN** a download is in progress
- **THEN** stdout receives NO output until the MCP server is initialized and ready to handle requests

#### Scenario: Memlite's own progress lines survive

- **WHEN** a download is in progress under default settings
- **THEN** memlite's `info: …` progress lines are visible on stderr; no third-party `llama_model_loader:` / `print_info:` lines are mixed in

### Requirement: Embedding dimension discovered from the loaded model

On first DB initialization, the system SHALL load the GGUF model, query its embedding dimension `N`, and use that value both to declare `CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding FLOAT[N])` and to write `settings('embedding_dim', N)`.

#### Scenario: First-run records dimension

- **WHEN** a fresh DB is initialized with the default model (768-dim)
- **THEN** `vec_chunks` is declared with `FLOAT[768]` and `settings('embedding_dim')` equals `'768'`

### Requirement: Model switch is refused without explicit reindex

On every startup with an existing DB, the system SHALL compare the requested `model_url` (from `--model` or default) against `settings('model_url')`. If they differ, memlite MUST exit before serving with error `MODEL_MISMATCH` and a message naming the stored model, the requested model, and the remedial actions: `memlite reindex` (deferred to v2) or deleting the DB.

#### Scenario: Same model proceeds

- **WHEN** memlite starts with `--model URL` that matches the stored `settings('model_url')`
- **THEN** the server initializes normally and accepts requests

#### Scenario: Different model rejected

- **WHEN** memlite starts with a `--model URL` different from the stored value
- **THEN** the server MUST NOT start; stderr MUST include the stored model, the requested model, and remedial guidance; exit status is nonzero

### Requirement: Embedding produces a fixed-dim float vector per chunk

For every chunk presented for embedding, the system SHALL produce an N-dimension float vector matching the model's `n_embd`. If embedding fails (model crash, OOM, malformed input), the error MUST surface as `EMBEDDING_FAILED` to the calling tool and the calling transaction MUST roll back.

#### Scenario: Embedding succeeds for normal input

- **WHEN** a chunk's text is presented for embedding
- **THEN** the system returns a `[N]float` vector with the expected dimension

#### Scenario: Embedding fails

- **WHEN** the embedding call returns an error
- **THEN** the tool currently in progress returns `EMBEDDING_FAILED` and the SQLite transaction is rolled back so no partial `chunks` or `vec_chunks` rows persist

### Requirement: No remote embedding or multi-provider support in v1

The system SHALL NOT make outbound HTTP calls for embedding at request time. The only outbound network use SHALL be the one-time model download on first run (or when the user explicitly switches model and starts fresh).

#### Scenario: Steady-state offline operation

- **WHEN** the model is already present on disk
- **THEN** memlite serves MCP requests with no outbound network activity

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

