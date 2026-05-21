const std = @import("std");

const c = @cImport({
    @cDefine("SQLITE_CORE", "1");
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

pub fn main() !void {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        std.debug.print("sqlite3_open failed: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.SqliteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    try smokeSqliteVersion(db);
    try smokeFts5(db);
    try smokeVec0(db);
}

fn smokeSqliteVersion(db: ?*c.sqlite3) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT sqlite_version()", -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare sqlite_version failed: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NoRow;
    const text = c.sqlite3_column_text(stmt, 0);
    std.debug.print("sqlite_version: {s}\n", .{text});
}

fn smokeFts5(db: ?*c.sqlite3) !void {
    if (c.sqlite3_exec(
        db,
        "CREATE VIRTUAL TABLE fts_probe USING fts5(content);",
        null,
        null,
        null,
    ) != c.SQLITE_OK) {
        std.debug.print("fts5 missing: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.NoFts5;
    }
    std.debug.print("fts5 OK\n", .{});
}

fn smokeVec0(db: ?*c.sqlite3) !void {
    if (c.sqlite3_vec_init(db, null, null) != c.SQLITE_OK) {
        std.debug.print("sqlite_vec_init failed: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.VecInitFailed;
    }
    if (c.sqlite3_exec(
        db,
        "CREATE VIRTUAL TABLE vec_probe USING vec0(embedding FLOAT[4]);",
        null,
        null,
        null,
    ) != c.SQLITE_OK) {
        std.debug.print("vec0 missing: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.NoVec0;
    }
    std.debug.print("vec0 OK\n", .{});
}
