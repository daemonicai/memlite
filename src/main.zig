const std = @import("std");
const mcp = @import("mcp.zig");
const db_mod = @import("db.zig");
const model_url_mod = @import("model_url.zig");
const download_mod = @import("download.zig");
const model_mod = @import("model.zig");
const embed_mod = @import("embed.zig");
const tools_mod = @import("tools.zig");

/// Default model URL — §6 spec. Stored in `settings('model_url')` on first
/// init; subsequent runs must pass the same URL or get MODEL_MISMATCH.
const DEFAULT_MODEL_URL =
    "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const cli = try parseArgs(args);

    const parsed_url = model_url_mod.parse(cli.model_url) catch |err| {
        std.log.err("memlite: invalid --model URL ({s}): {s}", .{ cli.model_url, @errorName(err) });
        return err;
    };

    const home = init.environ_map.get("HOME") orelse {
        std.log.err("memlite: $HOME not set; cannot derive cache path", .{});
        return error.NoHome;
    };
    const cache_path = try model_url_mod.cachePathZ(arena, home, parsed_url);

    // Open the DB first so a MODEL_MISMATCH fails fast — before any
    // bytes get downloaded or a wrong-dim model gets loaded.
    const db_path = try resolveDbPath(arena, init);
    var db = try db_mod.Db.open(db_path);
    defer db.close();
    const db_fresh = try db.isFresh();
    if (!db_fresh) try verifyModelMatchesDb(&db, gpa, parsed_url.raw);

    try ensureModelCached(gpa, io, arena, cache_path, parsed_url.raw);

    model_mod.initBackend();
    defer model_mod.deinitBackend();

    var model = model_mod.Model.loadFromFile(cache_path) catch |err| {
        std.log.err("memlite: failed to load model {s}: {s}", .{ cache_path, @errorName(err) });
        return err;
    };
    defer model.deinit();
    const embedding_dim = model.embeddingDim();

    if (db_fresh) {
        std.log.info("memlite: initializing DB at {s} (dim={d})", .{ db_path, embedding_dim });
        try db.initSchema(gpa, embedding_dim, parsed_url.raw);
    }

    var embedder = try embed_mod.Embedder.init(model);
    defer embedder.deinit();

    var tools = tools_mod.Tools.init(&db, &embedder);

    var stdin_buf: [4 * 1024 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);

    try mcp.serve(gpa, &stdin_reader.interface, &stdout_writer.interface, &tools);
}

const Cli = struct {
    model_url: []const u8,
};

/// Minimal CLI: optional `serve` subcommand, optional `--model URL`. The
/// full surface (init, dump, --db, etc.) arrives in §12.
fn parseArgs(args: []const [:0]const u8) !Cli {
    var model_url: []const u8 = DEFAULT_MODEL_URL;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "serve")) continue;
        if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("memlite: --model needs a URL", .{});
                return error.MissingArgValue;
            }
            model_url = args[i];
            continue;
        }
        std.log.warn("memlite: ignoring unknown arg {s} (full CLI in §12)", .{a});
    }
    return .{ .model_url = model_url };
}

fn ensureModelCached(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    cache_path: [:0]const u8,
    url: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, cache_path, .{})) |_| {
        std.log.info("memlite: model cached at {s}", .{cache_path});
        return;
    } else |_| {}

    const cache_dir = std.fs.path.dirname(cache_path) orelse return error.BadCachePath;
    try cwd.createDirPath(io, cache_dir);
    const dir_z = try arena.dupeZ(u8, cache_dir);
    _ = dir_z;
    var dir = try cwd.openDir(io, cache_dir, .{});
    defer dir.close(io);
    const basename = std.fs.path.basename(cache_path);
    try download_mod.download(gpa, io, url, dir, basename);
}

fn verifyModelMatchesDb(db: *db_mod.Db, gpa: std.mem.Allocator, url: []const u8) !void {
    const stored = (try db.getSetting(gpa, "model_url")) orelse {
        std.log.err("memlite: DB is initialized but model_url setting is missing", .{});
        return error.MissingModelUrlSetting;
    };
    defer gpa.free(stored);
    if (!std.mem.eql(u8, stored, url)) {
        std.log.err(
            "memlite: MODEL_MISMATCH — requested model URL does not match the DB.\n  requested: {s}\n  in DB:     {s}\n  Either pass --model with the URL the DB was initialized with, or delete the DB to start over.",
            .{ url, stored },
        );
        return error.ModelMismatch;
    }
}

/// Resolve the DB path:
///   1. $MEMLITE_DB (used by tests / dev), or
///   2. ~/.memlite/memlite.db (and create ~/.memlite/ if absent).
/// CLI flags will replace this in §12.
fn resolveDbPath(arena: std.mem.Allocator, init: std.process.Init) ![:0]const u8 {
    if (init.environ_map.get("MEMLITE_DB")) |env_val| {
        return try arena.dupeZ(u8, env_val);
    }
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const dir = try std.fs.path.joinZ(arena, &.{ home, ".memlite" });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    return try std.fs.path.joinZ(arena, &.{ home, ".memlite", "memlite.db" });
}

test {
    std.testing.refAllDecls(@This());
    _ = mcp;
    _ = db_mod;
    _ = @import("model_url.zig");
    _ = @import("download.zig");
    _ = @import("model.zig");
    _ = @import("embed.zig");
    _ = @import("tools.zig");
    _ = @import("chunk.zig");
}
