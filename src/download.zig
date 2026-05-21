//! Atomic HTTPS download for memlite model files.
//!
//! v1-foundation §6.3. Uses `std.http.Client` (which auto-rescans system CA
//! roots on first HTTPS request) and `std.Io.Dir.createFileAtomic` so a
//! partially written file is never visible at the destination path.
//!
//! Progress is reported line-oriented on stderr via `std.log` at a cadence
//! of every 5 % of the body when `Content-Length` is known, otherwise every
//! 5 MiB. See `Progress` below.

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

const MIB: u64 = 1024 * 1024;
const UNKNOWN_STEP: u64 = 5 * MIB;

/// Sink for one formatted progress line. The line is `basename`-prefixed
/// and does NOT include a trailing newline; the production callback hands
/// it to `std.log.info("{s}", .{line})` which adds the `info:` prefix and
/// terminator. Tests substitute a callback that captures lines verbatim.
pub const EmitFn = *const fn (ctx: ?*anyopaque, line: []const u8) void;

/// A `std.Io.Writer` adapter that forwards every byte to an inner writer
/// while counting bytes and emitting a progress line each time the running
/// total crosses a 5% (known total) or 5 MiB (unknown total) threshold.
///
/// Zero allocations on the hot path: log lines are formatted into a 256-
/// byte stack buffer per emission.
pub const Progress = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    basename: []const u8,
    total: ?u64,
    count: u64 = 0,
    next_emit: u64,
    /// Next percent threshold to emit at. 5, 10, ..., 100. Ignored when
    /// `total == null`.
    next_pct: u8 = 5,
    /// Lines emitted so far. For tests.
    lines: u32 = 0,
    emit_fn: EmitFn,
    emit_ctx: ?*anyopaque,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    pub fn init(
        out: *std.Io.Writer,
        buffer: []u8,
        basename: []const u8,
        total: ?u64,
        emit_fn: EmitFn,
        emit_ctx: ?*anyopaque,
    ) Progress {
        return .{
            .out = out,
            .writer = .{ .buffer = buffer, .vtable = &vtable },
            .basename = basename,
            .total = total,
            .next_emit = if (total) |t| (t * 5) / 100 else UNKNOWN_STEP,
            .emit_fn = emit_fn,
            .emit_ctx = emit_ctx,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Progress = @alignCast(@fieldParentPtr("writer", w));
        const aux = w.buffered();
        const aux_n = try self.out.writeSplatHeader(aux, data, splat);
        if (aux_n < w.end) {
            self.bump(aux_n);
            const remaining = w.buffer[aux_n..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        self.bump(aux_n);
        const n = aux_n - w.end;
        w.end = 0;
        return n;
    }

    fn bump(self: *Progress, n: usize) void {
        self.count += n;
        if (self.total) |t| {
            while (self.next_pct <= 100 and self.count >= self.next_emit) {
                self.fire(self.next_pct);
                self.next_pct +|= 5;
                self.next_emit = if (self.next_pct <= 100)
                    (t * self.next_pct) / 100
                else
                    std.math.maxInt(u64);
            }
        } else {
            while (self.count >= self.next_emit) {
                self.fire(0);
                self.next_emit += UNKNOWN_STEP;
            }
        }
    }

    fn fire(self: *Progress, pct: u8) void {
        var buf: [256]u8 = undefined;
        const line = formatLine(&buf, self.basename, self.count, self.total, pct) catch return;
        self.emit_fn(self.emit_ctx, line);
        self.lines += 1;
    }
};

fn formatLine(buf: []u8, basename: []const u8, count: u64, total: ?u64, pct: u8) ![]u8 {
    const mib = count / MIB;
    if (total) |t| {
        const total_mib = t / MIB;
        return std.fmt.bufPrint(buf, "memlite: download {s}: {d} / {d} MiB ({d}%)", .{ basename, mib, total_mib, pct });
    }
    return std.fmt.bufPrint(buf, "memlite: download {s}: {d} MiB", .{ basename, mib });
}

fn stdLogEmit(_: ?*anyopaque, line: []const u8) void {
    std.log.info("{s}", .{line});
}

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

    const uri = std.Uri.parse(url) catch |err| {
        std.log.err("memlite: bad URL {s}: {s}", .{ url, @errorName(err) });
        return Error.HttpRequestFailed;
    };

    var req = client.request(.GET, uri, .{ .keep_alive = false }) catch |err| {
        std.log.err("memlite: request {s}: {s}", .{ url, @errorName(err) });
        return Error.HttpRequestFailed;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        std.log.err("memlite: send {s}: {s}", .{ url, @errorName(err) });
        return Error.HttpRequestFailed;
    };

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.log.err("memlite: receive head {s}: {s}", .{ url, @errorName(err) });
        return Error.HttpRequestFailed;
    };

    if (response.head.status != .ok) {
        std.log.err("memlite: download HTTP {d}", .{@intFromEnum(response.head.status)});
        return Error.HttpStatusNotOk;
    }

    if (response.head.content_encoding != .identity) {
        std.log.err("memlite: unexpected content-encoding {s}", .{@tagName(response.head.content_encoding)});
        return Error.HttpRequestFailed;
    }

    var transfer_buf: [64]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);

    var progress_buf: [4096]u8 = undefined;
    var progress = Progress.init(
        &file_writer.interface,
        &progress_buf,
        dst_basename,
        req.response_content_length,
        stdLogEmit,
        null,
    );

    _ = body_reader.streamRemaining(&progress.writer) catch |err| switch (err) {
        error.ReadFailed => {
            std.log.err("memlite: body read failed", .{});
            return Error.HttpRequestFailed;
        },
        else => |e| {
            std.log.err("memlite: stream failed: {s}", .{@errorName(e)});
            return Error.WriteFailed;
        },
    };

    progress.writer.flush() catch return Error.WriteFailed;
    file_writer.interface.flush() catch return Error.WriteFailed;
    const bytes = file_writer.pos;
    atomic.replace(io) catch |err| {
        std.log.err("memlite: rename to {s}: {s}", .{ dst_basename, @errorName(err) });
        return Error.ReplaceFailed;
    };
    std.log.info("memlite: downloaded {d} bytes -> {s}", .{ bytes, dst_basename });
}

