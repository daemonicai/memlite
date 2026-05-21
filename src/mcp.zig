//! Minimal MCP server scaffold: newline-delimited JSON-RPC 2.0 over stdio.
//!
//! v1-foundation §3 — exposes a single placeholder tool (`echo`) so we can
//! prove the transport works against `claude` / MCP inspector before the real
//! memory tools land in later groups.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Json = std.json;
const Stringify = Json.Stringify;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const PROTOCOL_VERSION = "2025-11-25";
pub const SERVER_NAME = "memlite";
pub const SERVER_VERSION = "0.1.0";

// JSON-RPC 2.0 standard error codes (transport-level; integer per RFC).
const code_parse_error = -32700;
const code_invalid_request = -32600;
const code_method_not_found = -32601;
const code_invalid_params = -32602;

/// v1 vocabulary of application-level error codes. The mcp-server spec
/// pins these as STRING codes inside the standard JSON-RPC error object —
/// non-standard, but explicitly required so callers can branch on a
/// stable enum rather than parsing free-text messages.
pub const AppError = enum {
    slug_exists,
    not_found,
    invalid_target,
    embedding_failed,
    invalid_format,
    invalid_url,
    model_mismatch,

    pub fn codeString(self: AppError) []const u8 {
        return switch (self) {
            .slug_exists => "SLUG_EXISTS",
            .not_found => "NOT_FOUND",
            .invalid_target => "INVALID_TARGET",
            .embedding_failed => "EMBEDDING_FAILED",
            .invalid_format => "INVALID_FORMAT",
            .invalid_url => "INVALID_URL",
            .model_mismatch => "MODEL_MISMATCH",
        };
    }
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema for the tool's `arguments` object. Emitted via
    /// Stringify.beginWriteRaw so we don't have to round-trip through Value.
    input_schema_json: []const u8,
};

const tools: []const Tool = &.{
    .{
        .name = "echo",
        .description = "Echo a text argument back to the caller. Placeholder for the v1-foundation MCP scaffold; replaced by the real memory tools in later groups.",
        .input_schema_json =
        \\{"type":"object","properties":{"text":{"type":"string","description":"Text to echo back."}},"required":["text"]}
        ,
    },
};

/// Run the JSON-RPC loop until stdin closes.
pub fn serve(gpa: Allocator, in: *Reader, out: *Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();

        const maybe_line = in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                writeError(out, .null, code_parse_error, "Request line exceeds buffer") catch {};
                out.flush() catch {};
                return err;
            },
            error.ReadFailed => return err,
        };
        const line = maybe_line orelse return; // EOF
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        handleLine(aa, trimmed, out) catch |err| {
            std.log.err("mcp: handleLine failed: {s}", .{@errorName(err)});
        };
        out.flush() catch {};
    }
}

fn handleLine(aa: Allocator, line: []const u8, out: *Writer) !void {
    const parsed: Json.Value = Json.parseFromSliceLeaky(Json.Value, aa, line, .{}) catch {
        try writeError(out, .null, code_parse_error, "Parse error");
        return;
    };

    if (parsed != .object) {
        try writeError(out, .null, code_invalid_request, "Request must be a JSON object");
        return;
    }
    const obj = parsed.object;
    const id = obj.get("id");
    const method_v = obj.get("method") orelse return; // response or malformed — ignore

    if (method_v != .string) {
        if (id) |i| try writeError(out, i, code_invalid_request, "method must be a string");
        return;
    }
    const method = method_v.string;
    const params = obj.get("params");

    if (id == null) {
        // Notification — handle if known, but never reply.
        return;
    }
    const req_id = id.?;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(out, req_id);
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeEmptyResult(out, req_id);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeToolsList(out, req_id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(out, req_id, params);
    } else {
        try writeError(out, req_id, code_method_not_found, method);
    }
}

fn beginResponse(s: *Stringify, id: Json.Value) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
}

fn writeInitialize(out: *Writer, id: Json.Value) !void {
    var s: Stringify = .{ .writer = out };
    try beginResponse(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write(PROTOCOL_VERSION);
    try s.objectField("capabilities");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("serverInfo");
    try s.beginObject();
    try s.objectField("name");
    try s.write(SERVER_NAME);
    try s.objectField("version");
    try s.write(SERVER_VERSION);
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

fn writeEmptyResult(out: *Writer, id: Json.Value) !void {
    var s: Stringify = .{ .writer = out };
    try beginResponse(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

fn writeToolsList(out: *Writer, id: Json.Value) !void {
    var s: Stringify = .{ .writer = out };
    try beginResponse(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (tools) |t| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name);
        try s.objectField("description");
        try s.write(t.description);
        try s.objectField("inputSchema");
        try s.beginWriteRaw();
        try out.writeAll(t.input_schema_json);
        s.endWriteRaw();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

fn handleToolsCall(out: *Writer, id: Json.Value, params: ?Json.Value) !void {
    if (params == null or params.? != .object) {
        return writeError(out, id, code_invalid_params, "tools/call requires a params object");
    }
    const p = params.?.object;
    const name_v = p.get("name") orelse {
        return writeError(out, id, code_invalid_params, "tools/call: missing name");
    };
    if (name_v != .string) {
        return writeError(out, id, code_invalid_params, "tools/call: name must be a string");
    }
    const tool_name = name_v.string;
    const args = p.get("arguments");

    if (std.mem.eql(u8, tool_name, "echo")) {
        return runEcho(out, id, args);
    }
    return writeError(out, id, code_method_not_found, tool_name);
}

fn runEcho(out: *Writer, id: Json.Value, args: ?Json.Value) !void {
    const text: []const u8 = blk: {
        if (args) |a| if (a == .object) {
            if (a.object.get("text")) |t| if (t == .string) break :blk t.string;
        };
        break :blk "";
    };

    var s: Stringify = .{ .writer = out };
    try beginResponse(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.objectField("isError");
    try s.write(false);
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

fn writeError(out: *Writer, id: Json.Value, code: i64, message: []const u8) !void {
    var s: Stringify = .{ .writer = out };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

/// Application-level error envelope: same JSON-RPC error object, but
/// `code` is a v1-vocabulary string rather than a JSON-RPC integer.
/// Used for SLUG_EXISTS, EMBEDDING_FAILED, etc.
pub fn writeAppError(out: *Writer, id: Json.Value, app: AppError, message: []const u8) !void {
    var s: Stringify = .{ .writer = out };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(app.codeString());
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}
