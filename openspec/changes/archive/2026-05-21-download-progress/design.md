## Context

`std.http.Client.fetch` writes the response body into a caller-provided `*std.Io.Writer` and returns a `FetchResult { status }`. No callback, no streaming hook into the body — the caller's responsibility is to provide a Writer that does whatever per-byte work is needed. So the entry point for progress is to wrap the file Writer with one that counts bytes and emits log lines.

The wrapper needs to:

1. Forward all bytes to the inner Writer untouched.
2. Maintain a running byte counter.
3. Know the total length (Content-Length from the response) so percentage math works.
4. Emit log lines at threshold crossings.

(3) is the awkward one because `fetch` doesn't expose response headers to a `response_writer` — by the time the writer sees bytes, the headers have already been parsed and discarded into `FetchResult`. So we need to either (a) call `client.request(...)` directly and inspect the response struct ourselves, or (b) accept that we may not know total content length.

## Goals / Non-Goals

**Goals:**
- One stderr line every ~5% of the download, line-oriented (no `\r`), parseable by `grep` / `awk`.
- Works whether or not Content-Length is known.
- Wrapper has zero allocations on the hot path (writes go through, log lines use a stack buffer).

**Non-Goals:**
- A spinner, color, or any TTY-specific UI. Stderr is line-oriented per the v1 spec.
- Throughput / ETA estimation. Useful but adds complexity; deferred.
- Streaming progress for `memlite dump` or other long-running ops. This change is scoped to the model download path.

## Decisions

### D1 — Use `client.request(...)` instead of `client.fetch(...)`

We move from `fetch` to the lower-level `Client.request` flow:

```zig
var req = try client.request(.GET, uri, .{ ... });
defer req.deinit();
try req.sendBodiless();
try req.receiveHead(redirect_buffer);
const content_length = req.response_content_length; // ?u64
const body = req.reader.bodyReader(...);
// stream chunks from `body` into atomic.file with progress counter
```

The downside is more code than `fetch`. The upside is full access to the response — including Content-Length, so progress can show percent.

### D2 — Threshold cadence: 5% or 5 MiB

When total is known, emit at 5%, 10%, 15%, ... 100%. When total is unknown (chunked transfer), emit every 5 MiB. Both give roughly 20 lines per typical model download. Avoids per-chunk spam; survives small read sizes from sqlite-vec-style streams that might call write() in tiny increments.

### D3 — Wrapper is a Zig `Writer`, not a counting `bodyReader`

The progress wrapper lives on the WRITE side, wrapping the file-writer. Two reasons:

(a) `bodyReader` returns bytes from the network — wrapping that would require a reader-to-writer pipe to count them, which the std API doesn't directly provide.

(b) The "bytes successfully written to disk" count is more honest than "bytes received over the network" if we ever batch or buffer.

Implementation: a small `Writer.VTable` whose drain function copies into the inner writer's buffer and increments the counter, then calls the inner drain. Zig 0.16's vtable shape makes this ~30 lines.

## Risks / Trade-offs

- **Code volume.** `Client.request` is more verbose than `fetch`. Acceptable: the v1 implementation was 50 lines; this might grow to 100.
- **Cancellation.** The current code has no cancellation path. Progress doesn't change that, but the threshold-emit logic should be ready for a cancel hook later (just don't fight us).
- **Test fragility.** Asserting "20 lines emitted" depends on Content-Length being known. Test should accept a range (e.g. 15–25 lines) or pin via a fixed-size input stream.

## Open Questions

- Should we also report final throughput on the "downloaded N bytes" line (e.g. `… in 12.3s, 8.1 MiB/s`)? Mildly useful; defer to a follow-up.
