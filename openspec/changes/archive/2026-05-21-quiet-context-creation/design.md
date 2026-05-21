## Context

The previous `quiet-llama-logs` change made an incorrect assumption in Decision D2: "Subsequent embed calls go through `llama_decode` which uses the callback-routed log path, which `llama_log_set(null, null)` already silences." While `llama_decode` does route through the callback path, `llama_init_from_model()` — the context constructor — does not. It writes `llama_context:`, `sched_reserve:`, and `graph_reserve:` lines via direct `fprintf(stderr, …)`, the same mechanism used by the model loader.

This is a gap in the quiet-mode coverage: model load is suppressed, but the immediately-following context creation is not.

## Goals / Non-Goals

**Goals:**
- Silence `llama_context:`, `sched_reserve:`, and `graph_reserve:` stderr output during context creation when in quiet mode.
- Use the same `dup2(/dev/null)` pattern already proven in `model.zig`.
- Keep `--verbose-llama` as the single escape hatch for all suppressed llama.cpp output (loader + context creation).
- Zero changes to the vendored llama.cpp amalgamation.

**Non-Goals:**
- Suppressing `llama_decode` output (already handled by `llama_log_set`).
- Changing the flag name or env var behavior.
- Addressing POSIX-only assumption (same as previous change).

## Decisions

### D1 — Extend `Embedder.init()` with `quiet: bool` parameter

Two approaches considered:

(a) **Wrap the call in `main.zig`** — do the dup2 redirect in `setupSession()` around the `Embedder.init()` call. Rejected: puts knowledge of llama.cpp internals into `main.zig`, inconsistent with the model-load approach where redirect logic lives in the responsible module.

(b) **Add `quiet` parameter to `Embedder.init()`** — embed the redirect logic inside the same module that owns the llama.cpp interaction. Chosen: keeps the fd-redirect pattern co-located with the call it protects, mirrors `Model.loadFromFile`.

### D2 — Same redirect pattern as `model.zig`

Use the exact same `dup`/`dup2` pattern established in `Model.loadFromFile`:

```zig
var saved_stderr: c_int = -1;
if (quiet) {
    const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (dev_null >= 0) {
        saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
        if (saved_stderr >= 0) {
            _ = std.c.dup2(dev_null, std.posix.STDERR_FILENO);
        }
        _ = std.c.close(dev_null);
    }
}
defer {
    if (saved_stderr >= 0) {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
}
```

No new patterns, no new risk surface.

## Risks / Trade-offs

- **Same risks as model-load redirect:** if context creation logs a useful error to stderr before crashing, we swallow it. Mitigation: `llama_init_from_model` returns null on failure; memlite already writes its own `error:` line in that case.
- **API break:** `Embedder.init(model)` gains a required parameter. Only caller is `main.zig` and the embedded test, both updated in this change.

## Exact Changes

### `src/embed.zig`

**1. Add `quiet: bool` parameter to `init()` and insert stderr redirect before `llama_init_from_model`:**

```diff
-    pub fn init(model: model_mod.Model) Error!Embedder {
+    /// When `quiet` is true, stderr is redirected to /dev/null for the
+    /// duration of `llama_init_from_model` to suppress the verbose
+    /// context-construction diagnostics (POSIX-only, graceful fallback).
+    pub fn init(model: model_mod.Model, quiet: bool) Error!Embedder {
         var params = c.llama_context_default_params();
         params.embeddings = true;
         params.pooling_type = c.LLAMA_POOLING_TYPE_MEAN;
         params.no_perf = true;

         const n_ctx_train = model.trainedCtxLen();
         const n_ctx: u32 = if (n_ctx_train > 0) n_ctx_train else 2048;
         params.n_ctx = n_ctx;
         // Single-shot embedding: process the whole input as one batch.
         params.n_batch = n_ctx;
         params.n_ubatch = n_ctx;

+        // Suppress context-creation stderr chatter when quiet.
+        var saved_stderr: c_int = -1;
+        if (quiet) {
+            const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
+            if (dev_null >= 0) {
+                saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
+                if (saved_stderr >= 0) {
+                    _ = std.c.dup2(dev_null, std.posix.STDERR_FILENO);
+                }
+                _ = std.c.close(dev_null);
+            }
+        }
+        defer {
+            if (saved_stderr >= 0) {
+                _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
+                _ = std.c.close(saved_stderr);
+            }
+        }
+
         const ctx = c.llama_init_from_model(model.handle, params);
         if (ctx == null) return Error.ContextInitFailed;
```

**2. Update test to pass `quiet: true`:**

```diff
-    var emb = try Embedder.init(model);
+    var emb = try Embedder.init(model, true);
```

### `src/main.zig`

**3. Pass quiet flag from CLI:**

```diff
-    var embedder = try embed_mod.Embedder.init(model);
+    var embedder = try embed_mod.Embedder.init(model, !cli.verbose_llama);
```
