## 1. ProgressWriter

- [ ] 1.1 In `src/download.zig`, define a `ProgressWriter` struct with a `std.Io.Writer.VTable` whose `drain` forwards data to an inner Writer and increments a byte counter
- [ ] 1.2 Accept `total: ?u64` and an emit threshold of 5% (when total is known) or 5 MiB (when total is unknown)
- [ ] 1.3 Emit `info: memlite: download {basename}: X / Y MiB (NN%)` on every threshold crossing; final line printed unconditionally after the stream ends

## 2. Switch from fetch to request

- [ ] 2.1 Replace `client.fetch(...)` with `client.request(.GET, uri, .{...})` so we can inspect `response_content_length` after `receiveHead`
- [ ] 2.2 Hand the response body reader to a manual chunked-copy loop that writes into the ProgressWriter (which writes into the atomic-file writer)
- [ ] 2.3 Preserve the existing atomic-temp-file → replace semantics; the ProgressWriter sits between the body reader and the file writer
- [ ] 2.4 Preserve the existing error mapping (HTTP non-200 → `HttpStatusNotOk`; write failure → `WriteFailed`; replace failure → `ReplaceFailed`)

## 3. Tests

- [ ] 3.1 Unit test against an in-memory 10 MiB byte stream with `total = 10 << 20`: assert the number of emitted lines is in [18, 22] and that each line includes the `(X / Y MiB, NN%)` format
- [ ] 3.2 Unit test with `total = null` and a 50 MiB stream: assert lines emitted ≥ 9 (roughly 50/5)

## 4. Verification

- [ ] 4.1 Manual test: clear `~/.memlite/models/nomic-ai/`, run `memlite init`, observe ~20 progress lines on stderr ending with `100%` then the final `downloaded N bytes` line
- [ ] 4.2 Manual test: re-run `memlite init` with the model cached — no download lines appear, only the existing `model cached at …` line
