//! SQLite connection lifecycle, schema bootstrap, and settings I/O.
//!
//! v1-foundation §4. Schema lives in src/schema.sql and is applied verbatim
//! on first run (with the embedding dimension substituted into the vec0
//! virtual-table declaration). Subsequent runs only register the sqlite-vec
//! module on the new connection — the schema is already in sqlite_master.

const std = @import("std");

pub const c = @cImport({
    @cDefine("SQLITE_CORE", "1");
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

const Allocator = std.mem.Allocator;

pub const Error = error{
    SqliteOpenFailed,
    SqliteVecInitFailed,
    SqliteExecFailed,
    SqlitePrepareFailed,
    SqliteStepFailed,
    SqliteBindFailed,
} || Allocator.Error;

const schema_template = @embedFile("schema.sql");

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open or create the DB at `path`. Pass `":memory:"` for an ephemeral
    /// in-process database (used by tests).
    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }
        var db: Db = .{ .handle = handle.? };
        errdefer db.close();
        try db.applyPragmas();
        if (c.sqlite3_vec_init(db.handle, null, null) != c.SQLITE_OK) {
            return error.SqliteVecInitFailed;
        }
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Returns true if the schema has not yet been applied (i.e. the
    /// `memories` table is absent).
    pub fn isFresh(self: *Db) Error!bool {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='memories';";
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStepFailed;
        return c.sqlite3_column_int(stmt, 0) == 0;
    }

    /// Apply the schema and write the two required settings rows. Idempotent
    /// is NOT promised — call only when `isFresh()` returned true.
    pub fn initSchema(
        self: *Db,
        gpa: Allocator,
        embedding_dim: u32,
        model_url: []const u8,
    ) Error!void {
        var dim_buf: [16]u8 = undefined;
        const dim_str = std.fmt.bufPrint(&dim_buf, "{d}", .{embedding_dim}) catch unreachable;

        const replaced = try std.mem.replaceOwned(u8, gpa, schema_template, "{DIM}", dim_str);
        defer gpa.free(replaced);
        const sql_z = try gpa.dupeZ(u8, replaced);
        defer gpa.free(sql_z);
        try self.exec(sql_z);

        try self.setSetting("model_url", model_url);
        try self.setSetting("embedding_dim", dim_str);
    }

    pub fn setSetting(self: *Db, key: []const u8, value: []const u8) Error!void {
        const sql = "INSERT INTO settings(key, value) VALUES (?, ?) " ++
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// Caller owns the returned slice (allocated with `gpa`). Returns null
    /// if the key is absent.
    pub fn getSetting(self: *Db, gpa: Allocator, key: []const u8) Error!?[]u8 {
        const sql = "SELECT value FROM settings WHERE key = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK) return error.SqliteBindFailed;
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
        const ptr = c.sqlite3_column_text(stmt, 0) orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const out = try gpa.alloc(u8, len);
        @memcpy(out, ptr[0..len]);
        return out;
    }

    fn applyPragmas(self: *Db) Error!void {
        try self.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA temp_store = MEMORY;
        );
    }

    fn exec(self: *Db, sql: [:0]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                std.log.err("sqlite: {s}", .{errmsg});
                c.sqlite3_free(errmsg);
            }
            return error.SqliteExecFailed;
        }
    }
};

// ---- Tests ----

const testing = std.testing;

test "fresh in-memory DB initializes schema and writes settings" {
    var db = try Db.open(":memory:");
    defer db.close();

    try testing.expect(try db.isFresh());

    const url = "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf";
    try db.initSchema(testing.allocator, 768, url);

    try testing.expect(!(try db.isFresh()));

    const stored_url = (try db.getSetting(testing.allocator, "model_url")) orelse return error.MissingSetting;
    defer testing.allocator.free(stored_url);
    try testing.expectEqualStrings(url, stored_url);

    const stored_dim = (try db.getSetting(testing.allocator, "embedding_dim")) orelse return error.MissingSetting;
    defer testing.allocator.free(stored_dim);
    try testing.expectEqualStrings("768", stored_dim);
}

test "delete trigger snapshots memory + tags into history" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema(testing.allocator, 4, "test://model");

    try db.exec(
        \\INSERT INTO memories(slug, content, created, updated, last_accessed)
        \\VALUES ('user-tea-pref', 'milk no sugar', 1000, 1000, 1000);
        \\INSERT INTO tags(memory_id, key, value) VALUES
        \\  (1, 'kind', 'preference'),
        \\  (1, 'source', 'claude'),
        \\  (1, 'lang', 'en');
        \\INSERT INTO chunks(memory_id, ord, text) VALUES (1, 0, 'milk no sugar');
        \\INSERT INTO vec_chunks(rowid, embedding) VALUES (1, X'0000803F000000400000404000008040');
        \\DELETE FROM memories WHERE id = 1;
    );

    // History row created with the snapshot.
    var stmt: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(
        db.handle,
        "SELECT slug, content, archive_reason, tags_snapshot FROM memories_history WHERE memory_id = 1;",
        -1,
        &stmt,
        null,
    ));
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    try testing.expectEqualStrings("user-tea-pref", std.mem.span(c.sqlite3_column_text(stmt, 0)));
    try testing.expectEqualStrings("milk no sugar", std.mem.span(c.sqlite3_column_text(stmt, 1)));
    try testing.expectEqualStrings("deleted", std.mem.span(c.sqlite3_column_text(stmt, 2)));
    // tags_snapshot is `{key: [values...]}` — parse to confirm shape.
    const snap = std.mem.span(c.sqlite3_column_text(stmt, 3));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snap, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("kind").?.array.items[0].string.len > 0);

    // Cascades fired: chunks, tags, vec_chunks all empty.
    try expectScalarInt(db.handle, "SELECT count(*) FROM chunks;", 0);
    try expectScalarInt(db.handle, "SELECT count(*) FROM tags;", 0);
    try expectScalarInt(db.handle, "SELECT count(*) FROM fts_chunks;", 0);
    try expectScalarInt(db.handle, "SELECT count(*) FROM vec_chunks;", 0);
}

test "content update snapshots history, but slug-only/tag-only updates do not" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema(testing.allocator, 4, "test://model");

    try db.exec(
        \\INSERT INTO memories(slug, content, created, updated, last_accessed)
        \\VALUES ('x', 'v1', 1, 1, 1);
        \\UPDATE memories SET slug = 'y' WHERE id = 1;
        \\UPDATE memories SET content = 'v2' WHERE id = 1;
    );
    try expectScalarInt(db.handle, "SELECT count(*) FROM memories_history;", 1);
    try expectScalarInt(
        db.handle,
        "SELECT count(*) FROM memories_history WHERE archive_reason = 'updated' AND content = 'v1';",
        1,
    );
}

fn expectScalarInt(handle: *c.sqlite3, sql: [:0]const u8, expected: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(handle, sql.ptr, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    try testing.expectEqual(expected, c.sqlite3_column_int64(stmt, 0));
}
