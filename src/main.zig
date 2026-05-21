const std = @import("std");
const mcp = @import("mcp.zig");
const db_mod = @import("db.zig");
const model_url_mod = @import("model_url.zig");
const download_mod = @import("download.zig");
const model_mod = @import("model.zig");
const embed_mod = @import("embed.zig");
const tools_mod = @import("tools.zig");

const c = db_mod.c;

/// Default model URL — §6 spec. Stored in `settings('model_url')` on first
/// init; subsequent runs must pass the same URL or get MODEL_MISMATCH.
const DEFAULT_MODEL_URL =
    "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf";

const Subcommand = enum { serve, init, dump };

const Cli = struct {
    subcommand: Subcommand = .serve,
    db_path: ?[]const u8 = null,
    model_url: []const u8 = DEFAULT_MODEL_URL,
};

pub fn main(init_args: std.process.Init) !void {
    const arena = init_args.arena.allocator();
    const args = try init_args.minimal.args.toSlice(arena);
    const cli = try parseArgs(args);

    switch (cli.subcommand) {
        .serve => try runServe(init_args, cli),
        .init => try runInit(init_args, cli),
        .dump => try runDump(init_args, cli),
    }
}

fn parseArgs(args: []const [:0]const u8) !Cli {
    var cli: Cli = .{};
    var i: usize = 1;
    var saw_subcommand = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--db")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("memlite: --db needs a path", .{});
                return error.MissingArgValue;
            }
            cli.db_path = args[i];
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("memlite: --model needs a URL", .{});
                return error.MissingArgValue;
            }
            cli.model_url = args[i];
        } else if (!saw_subcommand and std.mem.eql(u8, a, "serve")) {
            cli.subcommand = .serve;
            saw_subcommand = true;
        } else if (!saw_subcommand and std.mem.eql(u8, a, "init")) {
            cli.subcommand = .init;
            saw_subcommand = true;
        } else if (!saw_subcommand and std.mem.eql(u8, a, "dump")) {
            cli.subcommand = .dump;
            saw_subcommand = true;
        } else {
            std.log.err("memlite: unknown arg: {s}", .{a});
            printUsage();
            return error.UnknownArg;
        }
    }
    return cli;
}

fn printUsage() void {
    const text =
        \\Usage: memlite [serve|init|dump] [options]
        \\
        \\Subcommands:
        \\  serve   (default) Open the DB, ensure the model, and run the MCP loop.
        \\  init    Open/create the DB, download the model if missing, write
        \\          settings, then exit. Useful for first-run setup separate
        \\          from running the MCP server.
        \\  dump    Open the DB read-only and write all rows as NDJSON to stdout
        \\          (one JSON object per line, with a `_table` discriminator).
        \\
        \\Options:
        \\  --db PATH       Override the DB path. Default: $MEMLITE_DB or
        \\                  ~/.memlite/memlite.db
        \\  --model URL     HuggingFace `/resolve/` URL of the GGUF embedding
        \\                  model. Pinned in settings on first init; subsequent
        \\                  runs must match.
        \\  -h, --help      Show this help.
        \\
    ;
    std.debug.print("{s}", .{text});
}

// =====================================================================
// Subcommands
// =====================================================================

fn runServe(init_args: std.process.Init, cli: Cli) !void {
    const io = init_args.io;
    const gpa = init_args.gpa;
    const arena = init_args.arena.allocator();

    const setup = try setupSession(init_args, cli, .open_existing_or_init);

    var db = setup.db;
    defer db.close();

    var model = setup.model;
    defer model.deinit();
    defer model_mod.deinitBackend();

    var embedder = try embed_mod.Embedder.init(model);
    defer embedder.deinit();

    var tools = tools_mod.Tools.init(&db, &embedder, io);
    _ = arena;

    var stdin_buf: [4 * 1024 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);

    try mcp.serve(gpa, &stdin_reader.interface, &stdout_writer.interface, &tools);
}

fn runInit(init_args: std.process.Init, cli: Cli) !void {
    var setup = try setupSession(init_args, cli, .open_existing_or_init);
    setup.db.close();
    setup.model.deinit();
    model_mod.deinitBackend();
    std.log.info("memlite: init complete (db_path={s})", .{setup.db_path});
}

