## Why

v1 reports first-run model download as exactly two lines: `info: downloading <url>` at the start and `info: downloaded N bytes -> <basename>` at the end. The default model is ~99 MB; depending on bandwidth, the gap between the two lines is anywhere from 30 seconds to several minutes during which the user sees nothing. That feels broken — they don't know whether memlite is downloading, blocked on TLS, or hung.

The v1 embedding-engine spec already includes the example progress shape `memlite: downloading model (12% / 17.2 MB)`. The implementation currently doesn't match that example.

## What Changes

- `download.zig` MUST emit a progress line on stderr every ~5% of the total content length, plus the existing start and finish lines.
- When the server returns a `Content-Length` header, the progress line MUST include `(X / Y MiB, NN%)`. When it does not (chunked transfer), progress falls back to `(X MiB)` without the percent.
- Progress lines MUST go to stderr, terminated by `\n` (no carriage-return overstrike — the v1 spec is explicit about line-oriented progress so the output is grep-able and host-log-friendly).
- The implementation MUST preserve the existing atomic-temp-file-and-rename semantics — progress is a wrapper concern, not a storage concern.

## Capabilities

### Modified Capabilities

- `embedding-engine` — sharpens the existing "First-run auto-download with progress on stderr" requirement with a concrete cadence and format.

### New Capabilities

None.

## Impact

- **Code:** a `ProgressWriter` wrapping a `*std.Io.Writer` and counting bytes; emits a log line each time it crosses a 5%-of-total threshold (or every 5 MiB if total is unknown). Sits between `std.http.Client.fetch`'s `response_writer` and the underlying `File.Writer`.
- **No schema changes, no DB migration, no new dependencies.** The Writer interface in Zig 0.16 std lets us wrap with a small vtable.
- **Tests:** unit test against a 10-MiB byte stream confirming the threshold logic emits the expected number of lines; manual test that a real first-run download produces ~20 progress lines.
- **No back-compat risk:** existing callers of `download.download` see the same return shape; only stderr changes.
