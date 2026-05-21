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
    InvalidPath,
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
    io: std.Io,

    /// Maximum file size accepted by `memory_load`. Markdown files larger
    /// than this are almost certainly the wrong artifact for relationship
    /// memory; cap to prevent accidental OOM.
    pub const MAX_LOAD_FILE_BYTES: usize = 1024 * 1024;

    pub fn init(db: *Db, embedder: *Embedder, io: std.Io) Tools {
        return .{ .db = db, .embedder = embedder, .io = io };
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

    // ---- memory_load --------------------------------------------------

    pub const LoadArgs = struct {
        path: []const u8,
        slug: ?[]const u8 = null,
        tags: []const TagPair = &.{},
    };

    /// Read a markdown file from `path` and add it as a memory.
    /// Markdown-only by design — see ingest spec, "memory_load reads a
    /// Markdown file from disk and forwards to memory_add".
    pub fn memoryLoad(self: *Tools, gpa: Allocator, args: LoadArgs) Error!AddResult {
        if (args.path.len == 0 or !std.fs.path.isAbsolute(args.path)) {
            return Error.InvalidPath;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var file = std.Io.Dir.cwd().openFile(self.io, args.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return Error.InvalidPath,
        };
        defer file.close(self.io);

        var read_buf: [64 * 1024]u8 = undefined;
        var file_reader: std.Io.File.Reader = .init(file, self.io, &read_buf);
        const reader = &file_reader.interface;

        const content = reader.allocRemaining(aa, .limited(MAX_LOAD_FILE_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => return Error.InvalidPath,
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.InvalidPath,
        };

        return self.memoryAdd(gpa, .{
            .content = content,
            .format = "markdown",
            .slug = args.slug,
            .tags = args.tags,
        });
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

        // sqlite3_last_insert_rowid doesn't reliably reflect trigger-driven
        // inserts on every SQLite build, so read the new history row's id
        // directly. memories_history.id is AUTOINCREMENT so MAX(id) for
        // this memory_id is the row the BEFORE DELETE trigger just wrote.
        const history_id = try self.scalarBoundI64(
            "SELECT IFNULL(MAX(id), 0) FROM memories_history WHERE memory_id = ?;",
            id,
        );
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

    // ---- memory_search -----------------------------------------------

    pub const TagFilter = struct {
        key: []const u8,
        /// One or more values; semantics is "key = K AND value IN values".
        values: []const []const u8,
    };

    pub const SearchArgs = struct {
        query: []const u8,
        where: []const TagFilter = &.{},
        limit: u32 = 10,
        oversample: u32 = 3,
    };

    pub const ChunkMatch = struct {
        chunk_id: i64,
        memory_id: i64,
        ord: i64,
        text: []const u8,
        score: f64,
    };

    pub const MemoryMatch = struct {
        id: i64,
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
        tags_json: []const u8,
        score: f64,
        matches: []const ChunkMatch,
        created: i64,
        updated: i64,
        last_accessed: i64,
    };

    pub const SearchResult = struct {
        memories: []const MemoryMatch,
    };

    pub fn memorySearch(self: *Tools, gpa: Allocator, args: SearchArgs) Error!SearchResult {
        const query_embedding = self.embedder.embed(gpa, args.query) catch return Error.EmbeddingFailed;
        defer gpa.free(query_embedding);

        const limit = if (args.limit == 0) 10 else args.limit;
        const oversample = if (args.oversample == 0) 3 else args.oversample;
        const k: u32 = limit *| oversample;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        // Pre-filtered memory ids via tag filter (or null for "all").
        const allowed_ids: ?[]const i64 = if (args.where.len == 0)
            null
        else
            try self.filterMemoriesByTags(aa, args.where);
        if (allowed_ids) |ids| if (ids.len == 0) {
            return .{ .memories = &.{} };
        };

        const vec_hits = try self.vecSearch(aa, query_embedding, k, allowed_ids);
        const fts_hits = try self.ftsSearch(aa, args.query, k, allowed_ids);

        // RRF combine. Map chunk_id -> running score; track first hit so we can
        // resolve memory_id, ord, text once at the end.
        var scores: std.AutoArrayHashMapUnmanaged(i64, f64) = .empty;
        defer scores.deinit(aa);

        for (vec_hits, 0..) |hit, rank0| {
            const contribution = 1.0 / (60.0 + @as(f64, @floatFromInt(rank0 + 1)));
            const gop = try scores.getOrPut(aa, hit);
            if (!gop.found_existing) gop.value_ptr.* = 0.0;
            gop.value_ptr.* += contribution;
        }
        for (fts_hits, 0..) |hit, rank0| {
            const contribution = 1.0 / (60.0 + @as(f64, @floatFromInt(rank0 + 1)));
            const gop = try scores.getOrPut(aa, hit);
            if (!gop.found_existing) gop.value_ptr.* = 0.0;
            gop.value_ptr.* += contribution;
        }

        if (scores.count() == 0) return .{ .memories = &.{} };

        // Resolve chunk metadata and group by memory_id.
        var by_memory: std.AutoArrayHashMapUnmanaged(i64, std.ArrayList(ChunkMatch)) = .empty;
        defer {
            var it = by_memory.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(aa);
            by_memory.deinit(aa);
        }

        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            const chunk_id = entry.key_ptr.*;
            const score = entry.value_ptr.*;
            const meta = self.chunkMeta(aa, chunk_id) catch |err| switch (err) {
                Error.NotFound => continue, // chunk gone between query and read; skip
                else => return err,
            };
            const m_gop = try by_memory.getOrPut(aa, meta.memory_id);
            if (!m_gop.found_existing) m_gop.value_ptr.* = .empty;
            try m_gop.value_ptr.append(aa, .{
                .chunk_id = chunk_id,
                .memory_id = meta.memory_id,
                .ord = meta.ord,
                .text = meta.text,
                .score = score,
            });
        }

        // Rank memories by max chunk score.
        const Entry = struct { memory_id: i64, top_score: f64, chunks: []ChunkMatch };
        var ranked: std.ArrayList(Entry) = .empty;
        defer ranked.deinit(aa);
        {
            var it = by_memory.iterator();
            while (it.next()) |kv| {
                const chunks = kv.value_ptr.items;
                std.mem.sort(ChunkMatch, chunks, {}, struct {
                    fn lessThan(_: void, a: ChunkMatch, b: ChunkMatch) bool {
                        return a.score > b.score;
                    }
                }.lessThan);
                try ranked.append(aa, .{
                    .memory_id = kv.key_ptr.*,
                    .top_score = chunks[0].score,
                    .chunks = chunks,
                });
            }
        }
        std.mem.sort(Entry, ranked.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.top_score > b.top_score;
            }
        }.lessThan);

        const memories_to_return = @min(@as(usize, @intCast(limit)), ranked.items.len);

        // Materialize MemoryMatch list in caller's gpa so it survives the arena.
        // memory_search is side-effect-free — no last_accessed bump here. The
        // memory_bump tool is the explicit "I used this" signal. See
        // openspec/changes/memory-bump-tool.
        const out_mems = try gpa.alloc(MemoryMatch, memories_to_return);

        for (ranked.items[0..memories_to_return], 0..) |entry, out_i| {
            const meta = try self.memoryHeader(gpa, entry.memory_id);
            const tags = try self.fetchTagsJson(gpa, entry.memory_id);

            const chunk_copies = try gpa.alloc(ChunkMatch, entry.chunks.len);
            for (entry.chunks, 0..) |ch, i| {
                chunk_copies[i] = .{
                    .chunk_id = ch.chunk_id,
                    .memory_id = ch.memory_id,
                    .ord = ch.ord,
                    .text = try gpa.dupe(u8, ch.text),
                    .score = ch.score,
                };
            }

            out_mems[out_i] = .{
                .id = entry.memory_id,
                .slug = meta.slug,
                .format = meta.format,
                .content = meta.content,
                .tags_json = tags,
                .score = entry.top_score,
                .matches = chunk_copies,
                .created = meta.created,
                .updated = meta.updated,
                .last_accessed = meta.last_accessed,
            };
        }

        return .{ .memories = out_mems };
    }

    // ---- memory_list -------------------------------------------------

    pub const OrderBy = enum {
        created,
        updated,
        last_accessed,

        pub fn column(self: OrderBy) []const u8 {
            return switch (self) {
                .created => "created",
                .updated => "updated",
                .last_accessed => "last_accessed",
            };
        }
    };

    pub const ListArgs = struct {
        where: []const TagFilter = &.{},
        since: ?i64 = null,
        limit: u32 = 50,
        offset: u32 = 0,
        order_by: OrderBy = .updated,
    };

    pub const ListEntry = struct {
        id: i64,
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
        tags_json: []const u8,
        created: i64,
        updated: i64,
        last_accessed: i64,
    };

    pub const ListResult = struct {
        memories: []const ListEntry,
    };

    pub fn memoryList(self: *Tools, gpa: Allocator, args: ListArgs) Error!ListResult {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var sql_buf: std.ArrayList(u8) = .empty;
        try sql_buf.appendSlice(aa,
            "SELECT id, slug, format, content, created, updated, last_accessed FROM memories m",
        );

        var first_pred = true;
        for (args.where, 0..) |filt, i| {
            try sql_buf.appendSlice(aa, if (first_pred) " WHERE " else " AND ");
            first_pred = false;
            _ = i;
            try sql_buf.appendSlice(aa, "EXISTS (SELECT 1 FROM tags t WHERE t.memory_id = m.id AND t.key = ? AND t.value IN (");
            for (filt.values, 0..) |_, j| {
                if (j > 0) try sql_buf.append(aa, ',');
                try sql_buf.append(aa, '?');
            }
            try sql_buf.appendSlice(aa, "))");
        }

        const col = args.order_by.column();
        if (args.since) |_| {
            try sql_buf.appendSlice(aa, if (first_pred) " WHERE " else " AND ");
            first_pred = false;
            // NULL exclusion is implicit in `>= ?` but be explicit so the
            // intent is plain.
            try sql_buf.appendSlice(aa, col);
            try sql_buf.appendSlice(aa, " IS NOT NULL AND ");
            try sql_buf.appendSlice(aa, col);
            try sql_buf.appendSlice(aa, " >= ?");
        }

        try sql_buf.appendSlice(aa, " ORDER BY ");
        try sql_buf.appendSlice(aa, col);
        try sql_buf.appendSlice(aa, " DESC LIMIT ? OFFSET ?;");
        const sql_z = try aa.dupeZ(u8, sql_buf.items);

        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql_z, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);

        var idx: c_int = 1;
        for (args.where) |filt| {
            try sqliteOk(c.sqlite3_bind_text(stmt, idx, filt.key.ptr, @intCast(filt.key.len), null));
            idx += 1;
            for (filt.values) |v| {
                try sqliteOk(c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), null));
                idx += 1;
            }
        }
        if (args.since) |s| {
            try sqliteOk(c.sqlite3_bind_int64(stmt, idx, s));
            idx += 1;
        }
        try sqliteOk(c.sqlite3_bind_int64(stmt, idx, @intCast(args.limit)));
        idx += 1;
        try sqliteOk(c.sqlite3_bind_int64(stmt, idx, @intCast(args.offset)));

        var out: std.ArrayList(ListEntry) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            const id = c.sqlite3_column_int64(stmt, 0);
            const slug_text = c.sqlite3_column_text(stmt, 1);
            const slug: ?[]const u8 = if (slug_text == null) null else try gpa.dupe(u8, std.mem.span(slug_text));
            try out.append(gpa, .{
                .id = id,
                .slug = slug,
                .format = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2).?)),
                .content = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3).?)),
                .tags_json = try self.fetchTagsJson(gpa, id),
                .created = c.sqlite3_column_int64(stmt, 4),
                .updated = c.sqlite3_column_int64(stmt, 5),
                .last_accessed = c.sqlite3_column_int64(stmt, 6),
            });
        }
        return .{ .memories = try out.toOwnedSlice(gpa) };
    }

    // ---- list_tags / list_tag_values / list_tag_siblings -------------

    pub const KeyCount = struct { key: []const u8, memory_count: i64 };
    pub const ValueCount = struct { value: []const u8, memory_count: i64 };
    pub const Sibling = struct { key: []const u8, value: []const u8, co_occurrence_count: i64 };

    pub fn listTags(self: *Tools, gpa: Allocator) Error![]const KeyCount {
        const sql = "SELECT key, count(DISTINCT memory_id) FROM tags GROUP BY key ORDER BY 2 DESC, key;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        var out: std.ArrayList(KeyCount) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            try out.append(gpa, .{
                .key = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0).?)),
                .memory_count = c.sqlite3_column_int64(stmt, 1),
            });
        }
        return try out.toOwnedSlice(gpa);
    }

    pub fn listTagValues(self: *Tools, gpa: Allocator, key: []const u8) Error![]const ValueCount {
        const sql = "SELECT value, count(DISTINCT memory_id) FROM tags WHERE key = ? GROUP BY value ORDER BY 2 DESC, value;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null));
        var out: std.ArrayList(ValueCount) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            try out.append(gpa, .{
                .value = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0).?)),
                .memory_count = c.sqlite3_column_int64(stmt, 1),
            });
        }
        return try out.toOwnedSlice(gpa);
    }

    pub fn listTagSiblings(self: *Tools, gpa: Allocator, key: []const u8, value: []const u8) Error![]const Sibling {
        const sql =
            \\SELECT key, value, count(DISTINCT memory_id) AS co
            \\FROM tags
            \\WHERE memory_id IN (SELECT memory_id FROM tags WHERE key = ? AND value = ?)
            \\  AND NOT (key = ? AND value = ?)
            \\GROUP BY key, value
            \\ORDER BY co DESC, key, value;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 3, key.ptr, @intCast(key.len), null));
        try sqliteOk(c.sqlite3_bind_text(stmt, 4, value.ptr, @intCast(value.len), null));
        var out: std.ArrayList(Sibling) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            try out.append(gpa, .{
                .key = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0).?)),
                .value = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1).?)),
                .co_occurrence_count = c.sqlite3_column_int64(stmt, 2),
            });
        }
        return try out.toOwnedSlice(gpa);
    }

    // ---- memory_history ---------------------------------------------

    pub const HistoryEntry = struct {
        id: i64,
        memory_id: i64,
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
        tags_snapshot: []const u8,
        created: i64,
        updated: i64,
        last_accessed: i64,
        archived_at: i64,
        archive_reason: []const u8,
    };

    pub fn memoryHistory(self: *Tools, gpa: Allocator, target: Target) Error![]const HistoryEntry {
        // For string target: union live-memory-id resolution with direct
        // slug match in history. For numeric: history.memory_id only.
        const sql_z = switch (target) {
            .id =>
                \\SELECT id, memory_id, slug, format, content, tags_snapshot,
                \\       created, updated, last_accessed, archived_at, archive_reason
                \\FROM memories_history
                \\WHERE memory_id = ?
                \\ORDER BY archived_at DESC;
            ,
            .slug =>
                \\SELECT id, memory_id, slug, format, content, tags_snapshot,
                \\       created, updated, last_accessed, archived_at, archive_reason
                \\FROM memories_history
                \\WHERE slug = ?
                \\   OR memory_id = (SELECT id FROM memories WHERE slug = ?)
                \\ORDER BY archived_at DESC;
            ,
        };

        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql_z, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);

        switch (target) {
            .id => |n| try sqliteOk(c.sqlite3_bind_int64(stmt, 1, n)),
            .slug => |s| {
                try sqliteOk(c.sqlite3_bind_text(stmt, 1, s.ptr, @intCast(s.len), null));
                try sqliteOk(c.sqlite3_bind_text(stmt, 2, s.ptr, @intCast(s.len), null));
            },
        }

        var out: std.ArrayList(HistoryEntry) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            const slug_text = c.sqlite3_column_text(stmt, 2);
            const slug: ?[]const u8 = if (slug_text == null) null else try gpa.dupe(u8, std.mem.span(slug_text));
            try out.append(gpa, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .memory_id = c.sqlite3_column_int64(stmt, 1),
                .slug = slug,
                .format = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3).?)),
                .content = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4).?)),
                .tags_snapshot = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5).?)),
                .created = c.sqlite3_column_int64(stmt, 6),
                .updated = c.sqlite3_column_int64(stmt, 7),
                .last_accessed = c.sqlite3_column_int64(stmt, 8),
                .archived_at = c.sqlite3_column_int64(stmt, 9),
                .archive_reason = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 10).?)),
            });
        }
        return try out.toOwnedSlice(gpa);
    }

    // ---- memory_status ----------------------------------------------

    pub const Status = struct {
        total_memories: i64,
        total_chunks: i64,
        total_tags: i64,
        history_entries: i64,
        embedding_model: []const u8,
        embedding_dim: i64,
        database_size_bytes: i64,
        text_count: i64,
        markdown_count: i64,
    };

    pub fn memoryStatus(self: *Tools, gpa: Allocator) Error!Status {
        const total_memories = try self.scalarInt64("SELECT count(*) FROM memories;");
        const total_chunks = try self.scalarInt64("SELECT count(*) FROM chunks;");
        const total_tags = try self.scalarInt64("SELECT count(*) FROM tags;");
        const history_entries = try self.scalarInt64("SELECT count(*) FROM memories_history;");
        const text_count = try self.scalarInt64("SELECT count(*) FROM memories WHERE format = 'text';");
        const markdown_count = try self.scalarInt64("SELECT count(*) FROM memories WHERE format = 'markdown';");

        const model_url = (self.db.getSetting(gpa, "model_url") catch return Error.Sqlite) orelse try gpa.dupe(u8, "");
        const dim_str = (self.db.getSetting(gpa, "embedding_dim") catch return Error.Sqlite) orelse try gpa.dupe(u8, "0");
        defer gpa.free(dim_str);
        const embedding_dim = std.fmt.parseInt(i64, dim_str, 10) catch 0;

        // page_count * page_size — accurate for both file-backed and :memory: DBs.
        const page_count = try self.scalarInt64("PRAGMA page_count;");
        const page_size = try self.scalarInt64("PRAGMA page_size;");

        return .{
            .total_memories = total_memories,
            .total_chunks = total_chunks,
            .total_tags = total_tags,
            .history_entries = history_entries,
            .embedding_model = model_url,
            .embedding_dim = embedding_dim,
            .database_size_bytes = page_count * page_size,
            .text_count = text_count,
            .markdown_count = markdown_count,
        };
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

    pub const BumpResult = struct { id: i64, last_accessed: i64 };

    /// Update `last_accessed = unixepoch()` for the targeted live memory.
    /// Returns the resolved id and the new timestamp. See
    /// openspec/changes/memory-bump-tool — this is the explicit engagement
    /// signal that replaces v1's auto-bump-on-memory_search behavior.
    pub fn memoryBump(self: *Tools, target: Target) Error!BumpResult {
        const id = try self.resolveTarget(target);
        try self.bumpLastAccessed(id);
        const new_last_accessed = try self.scalarBoundI64(
            "SELECT last_accessed FROM memories WHERE id = ?;",
            id,
        );
        return .{ .id = id, .last_accessed = new_last_accessed };
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

    // ---- Search helpers -----------------------------------------------

    const ChunkMeta = struct {
        memory_id: i64,
        ord: i64,
        text: []const u8,
    };

    const MemoryHeader = struct {
        slug: ?[]const u8,
        format: []const u8,
        content: []const u8,
        created: i64,
        updated: i64,
        last_accessed: i64,
    };

    fn vecSearch(
        self: *Tools,
        arena: Allocator,
        query_embedding: []const f32,
        k: u32,
        allowed_ids: ?[]const i64,
    ) Error![]const i64 {
        // sqlite-vec wants the k bound positionally on its right-hand side;
        // tag filtering is applied by pre-filtering rowid via an IN list.
        var sql_buf: std.ArrayList(u8) = .empty;
        try sql_buf.appendSlice(arena,
            "SELECT rowid FROM vec_chunks WHERE embedding MATCH ? AND k = ?",
        );
        if (allowed_ids) |ids| {
            try sql_buf.appendSlice(arena, " AND rowid IN (SELECT id FROM chunks WHERE memory_id IN (");
            try appendIntList(arena, &sql_buf, ids);
            try sql_buf.appendSlice(arena, "))");
        }
        try sql_buf.appendSlice(arena, " ORDER BY distance");
        try sql_buf.append(arena, ';');
        const sql_z = try arena.dupeZ(u8, sql_buf.items);

        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql_z, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        const bytes = std.mem.sliceAsBytes(query_embedding);
        try sqliteOk(c.sqlite3_bind_blob(stmt, 1, bytes.ptr, @intCast(bytes.len), null));
        try sqliteOk(c.sqlite3_bind_int64(stmt, 2, @intCast(k)));

        var out: std.ArrayList(i64) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            try out.append(arena, c.sqlite3_column_int64(stmt, 0));
        }
        return try out.toOwnedSlice(arena);
    }

    fn ftsSearch(
        self: *Tools,
        arena: Allocator,
        query: []const u8,
        k: u32,
        allowed_ids: ?[]const i64,
    ) Error![]const i64 {
        // Sanitize the query: keep alphanumeric + whitespace, drop everything
        // else. FTS5 free text otherwise interprets punctuation as operators.
        const cleaned = try sanitizeFtsQuery(arena, query);
        if (cleaned.len == 0) return &.{};

        var sql_buf: std.ArrayList(u8) = .empty;
        try sql_buf.appendSlice(arena, "SELECT rowid FROM fts_chunks WHERE text MATCH ?");
        if (allowed_ids) |ids| {
            try sql_buf.appendSlice(arena, " AND rowid IN (SELECT id FROM chunks WHERE memory_id IN (");
            try appendIntList(arena, &sql_buf, ids);
            try sql_buf.appendSlice(arena, "))");
        }
        try sql_buf.appendSlice(arena, " ORDER BY bm25(fts_chunks) LIMIT ?;");
        const sql_z = try arena.dupeZ(u8, sql_buf.items);

        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql_z, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_text(stmt, 1, cleaned.ptr, @intCast(cleaned.len), null));
        try sqliteOk(c.sqlite3_bind_int64(stmt, 2, @intCast(k)));

        var out: std.ArrayList(i64) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                // An invalid FTS query (e.g. a stop-word only string) shows up
                // as an error; treat it as "no FTS hits" rather than failing
                // the whole search.
                return &.{};
            }
            try out.append(arena, c.sqlite3_column_int64(stmt, 0));
        }
        return try out.toOwnedSlice(arena);
    }

    fn filterMemoriesByTags(
        self: *Tools,
        arena: Allocator,
        filters: []const TagFilter,
    ) Error![]const i64 {
        // Build:
        //   SELECT id FROM memories m
        //   WHERE EXISTS (SELECT 1 FROM tags t WHERE t.memory_id = m.id AND t.key = ? AND t.value IN (?, ?, ...))
        //     AND EXISTS (...)
        var sql_buf: std.ArrayList(u8) = .empty;
        try sql_buf.appendSlice(arena, "SELECT id FROM memories m");
        var first = true;
        for (filters) |_| {
            try sql_buf.appendSlice(arena, if (first) " WHERE EXISTS " else " AND EXISTS ");
            try sql_buf.appendSlice(arena, "(SELECT 1 FROM tags t WHERE t.memory_id = m.id AND t.key = ? AND t.value IN (");
            // Placeholders for values are added below using bound params, but
            // we don't know the count at SQL-build time without iterating.
            first = false;
        }
        // Build the full SQL with the right number of `?` placeholders for
        // each filter's values.
        sql_buf.clearRetainingCapacity();
        try sql_buf.appendSlice(arena, "SELECT id FROM memories m");
        for (filters, 0..) |filt, i| {
            try sql_buf.appendSlice(arena, if (i == 0) " WHERE EXISTS " else " AND EXISTS ");
            try sql_buf.appendSlice(arena, "(SELECT 1 FROM tags t WHERE t.memory_id = m.id AND t.key = ? AND t.value IN (");
            for (filt.values, 0..) |_, j| {
                if (j > 0) try sql_buf.append(arena, ',');
                try sql_buf.append(arena, '?');
            }
            try sql_buf.appendSlice(arena, "))");
        }
        try sql_buf.append(arena, ';');
        const sql_z = try arena.dupeZ(u8, sql_buf.items);

        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql_z, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);

        var idx: c_int = 1;
        for (filters) |filt| {
            try sqliteOk(c.sqlite3_bind_text(stmt, idx, filt.key.ptr, @intCast(filt.key.len), null));
            idx += 1;
            for (filt.values) |v| {
                try sqliteOk(c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), null));
                idx += 1;
            }
        }

        var out: std.ArrayList(i64) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            try out.append(arena, c.sqlite3_column_int64(stmt, 0));
        }
        return try out.toOwnedSlice(arena);
    }

    fn chunkMeta(self: *Tools, arena: Allocator, chunk_id: i64) Error!ChunkMeta {
        const sql = "SELECT memory_id, ord, text FROM chunks WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, chunk_id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        return .{
            .memory_id = c.sqlite3_column_int64(stmt, 0),
            .ord = c.sqlite3_column_int64(stmt, 1),
            .text = try arena.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2).?)),
        };
    }

    fn memoryHeader(self: *Tools, gpa: Allocator, id: i64) Error!MemoryHeader {
        const sql = "SELECT slug, format, content, created, updated, last_accessed FROM memories WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        const slug_text = c.sqlite3_column_text(stmt, 0);
        const slug: ?[]const u8 = if (slug_text == null) null else try gpa.dupe(u8, std.mem.span(slug_text));
        return .{
            .slug = slug,
            .format = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1).?)),
            .content = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2).?)),
            .created = c.sqlite3_column_int64(stmt, 3),
            .updated = c.sqlite3_column_int64(stmt, 4),
            .last_accessed = c.sqlite3_column_int64(stmt, 5),
        };
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

    fn scalarBoundI64(self: *Tools, sql: [:0]const u8, id: i64) Error!i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        try sqliteOk(c.sqlite3_prepare_v2(self.db.handle, sql.ptr, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try sqliteOk(c.sqlite3_bind_int64(stmt, 1, id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.Sqlite;
        return c.sqlite3_column_int64(stmt, 0);
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

fn appendIntList(arena: Allocator, buf: *std.ArrayList(u8), ids: []const i64) !void {
    for (ids, 0..) |id, i| {
        if (i > 0) try buf.append(arena, ',');
        try buf.print(arena, "{d}", .{id});
    }
}

fn sanitizeFtsQuery(arena: Allocator, query: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_space = true;
    for (query) |ch| {
        const keep = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_';
        if (keep) {
            try out.append(arena, ch);
            last_space = false;
        } else if (!last_space) {
            try out.append(arena, ' ');
            last_space = true;
        }
    }
    return try out.toOwnedSlice(arena);
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

// ---- Tests ----
//
// memory_bump and memory_search behavior introduced by
// openspec/changes/memory-bump-tool: bump updates last_accessed, search
// no longer does. The two bump tests run on every `zig build test`. The
// search test needs an embedder (to embed the query) and is gated on
// $MEMLITE_TEST_MODEL.

const testing = std.testing;
const model_mod = @import("model.zig");

fn fetchLastAccessed(db: *Db, id: i64) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(
        db.handle,
        "SELECT last_accessed FROM memories WHERE id = ?;",
        -1,
        &stmt,
        null,
    ) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NoRow;
    return c.sqlite3_column_int64(stmt, 0);
}

test "memory_bump updates last_accessed and returns the new value" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema(testing.allocator, 4, "test://model");

    var tools: Tools = .{ .db = &db, .embedder = undefined, .io = undefined };

    try tools.exec(
        \\INSERT INTO memories(slug, format, content, created, updated, last_accessed)
        \\VALUES ('x', 'text', 'hello', 1000, 1000, 1000);
    );

    const before = try fetchLastAccessed(&db, 1);
    try testing.expectEqual(@as(i64, 1000), before);

    const result = try tools.memoryBump(.{ .slug = "x" });
    try testing.expectEqual(@as(i64, 1), result.id);
    try testing.expect(result.last_accessed > 1000);
    try testing.expectEqual(result.last_accessed, try fetchLastAccessed(&db, 1));

    // Bump-by-id also resolves and updates.
    const second = try tools.memoryBump(.{ .id = 1 });
    try testing.expectEqual(@as(i64, 1), second.id);
    try testing.expect(second.last_accessed >= result.last_accessed);
}

test "memory_bump on a non-existent target returns NotFound" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema(testing.allocator, 4, "test://model");

    var tools: Tools = .{ .db = &db, .embedder = undefined, .io = undefined };

    try testing.expectError(Error.NotFound, tools.memoryBump(.{ .slug = "nope" }));
    try testing.expectError(Error.NotFound, tools.memoryBump(.{ .id = 42 }));
}

fn testModelPath() ?[:0]const u8 {
    const env = std.c.getenv("MEMLITE_TEST_MODEL") orelse return null;
    return std.mem.span(env);
}

test "memory_search leaves last_accessed unchanged" {
    const path = testModelPath() orelse return error.SkipZigTest;

    model_mod.initBackend();
    defer model_mod.deinitBackend();
    var model = try model_mod.Model.loadFromFile(path, .{ .quiet = true });
    defer model.deinit();
    var embedder = try Embedder.init(model);
    defer embedder.deinit();

    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema(testing.allocator, embedder.dim, "test://model");

    var tools: Tools = .{ .db = &db, .embedder = &embedder, .io = undefined };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    _ = try tools.memoryAdd(aa, .{
        .content = "the user takes their coffee black",
        .slug = "coffee-pref",
    });

    // Pin last_accessed to a deliberately-old value so any bump would be
    // unambiguously visible (unixepoch() is many orders of magnitude larger
    // than 1, so a same-second bump still shows as a jump).
    try tools.exec("UPDATE memories SET last_accessed = 1 WHERE id = 1;");
    try testing.expectEqual(@as(i64, 1), try fetchLastAccessed(&db, 1));

    _ = try tools.memorySearch(aa, .{ .query = "coffee" });

    try testing.expectEqual(@as(i64, 1), try fetchLastAccessed(&db, 1));
}