fn runDump(init_args: std.process.Init, cli: Cli) !void {
    const io = init_args.io;
    const gpa = init_args.gpa;
    const arena = init_args.arena.allocator();

    const db_path = try resolveDbPath(arena, init_args, cli);

    var db = try db_mod.Db.open(db_path);
    defer db.close();

    if (try db.isFresh()) {
        std.log.err("memlite: dump: DB at {s} is empty / uninitialized", .{db_path});
        return error.DbNotInitialized;
    }

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;

    try dumpTable(out, &db,
        "SELECT id, slug, format, content, created, updated, last_accessed FROM memories ORDER BY id;",
        "memories",
        &.{ "id", "slug", "format", "content", "created", "updated", "last_accessed" },
        &.{ .int, .text_or_null, .text, .text, .int, .int, .int },
    );
    try dumpTable(out, &db,
        "SELECT id, memory_id, ord, text FROM chunks ORDER BY id;",
        "chunks",
        &.{ "id", "memory_id", "ord", "text" },
        &.{ .int, .int, .int, .text },
    );
    try dumpTable(out, &db,
        "SELECT memory_id, key, value FROM tags ORDER BY memory_id, key, value;",
        "tags",
        &.{ "memory_id", "key", "value" },
        &.{ .int, .text, .text },
    );
    try dumpTable(out, &db,
        "SELECT id, memory_id, slug, format, content, tags_snapshot, created, updated, last_accessed, archived_at, archive_reason FROM memories_history ORDER BY id;",
        "memories_history",
        &.{ "id", "memory_id", "slug", "format", "content", "tags_snapshot_raw", "created", "updated", "last_accessed", "archived_at", "archive_reason" },
        &.{ .int, .int, .text_or_null, .text, .text, .text, .int, .int, .int, .int, .text },
    );
    try dumpTable(out, &db,
        "SELECT key, value FROM settings ORDER BY key;",
        "settings",
        &.{ "key", "value" },
        &.{ .text, .text },
    );

    try out.flush();
    _ = gpa;
}

const Setup = struct {
    db: db_mod.Db,
    model: model_mod.Model,
    db_path: [:0]const u8,
};

const SetupMode = enum { open_existing_or_init };

/// Shared setup path between `serve` and `init` — open the DB, verify or
/// initialize the model link, ensure the model is cached + loaded.
fn setupSession(init_args: std.process.Init, cli: Cli, mode: SetupMode) !Setup {
    _ = mode;
    const io = init_args.io;
    const gpa = init_args.gpa;
    const arena = init_args.arena.allocator();

    const parsed_url = model_url_mod.parse(cli.model_url) catch |err| {
        std.log.err("memlite: invalid --model URL ({s}): {s}", .{ cli.model_url, @errorName(err) });
        return err;
    };

    const home = init_args.environ_map.get("HOME") orelse {
        std.log.err("memlite: $HOME not set; cannot derive cache path", .{});
        return error.NoHome;
    };
    const cache_path = try model_url_mod.cachePathZ(arena, home, parsed_url);

    const db_path = try resolveDbPath(arena, init_args, cli);

    var db = try db_mod.Db.open(db_path);
    errdefer db.close();
    const db_fresh = try db.isFresh();
    if (!db_fresh) try verifyModelMatchesDb(&db, gpa, parsed_url.raw);

    try ensureModelCached(gpa, io, arena, cache_path, parsed_url.raw);

    model_mod.initBackend();
    errdefer model_mod.deinitBackend();

    var model = model_mod.Model.loadFromFile(cache_path) catch |err| {
        std.log.err("memlite: failed to load model {s}: {s}", .{ cache_path, @errorName(err) });
        return err;
    };
    errdefer model.deinit();
    const embedding_dim = model.embeddingDim();

    if (db_fresh) {
        std.log.info("memlite: initializing DB at {s} (dim={d})", .{ db_path, embedding_dim });
        try db.initSchema(gpa, embedding_dim, parsed_url.raw);
    }

    return .{ .db = db, .model = model, .db_path = db_path };
}

// =====================================================================
// Helpers
// =====================================================================

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

/// Resolve the DB path: --db wins, then $MEMLITE_DB, then ~/.memlite/memlite.db.
fn resolveDbPath(arena: std.mem.Allocator, init_args: std.process.Init, cli: Cli) ![:0]const u8 {
    if (cli.db_path) |p| return try arena.dupeZ(u8, p);
    if (init_args.environ_map.get("MEMLITE_DB")) |env_val| {
        return try arena.dupeZ(u8, env_val);
    }
    const home = init_args.environ_map.get("HOME") orelse return error.NoHome;
    const dir = try std.fs.path.joinZ(arena, &.{ home, ".memlite" });
    try std.Io.Dir.cwd().createDirPath(init_args.io, dir);
    return try std.fs.path.joinZ(arena, &.{ home, ".memlite", "memlite.db" });
}

// ---- dump helpers ---------------------------------------------------

const DumpType = enum { int, text, text_or_null };

fn dumpTable(
    out: *std.Io.Writer,
    db: *db_mod.Db,
    sql: [:0]const u8,
    table: []const u8,
    columns: []const []const u8,
    types: []const DumpType,
) !void {
    std.debug.assert(columns.len == types.len);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;

        var s: std.json.Stringify = .{ .writer = out };
        try s.beginObject();
        try s.objectField("_table");
        try s.write(table);
        for (columns, types, 0..) |name, ty, idx| {
            try s.objectField(name);
            const col: c_int = @intCast(idx);
            switch (ty) {
                .int => try s.write(c.sqlite3_column_int64(stmt, col)),
                .text => {
                    const ptr = c.sqlite3_column_text(stmt, col);
                    if (ptr == null) try s.write(null) else try s.write(std.mem.span(ptr));
                },
                .text_or_null => {
                    const ptr = c.sqlite3_column_text(stmt, col);
                    if (ptr == null) try s.write(null) else try s.write(std.mem.span(ptr));
                },
            }
        }
        try s.endObject();
        try out.writeByte('\n');
    }
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
