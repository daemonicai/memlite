const std = @import("std");
const mcp = @import("mcp.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdin_buf: [4 * 1024 * 1024]u8 = undefined; // 4 MiB — large memory_add payloads
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);

    try mcp.serve(gpa, &stdin_reader.interface, &stdout_writer.interface);
}
