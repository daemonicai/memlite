//! Strict HuggingFace URL parser for memlite's `--model` flag.
//!
//! v1-foundation §6.1. Accepts only:
//!     https://huggingface.co/{owner}/{repo}/resolve/{branch}/{filename}[?…]
//!
//! Rejects /blob/ paths (those serve HTML, not the raw file), non-HF hosts,
//! non-HTTPS schemes, and multi-segment filenames (the cache layout in §6.2
//! flattens to a single basename per repo).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Parsed = struct {
    owner: []const u8,
    repo: []const u8,
    branch: []const u8,
    filename: []const u8,
    /// The full URL — kept verbatim for storing in `settings('model_url')`
    /// so MODEL_MISMATCH comparisons are byte-exact.
    raw: []const u8,
};

pub const Error = error{
    InvalidScheme,
    UnsupportedHost,
    NotResolvePath,
    MalformedPath,
};

const https_prefix = "https://";
const expected_host = "huggingface.co";

pub fn parse(url: []const u8) Error!Parsed {
    if (!std.mem.startsWith(u8, url, https_prefix)) return Error.InvalidScheme;
    const after_scheme = url[https_prefix.len..];

    const host_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return Error.MalformedPath;
    const host = after_scheme[0..host_end];
    if (!std.mem.eql(u8, host, expected_host)) return Error.UnsupportedHost;
    const path = after_scheme[host_end..];

    const path_no_query = blk: {
        if (std.mem.indexOfScalar(u8, path, '?')) |q| break :blk path[0..q];
        break :blk path;
    };

    var it = std.mem.splitScalar(u8, path_no_query, '/');
    if (it.next()) |first| {
        if (first.len != 0) return Error.MalformedPath; // path must start with /
    } else return Error.MalformedPath;

    const owner = it.next() orelse return Error.MalformedPath;
    const repo = it.next() orelse return Error.MalformedPath;
    const action = it.next() orelse return Error.MalformedPath;
    if (std.mem.eql(u8, action, "blob")) return Error.NotResolvePath;
    if (!std.mem.eql(u8, action, "resolve")) return Error.NotResolvePath;
    const branch = it.next() orelse return Error.MalformedPath;
    const filename = it.next() orelse return Error.MalformedPath;
    if (it.next() != null) return Error.MalformedPath; // reject subdir paths after branch

    if (owner.len == 0 or repo.len == 0 or branch.len == 0 or filename.len == 0) {
        return Error.MalformedPath;
    }

    return .{
        .owner = owner,
        .repo = repo,
        .branch = branch,
        .filename = filename,
        .raw = url,
    };
}

/// Compose the on-disk cache path for a parsed URL.
/// Layout: `{home}/.memlite/models/{owner}/{repo}/{filename}`.
/// Returns a heap-allocated sentinel-terminated slice (caller owns).
pub fn cachePathZ(allocator: Allocator, home: []const u8, parsed: Parsed) Allocator.Error![:0]u8 {
    return std.fs.path.joinZ(allocator, &.{
        home,
        ".memlite",
        "models",
        parsed.owner,
        parsed.repo,
        parsed.filename,
    });
}

// ---- Tests ----

const testing = std.testing;

test "happy path: nomic-embed canonical URL" {
    const url = "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf";
    const p = try parse(url);
    try testing.expectEqualStrings("nomic-ai", p.owner);
    try testing.expectEqualStrings("nomic-embed-text-v1.5-GGUF", p.repo);
    try testing.expectEqualStrings("main", p.branch);
    try testing.expectEqualStrings("nomic-embed-text-v1.5.Q5_K_M.gguf", p.filename);
    try testing.expectEqualStrings(url, p.raw);
}

test "query string is stripped from filename" {
    const p = try parse("https://huggingface.co/o/r/resolve/main/file.gguf?download=true");
    try testing.expectEqualStrings("file.gguf", p.filename);
}

test "rejects http://" {
    try testing.expectError(Error.InvalidScheme, parse("http://huggingface.co/o/r/resolve/main/f.gguf"));
}

test "rejects non-HF host" {
    try testing.expectError(Error.UnsupportedHost, parse("https://example.com/o/r/resolve/main/f.gguf"));
}

test "rejects /blob/" {
    try testing.expectError(Error.NotResolvePath, parse("https://huggingface.co/o/r/blob/main/f.gguf"));
}

test "rejects unknown action segment" {
    try testing.expectError(Error.NotResolvePath, parse("https://huggingface.co/o/r/tree/main/f.gguf"));
}

test "rejects subdir path after branch" {
    try testing.expectError(Error.MalformedPath, parse("https://huggingface.co/o/r/resolve/main/dir/f.gguf"));
}

test "rejects missing filename" {
    try testing.expectError(Error.MalformedPath, parse("https://huggingface.co/o/r/resolve/main"));
}

test "cachePathZ joins under home/.memlite/models" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse("https://huggingface.co/nomic-ai/x-GGUF/resolve/main/x.gguf");
    const path = try cachePathZ(arena.allocator(), "/Users/me", p);
    try testing.expectEqualStrings("/Users/me/.memlite/models/nomic-ai/x-GGUF/x.gguf", path);
}
