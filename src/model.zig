//! GGUF model lifecycle wrapper over the llama.cpp.zig bindings.
//!
//! v1-foundation §6.4. Owns the llama_backend init/free pair and the
//! `llama_model *` for the configured model. Embedding context creation
//! and `embed(text)` live alongside (§7), but Group 6 only requires
//! `loadFromFile` + `embeddingDim`.

const std = @import("std");
const c = @import("llama_c");

pub const Error = error{
    BackendInitFailed,
    ModelLoadFailed,
    ContextInitFailed,
    TokenizeFailed,
    DecodeFailed,
    EmbeddingsUnavailable,
};

/// One-shot backend init. Idempotency is the caller's job — call once
/// before any Model.load and free at process exit.
pub fn initBackend() void {
    c.llama_backend_init();
    // Silence llama.cpp's chatty stderr printf log output (default for
    // non-server callers). Keep the protocol channel clean and let our
    // own std.log emit the human-facing progress lines.
    c.llama_log_set(null, null);
}

pub fn deinitBackend() void {
    c.llama_backend_free();
}

pub const LoadOptions = struct {
    /// When true, silence direct `fprintf(stderr, …)` chatter from the
    /// llama.cpp loader (`llama_model_loader:`, `print_info:`,
    /// `load_tensors:`, `create_tensor:`) by redirecting STDERR_FILENO to
    /// `/dev/null` for the duration of `llama_model_load_from_file`. The
    /// callback path (covered by `llama_log_set(null, null)` in
    /// `initBackend`) is unaffected. POSIX-only; on platforms where
    /// `/dev/null` cannot be opened or `dup` fails the load proceeds with
    /// stderr intact rather than failing.
    quiet: bool = false,
};

pub const Model = struct {
    handle: *c.llama_model,

    /// Load a GGUF file from disk. CPU-only (n_gpu_layers = 0).
    pub fn loadFromFile(path: [:0]const u8, opts: LoadOptions) Error!Model {
        var params = c.llama_model_default_params();
        params.n_gpu_layers = 0;

        var saved_stderr: c_int = -1;
        if (opts.quiet) {
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

        const m = c.llama_model_load_from_file(path.ptr, params);
        if (m == null) return Error.ModelLoadFailed;
        return .{ .handle = m.? };
    }

    pub fn deinit(self: *Model) void {
        c.llama_model_free(self.handle);
        self.* = undefined;
    }

    /// Embedding dimension reported by the GGUF model. This is the N that
    /// goes into vec0's `FLOAT[N]` declaration.
    pub fn embeddingDim(self: Model) u32 {
        const n = c.llama_model_n_embd(self.handle);
        std.debug.assert(n > 0);
        return @intCast(n);
    }

    /// Maximum context the model was trained on. Used by the embedding
    /// context to size n_ctx safely.
    pub fn trainedCtxLen(self: Model) u32 {
        const n = c.llama_model_n_ctx_train(self.handle);
        return if (n > 0) @intCast(n) else 0;
    }
};
