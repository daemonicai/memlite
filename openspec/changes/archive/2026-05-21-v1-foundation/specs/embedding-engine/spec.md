## ADDED Requirements

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

When `memlite serve` is invoked and the resolved model file is missing or has an unexpected size/integrity, the system SHALL download it via HTTPS using Zig's `std.http.Client` (`std.crypto.tls`, `std.crypto.Certificate.Bundle` for system CA roots). Progress MUST be reported as plain text lines on stderr; the protocol stream on stdout MUST remain inactive until the model is loaded.

#### Scenario: Missing model triggers download

- **WHEN** `memlite serve` starts and the resolved model path does not exist
- **THEN** the system creates the parent directory tree, downloads the model over HTTPS, and reports progress on stderr (e.g., `memlite: downloading model (12% / 17.2 MB)`)

#### Scenario: stdout remains JSON-RPC clean

- **WHEN** a download is in progress
- **THEN** stdout receives NO output until the MCP server is initialized and ready to handle requests

#### Scenario: Download to atomic location

- **WHEN** a download is in progress
- **THEN** bytes are written to a temporary file (e.g., `<path>.partial`) and renamed atomically to the final path only after the full download completes

#### Scenario: Network failure surfaces clearly

- **WHEN** the HTTP request fails (DNS, TLS, 4xx/5xx, abort)
- **THEN** the system writes a clear error to stderr describing the failure and exits with a nonzero status code; no MCP server is started

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
