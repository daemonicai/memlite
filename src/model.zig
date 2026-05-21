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

pub const Model = struct {
    handle: *c.llama_model,

    /// Load a GGUF file from disk. CPU-only (n_gpu_layers = 0).
    pub fn loadFromFile(path: [:0]const u8) Error!Model {
        var params = c.llama_model_default_params();
        params.n_gpu_layers = 0;
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
