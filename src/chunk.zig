//! Markdown chunking via md4c.
//!
//! v1-foundation §9. Strips markdown to plain text while recording:
//!   - byte offsets in the stripped buffer where H1/H2 sections begin
//!   - byte ranges of code blocks and list items (the "no-split" zones)
//!
//! Then splits the stripped text at heading boundaries and, for any
//! resulting chunk > `soft_cap` chars, sub-splits at the latest safe
//! paragraph boundary (\n\n) outside any no-split range. If no safe
//! boundary exists, the chunk is allowed to exceed the cap rather than
//! cutting a code block or list item — per spec.

const std = @import("std");

pub const c = @cImport({
    @cInclude("md4c.h");
});

const Allocator = std.mem.Allocator;

pub const DEFAULT_SOFT_CAP: usize = 1500;

pub const Error = error{
    ParseFailed,
} || Allocator.Error;

const Range = struct { start: usize, end: usize };

const State = struct {
    gpa: Allocator,
    stripped: std.ArrayList(u8) = .empty,
    heading_offsets: std.ArrayList(usize) = .empty,
    code_ranges: std.ArrayList(Range) = .empty,
    list_ranges: std.ArrayList(Range) = .empty,
    in_heading_level: u8 = 0,
    code_starts: std.ArrayList(usize) = .empty,
    list_starts: std.ArrayList(usize) = .empty,
};

/// Chunk `src` (markdown) into plain-text segments suitable for FTS5 and
/// embedding. Caller owns the returned slice and each chunk slice; both
/// live in `arena`.
pub fn chunkMarkdown(arena: Allocator, src: []const u8, soft_cap: usize) Error![]const []const u8 {
    var st: State = .{ .gpa = arena };
    defer st.stripped.deinit(arena);
    defer st.heading_offsets.deinit(arena);
    defer st.code_ranges.deinit(arena);
    defer st.list_ranges.deinit(arena);
    defer st.code_starts.deinit(arena);
    defer st.list_starts.deinit(arena);

    var parser: c.MD_PARSER = std.mem.zeroes(c.MD_PARSER);
    parser.flags = c.MD_FLAG_NOHTML | c.MD_FLAG_TABLES | c.MD_FLAG_STRIKETHROUGH;
    parser.enter_block = enterBlockCb;
    parser.leave_block = leaveBlockCb;
    parser.enter_span = enterSpanCb;
    parser.leave_span = leaveSpanCb;
    parser.text = textCb;

    if (c.md_parse(src.ptr, @intCast(src.len), &parser, @ptrCast(&st)) != 0) {
        return Error.ParseFailed;
    }

    const stripped = st.stripped.items;

    // Sections from H1/H2 boundaries.
    var sections: std.ArrayList(Range) = .empty;
    defer sections.deinit(arena);
    var prev: usize = 0;
    for (st.heading_offsets.items) |off| {
        if (off > prev) try sections.append(arena, .{ .start = prev, .end = off });
        prev = off;
    }
    if (stripped.len > prev) try sections.append(arena, .{ .start = prev, .end = stripped.len });

    // Empty markdown → emit a single empty chunk so the spec scenario
    // "Empty markdown still yields at least one chunk" holds.
    if (sections.items.len == 0) {
        const chunks_one = try arena.alloc([]const u8, 1);
        chunks_one[0] = "";
        return chunks_one;
    }

    var out: std.ArrayList([]const u8) = .empty;
    for (sections.items) |sec| {
        try softCap(arena, stripped, sec, soft_cap, &st, &out);
    }
    return try out.toOwnedSlice(arena);
}

/// Append a chunk to `out` after duping `slice` into `arena` — required
/// because the raw slice points into `st.stripped`, which is freed when
/// `chunkMarkdown` returns.
fn pushChunk(arena: Allocator, out: *std.ArrayList([]const u8), slice: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, slice, "\n ");
    const owned = try arena.dupe(u8, trimmed);
    try out.append(arena, owned);
}

