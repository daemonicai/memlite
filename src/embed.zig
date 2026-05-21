//! Single-text embedding over a loaded llama.cpp model.
//!
//! v1-foundation §7. Holds an embedding-mode `llama_context` (pooling = MEAN,
//! embeddings = true) tied to the Model from §6. `embed(text)` tokenizes,
//! runs a single forward pass, pulls the pooled sequence embedding, and
//! L2-normalizes it for cosine retrieval.

const std = @import("std");
const c = @import("llama_c");
const model_mod = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    ContextInitFailed,
    TokenizeFailed,
    InputTooLong,
    DecodeFailed,
    EmbeddingsUnavailable,
} || Allocator.Error;

/// Map any error returned from `Embedder.embed` to the v1 string code the
/// MCP server is required to surface to clients. Keep this in lockstep
/// with the `EMBEDDING_FAILED` requirement in the mcp-server spec.
pub fn errorCode(err: Error) []const u8 {
    return switch (err) {
        Error.OutOfMemory => "EMBEDDING_FAILED",
        else => "EMBEDDING_FAILED",
    };
}

pub const Embedder = struct {
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    dim: u32,
    n_ctx: u32,

    /// Open an embedding-mode context over `model`. The Model must outlive
    /// the Embedder. CPU-only — params.n_gpu_layers stays at the default 0.
    pub fn init(model: model_mod.Model) Error!Embedder {
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

        const ctx = c.llama_init_from_model(model.handle, params);
        if (ctx == null) return Error.ContextInitFailed;

        const vocab_ptr = c.llama_model_get_vocab(model.handle);
        std.debug.assert(vocab_ptr != null);

        return .{
            .ctx = ctx.?,
            .vocab = vocab_ptr.?,
            .dim = model.embeddingDim(),
            .n_ctx = n_ctx,
        };
    }

    pub fn deinit(self: *Embedder) void {
        c.llama_free(self.ctx);
        self.* = undefined;
    }

    /// Embed `text` into a freshly allocated, L2-normalized `[]f32` of
    /// length `self.dim`. Caller owns the returned slice.
    pub fn embed(self: *Embedder, gpa: Allocator, text: []const u8) Error![]f32 {
        // Two-call tokenize: probe required length, then fill.
        const need = -c.llama_tokenize(
            self.vocab,
            text.ptr,
            @intCast(text.len),
            null,
            0,
            true, // add_special: BOS/EOS or BERT [CLS]/[SEP]
            true, // parse_special
        );
        if (need <= 0) return Error.TokenizeFailed;
        if (@as(u32, @intCast(need)) > self.n_ctx) return Error.InputTooLong;

        const tokens = try gpa.alloc(c.llama_token, @intCast(need));
        defer gpa.free(tokens);

        const got = c.llama_tokenize(
            self.vocab,
            text.ptr,
            @intCast(text.len),
            tokens.ptr,
            @intCast(tokens.len),
            true,
            true,
        );
        if (got < 0 or got != need) return Error.TokenizeFailed;

        // Build a single-sequence batch covering all tokens.
        var batch = c.llama_batch_init(@intCast(tokens.len), 0, 1);
        defer c.llama_batch_free(batch);

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            batch.token[i] = tokens[i];
            batch.pos[i] = @intCast(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            // Pooling needs logits set on every position so the pooled
            // embedding can be computed; for MEAN pooling llama.cpp
            // requires all tokens flagged.
            batch.logits[i] = 1;
        }
        batch.n_tokens = @intCast(tokens.len);

        // llama_decode handles the embedding forward pass; for encoder-only
        // models (BERT/nomic-bert) it logs a benign "calling encode() instead"
        // info line and routes internally. We tolerate the noise.
        if (c.llama_decode(self.ctx, batch) != 0) return Error.DecodeFailed;

        const emb_ptr = c.llama_get_embeddings_seq(self.ctx, 0);
        if (emb_ptr == null) return Error.EmbeddingsUnavailable;

        const out = try gpa.alloc(f32, self.dim);
        @memcpy(out, emb_ptr[0..self.dim]);

        // L2 normalize so cosine-similarity reduces to a dot product.
        var sum: f32 = 0;
        for (out) |v| sum += v * v;
        const norm = std.math.sqrt(sum);
        if (norm > 0) {
            for (out) |*v| v.* /= norm;
        }
        return out;
    }
};

// ---- Tests ----
//
// These run only when `$MEMLITE_TEST_MODEL` points at a GGUF file (so CI
// without a model just sees a skip). The default invocation is to point
// it at the cached nomic-embed model written by §6's first-run path.

const testing = std.testing;

fn testModelPath() ?[:0]const u8 {
    const env = std.c.getenv("MEMLITE_TEST_MODEL") orelse return null;
    return std.mem.span(env);
}

test "embed returns dim-N L2-normalized vector; similar texts cosine-correlate" {
    const path = testModelPath() orelse return error.SkipZigTest;

    model_mod.initBackend();
    defer model_mod.deinitBackend();

    var model = try model_mod.Model.loadFromFile(path, .{ .quiet = true });
    defer model.deinit();

    var emb = try Embedder.init(model);
    defer emb.deinit();
    try testing.expectEqual(@as(u32, 768), emb.dim);

    const a = try emb.embed(testing.allocator, "milk no sugar, please");
    defer testing.allocator.free(a);
    const b = try emb.embed(testing.allocator, "I take my tea with milk and no sugar");
    defer testing.allocator.free(b);
    const c_unrelated = try emb.embed(testing.allocator, "the quick brown fox jumps over the lazy dog");
    defer testing.allocator.free(c_unrelated);

    try testing.expectEqual(emb.dim, @as(u32, @intCast(a.len)));

    // L2 norm ≈ 1.
    var norm_a: f32 = 0;
    for (a) |v| norm_a += v * v;
    try testing.expectApproxEqAbs(@as(f32, 1.0), norm_a, 0.001);

    // Cosine similarity (a·b) for related strings should exceed (a·c).
    var sim_ab: f32 = 0;
    var sim_ac: f32 = 0;
    for (a, b, c_unrelated) |x, y, z| {
        sim_ab += x * y;
        sim_ac += x * z;
    }
    try testing.expect(sim_ab > sim_ac);
}
