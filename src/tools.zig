//! High-level MCP tool implementations.
//!
//! v1-foundation §8. Owns the live Db + Embedder for the process. Each tool
//! is a thin orchestration layer over SQL: parse a request, run the
//! transactional sequence the schema expects, return a typed result. mcp.zig
//! sits on top and turns results / errors into JSON-RPC frames.
//!
//! All SQL is written here rather than in db.zig so db.zig stays focused
//! on connection lifecycle and the schema bootstrap.

const std = @import("std");
const db_mod = @import("db.zig");
const embed_mod = @import("embed.zig");
const chunk_mod = @import("chunk.zig");

const c = db_mod.c;
const Allocator = std.mem.Allocator;
const Db = db_mod.Db;
const Embedder = embed_mod.Embedder;

/// Stable application-level errors. Maps 1:1 with the v1 vocabulary in
/// mcp.AppError; tools.zig stays unaware of the JSON-RPC layer.
pub const Error = error{
    SlugExists,
    NotFound,
    InvalidTarget,
    InvalidFormat,
    EmbeddingFailed,
    Sqlite,
} || Allocator.Error;

pub const Target = union(enum) {
    id: i64,
    slug: []const u8,
};

/// `tags: {key: string | [string...]}` shape from MCP arguments, already
/// normalized to a flat list of (key, value) pairs.
pub const TagPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Tools = struct {
    db: *Db,
    embedder: *Embedder,

    pub fn init(db: *Db, embedder: *Embedder) Tools {
        return .{ .db = db, .embedder = embedder };
    }

    // ---- memory_add ---------------------------------------------------

    pub const AddArgs = struct {
        content: []const u8,
        format: []const u8 = "text",
        slug: ?[]const u8 = null,
        tags: []const TagPair = &.{},
    };

    pub const AddResult = struct {
        id: i64,
        slug: ?[]const u8,
        format: []const u8,
        chunks_created: u32,
        tags_created: u32,
    };

    pub fn memoryAdd(self: *Tools, gpa: Allocator, args: AddArgs) Error!AddResult {
        if (!isValidFormat(args.format)) return Error.InvalidFormat;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        const chunks = try splitContent(aa, args.format, args.content);
        const embeddings = try aa.alloc([]f32, chunks.len);
        for (chunks, 0..) |ck, i| {
            embeddings[i] = self.embedder.embed(aa, ck) catch return Error.EmbeddingFailed;
        }

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        const id = try self.insertMemory(args.slug, args.format, args.content);
        for (chunks, embeddings, 0..) |ck, emb, i| {
            const chunk_id = try self.insertChunk(id, @intCast(i), ck);
            try self.insertVecChunk(chunk_id, emb);
        }

        var tags_created: u32 = 0;
        for (args.tags) |t| {
            try self.insertTagIdempotent(id, t.key, t.value);
            tags_created += 1;
        }

        try self.exec("COMMIT;");
        return .{
            .id = id,
            .slug = args.slug,
            .format = args.format,
            .chunks_created = @intCast(chunks.len),
            .tags_created = tags_created,
        };
    }

    // ---- memory_get ---------------------------------------------------

    pub const GetResult = struct {
        id: i64,
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
        /// JSON document `{key: [values…]}` — already serialized by SQLite.
        tags_json: []const u8,
        created: i64,
        updated: i64,
        last_accessed: i64,
    };

    pub fn memoryGet(self: *Tools, gpa: Allocator, target: Target) Error!GetResult {
        const id = try self.resolveTarget(target);

        try self.exec("BEGIN;");
        errdefer self.exec("ROLLBACK;") catch {};

        // Bump last_accessed before the read so the caller sees the fresh value.
        try self.bumpLastAccessed(id);

        const sql = "SELECT id, slug, format, content, created, updated, last_accessed FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;

        const slug_text = c.sqlite3_column_text(stmt, 1);
        const slug: ?[]const u8 = if (slug_text == null) null else try gpa.dupe(u8, std.mem.span(slug_text));

        const fmt = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2).?));
        const content = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3).?));
        const created = c.sqlite3_column_int64(stmt, 4);
        const updated = c.sqlite3_column_int64(stmt, 5);
        const last_accessed = c.sqlite3_column_int64(stmt, 6);

        const tags_json = try self.fetchTagsJson(gpa, id);

        try self.exec("COMMIT;");
        return .{
            .id = id,
            .slug = slug,
            .format = fmt,
            .content = content,
            .tags_json = tags_json,
            .created = created,
            .updated = updated,
            .last_accessed = last_accessed,
        };
    }

    // ---- memory_delete -----------------------------------------------

    pub const DeleteResult = struct { id: i64, history_id: i64 };

    pub fn memoryDelete(self: *Tools, target: Target) Error!DeleteResult {
        const id = try self.resolveTarget(target);

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        // memories_history.id is AUTOINCREMENT, so the row created by the
        // BEFORE DELETE trigger will use last_insert_rowid() after DELETE.
        const sql = "DELETE FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        if (c.sqlite3_changes(self.db.handle) == 0) {
            // Pre-check via resolveTarget should have caught this, but
            // belt-and-braces in case of a TOCTOU race.
            return Error.NotFound;
        }

        const history_id = c.sqlite3_last_insert_rowid(self.db.handle);
        try self.exec("COMMIT;");
        return .{ .id = id, .history_id = history_id };
    }

    // ---- memory_clear -------------------------------------------------

    pub const ClearResult = struct { removed_count: i64, history_kept: bool };

    pub fn memoryClear(self: *Tools, retain_history: bool) Error!ClearResult {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        // Snapshot count before the wipe.
        const removed = try self.scalarInt64("SELECT count(*) FROM memories;");

        // DELETE per row so the BEFORE DELETE trigger fires and history is
        // populated. A TRUNCATE-equivalent (DELETE without WHERE) does fire
        // row-level triggers in SQLite, but spelling it out matches intent.
        try self.exec("DELETE FROM memories;");

        if (!retain_history) {
            try self.exec("DELETE FROM memories_history;");
        }

        try self.exec("COMMIT;");
        return .{ .removed_count = removed, .history_kept = retain_history };
    }

    // ---- memory_update ------------------------------------------------

    pub const UpdateArgs = struct {
        content: ?[]const u8 = null,
        format: ?[]const u8 = null,
        slug: ?SlugChange = null,
        tags: ?[]const TagPair = null, // null = leave tags; non-null = full replace
    };

    /// Slug update intent — distinct from `null` (no change) and an empty
    /// slug string (explicit clear).
    pub const SlugChange = union(enum) {
        clear, // null slug
        set: []const u8,
    };

    pub const UpdateResult = struct {
        id: i64,
        chunks_replaced: bool,
        tags_replaced: bool,
    };

    pub fn memoryUpdate(
        self: *Tools,
        gpa: Allocator,
        target: Target,
        args: UpdateArgs,
    ) Error!UpdateResult {
        const id = try self.resolveTarget(target);

        const new_format_opt: ?[]const u8 = args.format;
        if (new_format_opt) |f| {
            if (!isValidFormat(f)) return Error.InvalidFormat;
        }

        const content_changed = args.content != null;
        const format_changed = new_format_opt != null;
        const rechunk = content_changed or format_changed;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        // Compute new chunks + embeddings outside the transaction so an
        // embed failure doesn't leave a half-open one.
        var new_chunks: []const []const u8 = &.{};
        var new_embeddings: [][]f32 = &.{};
        if (rechunk) {
            const effective_format = new_format_opt orelse try self.fetchFormat(aa, id);
            const effective_content = if (content_changed) args.content.? else try self.fetchContent(aa, id);
            new_chunks = try splitContent(aa, effective_format, effective_content);
            new_embeddings = try aa.alloc([]f32, new_chunks.len);
            for (new_chunks, 0..) |ck, i| {
                new_embeddings[i] = self.embedder.embed(aa, ck) catch return Error.EmbeddingFailed;
            }
        }

        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        if (args.slug) |sc| {
            try self.applySlugChange(id, sc);
        }

        if (format_changed and !content_changed) {
            try self.execBindId("UPDATE memories SET format = ?, updated = unixepoch() WHERE id = ?;", new_format_opt.?, id);
        }

        if (content_changed) {
            try self.applyContentUpdate(id, args.content.?, new_format_opt);
        }

        var chunks_replaced = false;
        if (rechunk) {
            try self.deleteChunksFor(id);
            for (new_chunks, new_embeddings, 0..) |ck, emb, i| {
                const new_chunk_id = try self.insertChunk(id, @intCast(i), ck);
                try self.insertVecChunk(new_chunk_id, emb);
            }
            chunks_replaced = true;
        }

        var tags_replaced = false;
        if (args.tags) |new_tags| {
            try self.execBindOnlyId("DELETE FROM tags WHERE memory_id = ?;", id);
            for (new_tags) |t| try self.insertTagIdempotent(id, t.key, t.value);
            tags_replaced = true;
        }

        try self.exec("COMMIT;");
        return .{ .id = id, .chunks_replaced = chunks_replaced, .tags_replaced = tags_replaced };
    }

    // ---- memory_tag / memory_untag -----------------------------------

    pub const TagResult = struct { id: i64, idempotent: bool };

    pub fn memoryTag(self: *Tools, target: Target, key: []const u8, value: []const u8) Error!TagResult {
        const id = try self.resolveTarget(target);

        const sql = "INSERT OR IGNORE INTO tags(memory_id, key, value) VALUES (?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        try sqliteOk(c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 3, value.ptr, @intCast(value.len), null));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        return .{ .id = id, .idempotent = c.sqlite3_changes(self.db.handle) == 0 };
    }

    pub const UntagResult = struct { id: i64, removed_count: i64 };

    pub fn memoryUntag(
        self: *Tools,
        target: Target,
        key: []const u8,
        value: ?[]const u8,
    ) Error!UntagResult {
        const id = try self.resolveTarget(target);

        if (value) |v| {
            const sql = "DELETE FROM tags WHERE memory_id = ? AND key = ? AND value = ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
            defer _ = c.sqlite3_finalize(stmt);
            try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
            try sqliteOk(c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), null));
            try sqliteOk(c.sqlite3_bind_text(stmt, 3, v.ptr, @intCast(v.len), null));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        } else {
            const sql = "DELETE FROM tags WHERE memory_id = ? AND key = ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
            defer _ = c.sqlite3_finalize(stmt);
            try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
            try sqliteOk(c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), null));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        }
        return .{ .id = id, .removed_count = c.sqlite3_changes(self.db.handle) };
    }

    // =====================================================================
    // Private helpers
    // =====================================================================

    fn resolveTarget(self: *Tools, target: Target) Error!i64 {
        return switch (target) {
            .id => |id| if (try self.memoryExists(id)) id else Error.NotFound,
            .slug => |slug| try self.idForSlug(slug),
        };
    }

    fn memoryExists(self: *Tools, id: i64) Error!bool {
        const sql = "SELECT 1 FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        const rc = c.sqlite3_step(stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => Error.Sqlite,
        };
    }

    fn idForSlug(self: *Tools, slug: []const u8) Error!i64 {
        const sql = "SELECT id FROM memories WHERE slug = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_text(stmt, 1, slug.ptr, @intCast(slug.len), null));
        const rc = c.sqlite3_step(stmt);
        return switch (rc) {
            c.SQLITE_ROW => c.sqlite3_column_int64(stmt, 0),
            c.SQLITE_DONE => Error.NotFound,
            else => Error.Sqlite,
        };
    }

    fn insertMemory(
        self: *Tools,
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
    ) Error!i64 {
        const sql =
            \\INSERT INTO memories (slug, format, content, created, updated, last_accessed)
            \\VALUES (?, ?, ?, unixepoch(), unixepoch(), unixepoch());
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);

        if (slug) |s| {
            try sqliteOk(c.sqlite3_bind_text(stmt, 1, s.ptr, @intCast(s.len), null));
        } else {
            try sqliteOk(c.sqlite3_bind_null(stmt, 1));
        }
        try sqliteOk(c.sqlite3_bind_text(stmt, 2, format.ptr, @intCast(format.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 3, content.ptr, @intCast(content.len), null));

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            // sqlite3_extended_errcode lets us distinguish UNIQUE failures
            // on slug from other sqlite errors.
            const ext = c.sqlite3_extended_errcode(self.db.handle);
            if (ext == c.SQLITE_CONSTRAINT_UNIQUE) return Error.SlugExists;
            return Error.Sqlite;
        }
        return c.sqlite3_last_insert_rowid(self.db.handle);
    }

    fn insertChunk(self: *Tools, memory_id: i64, ord: i64, text: []const u8) Error!i64 {
        const sql = "INSERT INTO chunks (memory_id, ord, text) VALUES (?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, memory_id));
        try sqliteOk(c.sqlite3_bind_int64(stmt, 2, ord));
        try sqliteOk(c.sqlite3_bind_text(stmt, 3, text.ptr, @intCast(text.len), null));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        return c.sqlite3_last_insert_rowid(self.db.handle);
    }

    fn insertVecChunk(self: *Tools, chunk_id: i64, embedding: []const f32) Error!void {
        const sql = "INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, chunk_id));
        const bytes = std.mem.sliceAsBytes(embedding);
        try sqliteOk(c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), null));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn insertTagIdempotent(self: *Tools, memory_id: i64, key: []const u8, value: []const u8) Error!void {
        const sql = "INSERT OR IGNORE INTO tags(memory_id, key, value) VALUES (?, ?, ?);";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, memory_id));
        try sqliteOk(c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 3, value.ptr, @intCast(value.len), null));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn fetchTagsJson(self: *Tools, gpa: Allocator, id: i64) Error![]const u8 {
        const sql =
            \\SELECT IFNULL(
            \\  (SELECT json_group_object(key, json(vals)) FROM (
            \\    SELECT key, json_group_array(value) AS vals
            \\    FROM tags WHERE memory_id = ?
            \\    GROUP BY key
            \\  )),
            \\  '{}'
            \\);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.Sqlite;
        const text_ptr = c.sqlite3_column_text(stmt, 0) orelse return Error.Sqlite;
        return try gpa.dupe(u8, std.mem.span(text_ptr));
    }

    fn fetchFormat(self: *Tools, gpa: Allocator, id: i64) Error![]const u8 {
        const sql = "SELECT format FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        const ptr = c.sqlite3_column_text(stmt, 0) orelse return Error.Sqlite;
        return try gpa.dupe(u8, std.mem.span(ptr));
    }

    fn fetchContent(self: *Tools, gpa: Allocator, id: i64) Error![]const u8 {
        const sql = "SELECT content FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        const ptr = c.sqlite3_column_text(stmt, 0) orelse return Error.Sqlite;
        return try gpa.dupe(u8, std.mem.span(ptr));
    }

    fn bumpLastAccessed(self: *Tools, id: i64) Error!void {
        try self.execBindOnlyId("UPDATE memories SET last_accessed = unixepoch() WHERE id = ?;", id);
    }

    fn applySlugChange(self: *Tools, id: i64, sc: SlugChange) Error!void {
        const sql = "UPDATE memories SET slug = ? WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        switch (sc) {
            .clear => try sqliteOk(c.sqlite3_bind_null(stmt, 1)),
            .set => |s| try sqliteOk(c.sqlite3_bind_text(stmt, 1, s.ptr, @intCast(s.len), null)),
        }
        try sqliteOk(c.sqlite3_bind_int64(stmt, 2, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            const ext = c.sqlite3_extended_errcode(self.db.handle);
            if (ext == c.SQLITE_CONSTRAINT_UNIQUE) return Error.SlugExists;
            return Error.Sqlite;
        }
    }

    fn applyContentUpdate(
        self: *Tools,
        id: i64,
        content: []const u8,
        new_format: ?[]const u8,
    ) Error!void {
        if (new_format) |f| {
            const sql = "UPDATE memories SET content = ?, format = ?, updated = unixepoch() WHERE id = ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
            defer _ = c.sqlite3_finalize(stmt);
            try sqliteOk(c.sqlite3_bind_text(stmt, 1, content.ptr, @intCast(content.len), null));
            try sqliteOk(c.sqlite3_bind_text(stmt, 2, f.ptr, @intCast(f.len), null));
            try sqliteOk(c.sqlite3_bind_int64(stmt, 3, id));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        } else {
            const sql = "UPDATE memories SET content = ?, updated = unixepoch() WHERE id = ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
            defer _ = c.sqlite3_finalize(stmt);
            try sqliteOk(c.sqlite3_bind_text(stmt, 1, content.ptr, @intCast(content.len), null));
            try sqliteOk(c.sqlite3_bind_int64(stmt, 2, id));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
        }
    }

    fn deleteChunksFor(self: *Tools, id: i64) Error!void {
        try self.execBindOnlyId("DELETE FROM chunks WHERE memory_id = ?;", id);
    }

    fn scalarInt64(self: *Tools, sql: [:0]const u8) Error!i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql.ptr, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.Sqlite;
        return c.sqlite3_column_int64(stmt, 0);
    }

    fn execBindId(self: *Tools, sql: [:0]const u8, text: []const u8, id: i64) Error!void {
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql.ptr, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_text(stmt, 1, text.ptr, @intCast(text.len), null));
        try sqliteOk(c.sqlite3_bind_int64(stmt, 2, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn execBindOnlyId(self: *Tools, sql: [:0]const u8, id: i64) Error!void {
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql.ptr, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn exec(self: *Tools, sql: [:0]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db.handle, sql.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                std.log.err("sqlite: {s}", .{errmsg});
                c.sqlite3_free(errmsg);
            }
            return Error.Sqlite;
        }
    }
};

fn sqliteOk(rc: c_int) Error!void {
    if (rc != c.SQLITE_OK) return Error.Sqlite;
}

fn isValidFormat(f: []const u8) bool {
    return std.mem.eql(u8, f, "text") or std.mem.eql(u8, f, "markdown");
}

/// Split `content` per `format` into the chunk slices that will be stored
/// in `chunks` / `vec_chunks`. Text format is always a single chunk equal
/// to the input; markdown delegates to chunk_mod.
fn splitContent(arena: Allocator, format: []const u8, content: []const u8) Error![]const []const u8 {
    if (std.mem.eql(u8, format, "markdown")) {
        return chunk_mod.chunkMarkdown(arena, content, chunk_mod.DEFAULT_SOFT_CAP) catch |err| switch (err) {
            error.ParseFailed => Error.InvalidFormat,
            error.OutOfMemory => Error.OutOfMemory,
        };
    }
    // Text format: exactly one chunk, text equal to content.
    const one = try arena.alloc([]const u8, 1);
    one[0] = content;
    return one;
}
