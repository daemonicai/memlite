## MODIFIED Requirements

### Requirement: First-run auto-download with progress on stderr

When `memlite serve` is invoked and the resolved model file is missing or has an unexpected size/integrity, the system SHALL download it via HTTPS using Zig's `std.http.Client` (`std.crypto.tls`, `std.crypto.Certificate.Bundle` for system CA roots). Progress MUST be reported as plain text lines on stderr, terminated by `\n`. The implementation MUST emit:

- One opening line `info: memlite: downloading {url}` before any body bytes are read.
- One progress line per **5% of the content** when `Content-Length` is present, or per **5 MiB received** when it is not. Each progress line MUST be of the form `info: memlite: download {basename}: X / Y MiB (NN%)` (or `info: memlite: download {basename}: X MiB` when total is unknown).
- One closing line `info: memlite: downloaded N bytes -> {basename}` after the body is fully written and the atomic replace has succeeded.

The protocol stream on stdout MUST remain inactive until the model is loaded.

#### Scenario: Missing model triggers download

- **WHEN** `memlite serve` starts and the resolved model path does not exist
- **THEN** the system creates the parent directory tree, downloads the model over HTTPS, and reports progress on stderr per the cadence above

#### Scenario: Progress cadence with known Content-Length

- **WHEN** the download is in progress and the server returned a `Content-Length` header
- **THEN** between 18 and 22 progress lines appear on stderr, each with `(X / Y MiB, NN%)` and monotonically increasing percentages

#### Scenario: Progress cadence with chunked transfer

- **WHEN** the download is in progress and the server omitted `Content-Length`
- **THEN** progress lines appear every 5 MiB received; the percentage suffix is omitted

#### Scenario: stdout remains JSON-RPC clean

- **WHEN** a download is in progress
- **THEN** stdout receives NO output until the MCP server is initialized and ready to handle requests

#### Scenario: Download to atomic location

- **WHEN** a download is in progress
- **THEN** bytes are written to a temporary file in the destination directory and renamed atomically to the final path only after the full download completes

#### Scenario: Network failure surfaces clearly

- **WHEN** the HTTP request fails (DNS, TLS, 4xx/5xx, abort)
- **THEN** the system writes a clear error to stderr describing the failure and exits with a nonzero status code; no MCP server is started
