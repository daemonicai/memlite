const std = @import("std");
const mcp = @import("mcp.zig");
const db_mod = @import("db.zig");

/// Hardcoded default until §6 introduces real CLI flags and model
/// resolution. The dimension matches DEFAULT_EMBEDDING_DIM.
const DEFAULT_MODEL_URL =
    "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const db_path = try resolveDbPath(arena, init);
    var db = try db_mod.Db.open(db_path);
    defer db.close();

    if (try db.isFresh()) {
        std.log.info("memlite: initializing fresh DB at {s}", .{db_path});
        try db.initSchema(gpa, db_mod.DEFAULT_EMBEDDING_DIM, DEFAULT_MODEL_URL);
    }

    var stdin_buf: [4 * 1024 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);

    try mcp.serve(gpa, &stdin_reader.interface, &stdout_writer.interface);
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
}
