//! Atomic HTTPS download for memlite model files.
//!
//! v1-foundation §6.3. Uses `std.http.Client` (which auto-rescans system CA
//! roots on first HTTPS request) and `std.Io.Dir.createFileAtomic` so a
//! partially written file is never visible at the destination path.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    CreateFileFailed,
    HttpRequestFailed,
    HttpStatusNotOk,
    WriteFailed,
    ReplaceFailed,
};

/// Download `url` and atomically materialize it at `dst_dir/dst_basename`.
/// Progress is logged line-oriented to stderr via `std.log`.
pub fn download(
    gpa: Allocator,
    io: Io,
    url: []const u8,
    dst_dir: Io.Dir,
    dst_basename: []const u8,
) (Error || Allocator.Error)!void {
    std.log.info("memlite: downloading {s}", .{url});

    var atomic = dst_dir.createFileAtomic(io, dst_basename, .{
        .make_path = true,
        .replace = true,
    }) catch |err| {
        std.log.err("memlite: createFileAtomic({s}): {s}", .{ dst_basename, @errorName(err) });
        return Error.CreateFileFailed;
    };
    defer atomic.deinit(io);

    var file_buf: [256 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(atomic.file, io, &file_buf);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
        .keep_alive = false,
    }) catch |err| {
        std.log.err("memlite: fetch failed: {s}", .{@errorName(err)});
        return Error.HttpRequestFailed;
    };

    if (result.status != .ok) {
        std.log.err("memlite: download HTTP {d}", .{@intFromEnum(result.status)});
        return Error.HttpStatusNotOk;
    }

    file_writer.interface.flush() catch return Error.WriteFailed;
    const bytes = file_writer.pos;
    atomic.replace(io) catch |err| {
        std.log.err("memlite: rename to {s}: {s}", .{ dst_basename, @errorName(err) });
        return Error.ReplaceFailed;
    };
    std.log.info("memlite: downloaded {d} bytes -> {s}", .{ bytes, dst_basename });
}