fn softCap(
    arena: Allocator,
    stripped: []const u8,
    sec: Range,
    soft_cap: usize,
    st: *const State,
    out: *std.ArrayList([]const u8),
) Error!void {
    var cursor = sec.start;
    while (true) {
        const remaining = sec.end - cursor;
        if (remaining <= soft_cap) {
            try pushChunk(arena, out, stripped[cursor..sec.end]);
            return;
        }

        const search_end = cursor + soft_cap;
        const split_at = findSafeSplit(stripped, cursor, search_end, st) orelse {
            const next_safe = nextSafePoint(stripped, search_end, sec.end, st);
            try pushChunk(arena, out, stripped[cursor..next_safe]);
            cursor = next_safe;
            if (cursor >= sec.end) return;
            continue;
        };
        try pushChunk(arena, out, stripped[cursor..split_at]);
        cursor = split_at;
    }
}

/// Latest `\n\n` boundary in [from, to] that is NOT inside any no-split
/// range. Returns null if no such boundary exists.
fn findSafeSplit(stripped: []const u8, from: usize, to: usize, st: *const State) ?usize {
    var search_to = to;
    if (search_to > stripped.len) search_to = stripped.len;
    if (search_to <= from + 1) return null;

    // Walk backwards looking for "\n\n".
    var i: usize = search_to - 1;
    while (i > from) : (i -= 1) {
        if (stripped[i] == '\n' and stripped[i - 1] == '\n') {
            const candidate = i + 1; // split AFTER the blank line
            if (!insideAnyRange(candidate, st)) return candidate;
        }
    }
    return null;
}

/// Walk forward from `from` until we leave any no-split range we're
/// currently inside. Used when we couldn't find a safe split — we extend
/// the chunk past `soft_cap` rather than cut a code block.
fn nextSafePoint(stripped: []const u8, from: usize, ceiling: usize, st: *const State) usize {
    var pos = from;
    if (pos >= ceiling) return ceiling;
    while (insideAnyRange(pos, st)) {
        // Skip to the end of whichever no-split range we're in.
        if (rangeEndContaining(pos, st.code_ranges.items)) |e| {
            pos = e;
        } else if (rangeEndContaining(pos, st.list_ranges.items)) |e| {
            pos = e;
        } else break;
        if (pos >= ceiling) return ceiling;
    }
    // Snap forward to the next paragraph boundary if we can find one.
    if (std.mem.indexOfScalarPos(u8, stripped[0..ceiling], pos, '\n')) |nl| {
        return nl + 1;
    }
    return ceiling;
}

fn insideAnyRange(pos: usize, st: *const State) bool {
    for (st.code_ranges.items) |r| if (pos >= r.start and pos < r.end) return true;
    for (st.list_ranges.items) |r| if (pos >= r.start and pos < r.end) return true;
    return false;
}

fn rangeEndContaining(pos: usize, ranges: []const Range) ?usize {
    for (ranges) |r| if (pos >= r.start and pos < r.end) return r.end;
    return null;
}

// =====================================================================
// md4c callbacks
// =====================================================================

fn enterBlockCb(block_type: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(userdata.?));
    const before_len = st.stripped.items.len;

    switch (block_type) {
        c.MD_BLOCK_H => {
            const h_detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
            st.in_heading_level = @intCast(h_detail.level);
            if (h_detail.level <= 2) {
                st.heading_offsets.append(st.gpa, before_len) catch return -1;
            }
        },
        c.MD_BLOCK_CODE => {
            st.code_starts.append(st.gpa, before_len) catch return -1;
        },
        c.MD_BLOCK_LI => {
            st.list_starts.append(st.gpa, before_len) catch return -1;
        },
        c.MD_BLOCK_P, c.MD_BLOCK_QUOTE => {},
        else => {},
    }
    return 0;
}