// ---- Tests ----

const testing = std.testing;

const Capture = struct {
    list: std.ArrayList([]u8),
    gpa: Allocator,

    fn init(gpa: Allocator) Capture {
        return .{ .list = .empty, .gpa = gpa };
    }

    fn deinit(self: *Capture) void {
        for (self.list.items) |line| self.gpa.free(line);
        self.list.deinit(self.gpa);
    }

    fn callback(ctx: ?*anyopaque, line: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const copy = self.gpa.dupe(u8, line) catch return;
        self.list.append(self.gpa, copy) catch self.gpa.free(copy);
    }
};

test "Progress: 10 MiB with known total emits ~20 lines, each formatted" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();

    var sink_buf: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buf);

    var prog_buf: [4096]u8 = undefined;
    var prog = Progress.init(
        &sink.writer,
        &prog_buf,
        "model.gguf",
        10 * MIB,
        Capture.callback,
        &cap,
    );

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xab);
    var written: u64 = 0;
    while (written < 10 * MIB) : (written += chunk.len) {
        try prog.writer.writeAll(&chunk);
    }
    try prog.writer.flush();

    try testing.expect(prog.lines >= 18 and prog.lines <= 22);
    try testing.expectEqual(@as(usize, prog.lines), cap.list.items.len);

    // Each line must include the percent-bearing format.
    var prev_pct: u32 = 0;
    for (cap.list.items) |line| {
        try testing.expect(std.mem.indexOf(u8, line, "MiB (") != null);
        try testing.expect(std.mem.endsWith(u8, line, "%)"));
        try testing.expect(std.mem.startsWith(u8, line, "memlite: download model.gguf: "));

        const open = std.mem.indexOfScalar(u8, line, '(').?;
        const close = std.mem.lastIndexOfScalar(u8, line, '%').?;
        const pct_str = line[open + 1 .. close];
        const pct = try std.fmt.parseInt(u32, pct_str, 10);
        try testing.expect(pct > prev_pct);
        prev_pct = pct;
    }
    try testing.expectEqual(@as(u32, 100), prev_pct);
}

test "Progress: unknown total emits one line per 5 MiB" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();

    var sink_buf: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buf);

    var prog_buf: [4096]u8 = undefined;
    var prog = Progress.init(
        &sink.writer,
        &prog_buf,
        "model.gguf",
        null,
        Capture.callback,
        &cap,
    );

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xab);
    var written: u64 = 0;
    while (written < 50 * MIB) : (written += chunk.len) {
        try prog.writer.writeAll(&chunk);
    }
    try prog.writer.flush();

    try testing.expect(prog.lines >= 9);
    for (cap.list.items) |line| {
        try testing.expect(std.mem.startsWith(u8, line, "memlite: download model.gguf: "));
        try testing.expect(std.mem.endsWith(u8, line, " MiB"));
        try testing.expect(std.mem.indexOf(u8, line, "%") == null);
    }
}