fn leaveBlockCb(block_type: c.MD_BLOCKTYPE, _: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(userdata.?));
    // Always end a top-level block with a blank line so paragraph
    // boundaries land in the stripped output.
    switch (block_type) {
        c.MD_BLOCK_H => {
            st.in_heading_level = 0;
            appendBytes(st, "\n\n") catch return -1;
        },
        c.MD_BLOCK_CODE => {
            const start = st.code_starts.pop() orelse 0;
            st.code_ranges.append(st.gpa, .{ .start = start, .end = st.stripped.items.len }) catch return -1;
            appendBytes(st, "\n\n") catch return -1;
        },
        c.MD_BLOCK_LI => {
            const start = st.list_starts.pop() orelse 0;
            st.list_ranges.append(st.gpa, .{ .start = start, .end = st.stripped.items.len }) catch return -1;
            appendBytes(st, "\n") catch return -1;
        },
        c.MD_BLOCK_P, c.MD_BLOCK_QUOTE => {
            appendBytes(st, "\n\n") catch return -1;
        },
        else => {},
    }
    return 0;
}

fn enterSpanCb(_: c.MD_SPANTYPE, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn leaveSpanCb(_: c.MD_SPANTYPE, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn textCb(text_type: c.MD_TEXTTYPE, text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(userdata.?));
    const slice: []const u8 = text[0..@intCast(size)];
    switch (text_type) {
        // MD_TEXT_NULLCHAR is replaced text for embedded NUL; treat as space.
        c.MD_TEXT_NULLCHAR => appendBytes(st, " ") catch return -1,
        c.MD_TEXT_BR, c.MD_TEXT_SOFTBR => appendBytes(st, " ") catch return -1,
        else => appendBytes(st, slice) catch return -1,
    }
    return 0;
}

fn appendBytes(st: *State, bytes: []const u8) !void {
    try st.stripped.appendSlice(st.gpa, bytes);
}

// =====================================================================
// Tests
// =====================================================================
//
// The caller-provided allocator owns each chunk slice AND the outer
// `[]const u8` slice. In production this is the request arena, freed
// wholesale. Tests use a per-test arena for the same reason.

const testing = std.testing;

test "single H1 section produces one chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const chunks = try chunkMarkdown(arena.allocator(), "# Title\n\nA short paragraph.\n", DEFAULT_SOFT_CAP);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expect(std.mem.indexOf(u8, chunks[0], "Title") != null);
    try testing.expect(std.mem.indexOf(u8, chunks[0], "short paragraph") != null);
}

test "multiple H1/H2 sections produce multiple chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md =
        \\# Alpha
        \\
        \\First section body.
        \\
        \\## Bravo
        \\
        \\Second section body.
        \\
        \\# Charlie
        \\
        \\Third section body.
    ;
    const chunks = try chunkMarkdown(arena.allocator(), md, DEFAULT_SOFT_CAP);
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expect(std.mem.indexOf(u8, chunks[0], "Alpha") != null);
    try testing.expect(std.mem.indexOf(u8, chunks[1], "Bravo") != null);
    try testing.expect(std.mem.indexOf(u8, chunks[2], "Charlie") != null);
}

test "H3 does not introduce a chunk boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const chunks = try chunkMarkdown(arena.allocator(), "# A\n\n### sub\n\ntext\n", DEFAULT_SOFT_CAP);
    try testing.expectEqual(@as(usize, 1), chunks.len);
}

test "long paragraph soft-caps at paragraph boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena.allocator(), "# T\n\n");
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try b.appendSlice(arena.allocator(), "Paragraph filler line. ");
        if (i % 5 == 4) try b.appendSlice(arena.allocator(), "\n\n");
    }
    const chunks = try chunkMarkdown(arena.allocator(), b.items, 200);
    try testing.expect(chunks.len > 1);
    for (chunks) |chunk| {
        // Soft-cap is advisory; runs that can't break cleanly may exceed it.
        try testing.expect(chunk.len <= 400);
    }
}

test "empty markdown still yields one chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const chunks = try chunkMarkdown(arena.allocator(), "", DEFAULT_SOFT_CAP);
    try testing.expectEqual(@as(usize, 1), chunks.len);
}

test "code block content survives intact when section fits cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = "# T\n\nintro\n\n```zig\nfn add(a: i32, b: i32) i32 { return a + b; }\n```\n\nouter\n";
    const chunks = try chunkMarkdown(arena.allocator(), md, DEFAULT_SOFT_CAP);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expect(std.mem.indexOf(u8, chunks[0], "fn add") != null);
}
