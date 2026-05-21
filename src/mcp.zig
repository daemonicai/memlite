//! MCP server: newline-delimited JSON-RPC 2.0 over stdio.
//!
//! v1-foundation §3 (transport) + §8 (lifecycle tools). The protocol shell
//! lives here; tool semantics live in tools.zig. Group 10/11/12 will add
//! search / list / status onto the same surface.

const std = @import("std");
const tools_mod = @import("tools.zig");

const Allocator = std.mem.Allocator;
const Json = std.json;
const Stringify = Json.Stringify;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Tools = tools_mod.Tools;
const ToolsError = tools_mod.Error;

pub const PROTOCOL_VERSION = "2025-11-25";
pub const SERVER_NAME = "memlite";
pub const SERVER_VERSION = "0.1.0";

const code_parse_error = -32700;
const code_invalid_request = -32600;
const code_method_not_found = -32601;
const code_invalid_params = -32602;

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

/// Map a Tools error to the v1 application error code. Unmapped/Sqlite
/// errors fall through to JSON-RPC internal-error -32603 via the caller.
fn appErrorFor(err: ToolsError) ?AppError {
    return switch (err) {
        ToolsError.SlugExists => .slug_exists,
        ToolsError.NotFound => .not_found,
        ToolsError.InvalidTarget => .invalid_target,
        ToolsError.InvalidFormat => .invalid_format,
        ToolsError.EmbeddingFailed => .embedding_failed,
        ToolsError.Sqlite, ToolsError.OutOfMemory => null,
    };
}

const ToolDescriptor = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema for the tool's `arguments`. Emitted via beginWriteRaw.
    input_schema_json: []const u8,
};

const tool_list: []const ToolDescriptor = &.{
    .{
        .name = "memory_add",
        .description = "Add a memory. v1-foundation §8.1 — text format only; markdown lands in §9.",
        .input_schema_json =
        \\{"type":"object","properties":{"content":{"type":"string"},"format":{"type":"string","enum":["text","markdown"],"default":"text"},"slug":{"type":"string","description":"Optional logical name; must be unique across live memories."},"tags":{"type":"object","additionalProperties":{"oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]}}},"required":["content"]}
        ,
    },
    .{
        .name = "memory_get",
        .description = "Fetch a memory by id or slug. Bumps last_accessed.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]}},"required":["target"]}
        ,
    },
    .{
        .name = "memory_delete",
        .description = "Soft-delete a memory; a snapshot row is created in memories_history via trigger.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]}},"required":["target"]}
        ,
    },
    .{
        .name = "memory_clear",
        .description = "Delete all memories. retain_history defaults to true (history table is kept).",
        .input_schema_json =
        \\{"type":"object","properties":{"retain_history":{"type":"boolean","default":true}}}
        ,
    },
    .{
        .name = "memory_update",
        .description = "Partial update: any of content/format/slug/tags. Content or format change re-embeds.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]},"content":{"type":"string"},"format":{"type":"string","enum":["text","markdown"]},"slug":{"type":["string","null"],"description":"Pass null to clear the slug."},"tags":{"type":"object","description":"Full replacement when supplied."}},"required":["target"]}
        ,
    },
    .{
        .name = "memory_tag",
        .description = "Idempotently add a single (key, value) tag to a memory.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]},"key":{"type":"string"},"value":{"type":"string"}},"required":["target","key","value"]}
        ,
    },
    .{
        .name = "memory_list",
        .description = "Administrative read. Returns memories filtered by tags / since, ordered by created|updated|last_accessed (default updated). Does NOT bump last_accessed.",
        .input_schema_json =
        \\{"type":"object","properties":{"where":{"type":"object","additionalProperties":{"oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]}},"since":{"type":"integer","description":"Unix epoch; only memories with order_by column >= since are returned."},"limit":{"type":"integer","default":50},"offset":{"type":"integer","default":0},"order_by":{"type":"string","enum":["created","updated","last_accessed"],"default":"updated"}}}
        ,
    },
    .{
        .name = "list_tags",
        .description = "All distinct tag keys with the count of distinct memories carrying each key, sorted by memory_count desc.",
        .input_schema_json = "{\"type\":\"object\"}",
    },
    .{
        .name = "list_tag_values",
        .description = "All distinct values for a tag key, with the count of distinct memories carrying each value.",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
    },
    .{
        .name = "list_tag_siblings",
        .description = "Tags that co-occur on memories carrying the (key, value) pair, excluding the input pair only.",
        .input_schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"}},"required":["key","value"]}
        ,
    },
    .{
        .name = "memory_history",
        .description = "Snapshots from memories_history matching the target (slug or memory_id), most-recent-first.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]}},"required":["target"]}
        ,
    },
    .{
        .name = "memory_status",
        .description = "Aggregate counts (memories, chunks, tags, history), embedding model + dim, and on-disk DB size.",
        .input_schema_json = "{\"type\":\"object\"}",
    },
    .{
        .name = "memory_search",
        .description = "Hybrid semantic + full-text search. Embeds the query, retrieves chunks from vec0 + fts5, merges via RRF (k=60), groups by memory.",
        .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string"},"where":{"type":"object","description":"Tag filter: {key: string | [string,...]} — keys are AND-combined; values within a key are OR.","additionalProperties":{"oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]}},"limit":{"type":"integer","default":10},"oversample":{"type":"integer","default":3}},"required":["query"]}
        ,
    },
    .{
        .name = "memory_untag",
        .description = "Remove a single (key, value) tag — or all values for a key when value is omitted.",
        .input_schema_json =
        \\{"type":"object","properties":{"target":{"oneOf":[{"type":"integer"},{"type":"string"}]},"key":{"type":"string"},"value":{"type":"string"}},"required":["target","key"]}
        ,
    },
};

pub fn serve(
    gpa: Allocator,
    in: *Reader,
    out: *Writer,
    tools: *Tools,
) !void {
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
        const line = maybe_line orelse return;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        handleLine(aa, trimmed, out, tools) catch |err| {
            std.log.err("mcp: handleLine: {s}", .{@errorName(err)});
        };
        out.flush() catch {};
    }
}

fn handleLine(
    aa: Allocator,
    line: []const u8,
    out: *Writer,
    tools: *Tools,
) !void {
    const parsed: Json.Value = Json.parseFromSliceLeaky(Json.Value, aa, line, .{}) catch {
        try writeError(out, .null, code_parse_error, "Parse error");
        return;
    };
    if (parsed != .object) {
        try writeError(out, .null, code_invalid_request, "Request must be a JSON object");
        return;
    }
    const obj = parsed.object;
    const id_opt = obj.get("id");
    const method_v = obj.get("method") orelse return; // response — ignore
    if (method_v != .string) {
        if (id_opt) |i| try writeError(out, i, code_invalid_request, "method must be a string");
        return;
    }
    const method = method_v.string;
    const params = obj.get("params");
    if (id_opt == null) return; // notification
    const id = id_opt.?;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(out, id);
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeEmptyResult(out, id);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeToolsList(out, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(aa, out, id, params, tools);
    } else {
        try writeError(out, id, code_method_not_found, method);
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
    for (tool_list) |t| {
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

fn handleToolsCall(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    params: ?Json.Value,
    tools: *Tools,
) !void {
    if (params == null or params.? != .object) {
        return writeError(out, id, code_invalid_params, "tools/call requires a params object");
    }
    const p = params.?.object;
    const name_v = p.get("name") orelse return writeError(out, id, code_invalid_params, "missing name");
    if (name_v != .string) return writeError(out, id, code_invalid_params, "name must be a string");
    const tool_name = name_v.string;
    const args = p.get("arguments");

    if (std.mem.eql(u8, tool_name, "memory_add")) {
        return callMemoryAdd(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_get")) {
        return callMemoryGet(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_delete")) {
        return callMemoryDelete(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_clear")) {
        return callMemoryClear(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_update")) {
        return callMemoryUpdate(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_tag")) {
        return callMemoryTag(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_untag")) {
        return callMemoryUntag(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_search")) {
        return callMemorySearch(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_list")) {
        return callMemoryList(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "list_tags")) {
        return callListTags(aa, out, id, tools);
    } else if (std.mem.eql(u8, tool_name, "list_tag_values")) {
        return callListTagValues(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "list_tag_siblings")) {
        return callListTagSiblings(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_history")) {
        return callMemoryHistory(aa, out, id, args, tools);
    } else if (std.mem.eql(u8, tool_name, "memory_status")) {
        return callMemoryStatus(aa, out, id, tools);
    }
    return writeError(out, id, code_method_not_found, tool_name);
}

// =====================================================================
// Per-tool dispatch
// =====================================================================

fn callMemoryAdd(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;

    const content_v = obj.get("content") orelse return writeError(out, id, code_invalid_params, "missing content");
    if (content_v != .string) return writeError(out, id, code_invalid_params, "content must be a string");

    var add_args: tools_mod.Tools.AddArgs = .{ .content = content_v.string };

    if (obj.get("format")) |f| {
        if (f != .string) return writeError(out, id, code_invalid_params, "format must be a string");
        add_args.format = f.string;
    }
    if (obj.get("slug")) |s| switch (s) {
        .string => |str| add_args.slug = str,
        .null => {},
        else => return writeError(out, id, code_invalid_params, "slug must be a string"),
    };
    if (obj.get("tags")) |t| {
        add_args.tags = parseTagPairs(aa, t) catch |err| return writeError(out, id, code_invalid_params, @errorName(err));
    }

    const result = tools.memoryAdd(aa, add_args) catch |err| {
        return finalizeToolError(out, id, err);
    };

    try writeToolResult(out, id, .{ .memory_add = result });
}

fn callMemoryGet(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };
    const result = tools.memoryGet(aa, target) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_get = result });
}

fn callMemoryDelete(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    _ = aa;
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };
    const result = tools.memoryDelete(target) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_delete = result });
}

fn callMemoryClear(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    _ = aa;
    var retain_history = true;
    if (args) |a| if (a == .object) {
        if (a.object.get("retain_history")) |v| {
            if (v != .bool) return writeError(out, id, code_invalid_params, "retain_history must be a boolean");
            retain_history = v.bool;
        }
    };
    const result = tools.memoryClear(retain_history) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_clear = result });
}

fn callMemoryUpdate(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };

    var ua: tools_mod.Tools.UpdateArgs = .{};
    if (obj.get("content")) |v| {
        if (v != .string) return writeError(out, id, code_invalid_params, "content must be a string");
        ua.content = v.string;
    }
    if (obj.get("format")) |v| {
        if (v != .string) return writeError(out, id, code_invalid_params, "format must be a string");
        ua.format = v.string;
    }
    if (obj.get("slug")) |v| switch (v) {
        .string => |s| ua.slug = .{ .set = s },
        .null => ua.slug = .clear,
        else => return writeError(out, id, code_invalid_params, "slug must be string or null"),
    };
    if (obj.get("tags")) |v| {
        ua.tags = parseTagPairs(aa, v) catch |e| return writeError(out, id, code_invalid_params, @errorName(e));
    }

    const result = tools.memoryUpdate(aa, target, ua) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_update = result });
}

fn callMemoryTag(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    _ = aa;
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };
    const key_v = obj.get("key") orelse return writeError(out, id, code_invalid_params, "missing key");
    const val_v = obj.get("value") orelse return writeError(out, id, code_invalid_params, "missing value");
    if (key_v != .string or val_v != .string) return writeError(out, id, code_invalid_params, "key and value must be strings");
    const result = tools.memoryTag(target, key_v.string, val_v.string) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_tag = result });
}

fn callMemoryUntag(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    _ = aa;
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };
    const key_v = obj.get("key") orelse return writeError(out, id, code_invalid_params, "missing key");
    if (key_v != .string) return writeError(out, id, code_invalid_params, "key must be a string");
    var value: ?[]const u8 = null;
    if (obj.get("value")) |v| switch (v) {
        .string => |s| value = s,
        .null => {},
        else => return writeError(out, id, code_invalid_params, "value must be a string or null"),
    };
    const result = tools.memoryUntag(target, key_v.string, value) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_untag = result });
}

fn callMemorySearch(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const query_v = obj.get("query") orelse return writeError(out, id, code_invalid_params, "missing query");
    if (query_v != .string) return writeError(out, id, code_invalid_params, "query must be a string");

    var sa: tools_mod.Tools.SearchArgs = .{ .query = query_v.string };

    if (obj.get("limit")) |v| switch (v) {
        .integer => |n| sa.limit = if (n <= 0) 10 else @intCast(n),
        else => return writeError(out, id, code_invalid_params, "limit must be an integer"),
    };
    if (obj.get("oversample")) |v| switch (v) {
        .integer => |n| sa.oversample = if (n <= 0) 3 else @intCast(n),
        else => return writeError(out, id, code_invalid_params, "oversample must be an integer"),
    };

    if (obj.get("where")) |w| {
        sa.where = parseTagFilters(aa, w) catch |err| return writeError(out, id, code_invalid_params, @errorName(err));
    }

    const result = tools.memorySearch(aa, sa) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_search = result });
}

fn callMemoryList(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    var la: tools_mod.Tools.ListArgs = .{};
    if (args) |a| if (a == .object) {
        const obj = a.object;
        if (obj.get("limit")) |v| switch (v) {
            .integer => |n| la.limit = if (n <= 0) 50 else @intCast(n),
            else => return writeError(out, id, code_invalid_params, "limit must be integer"),
        };
        if (obj.get("offset")) |v| switch (v) {
            .integer => |n| la.offset = if (n < 0) 0 else @intCast(n),
            else => return writeError(out, id, code_invalid_params, "offset must be integer"),
        };
        if (obj.get("since")) |v| switch (v) {
            .integer => |n| la.since = n,
            else => return writeError(out, id, code_invalid_params, "since must be integer"),
        };
        if (obj.get("order_by")) |v| switch (v) {
            .string => |s| {
                if (std.mem.eql(u8, s, "created")) la.order_by = .created
                else if (std.mem.eql(u8, s, "updated")) la.order_by = .updated
                else if (std.mem.eql(u8, s, "last_accessed")) la.order_by = .last_accessed
                else return writeError(out, id, code_invalid_params, "order_by must be created|updated|last_accessed");
            },
            else => return writeError(out, id, code_invalid_params, "order_by must be string"),
        };
        if (obj.get("where")) |w| {
            la.where = parseTagFilters(aa, w) catch |err| return writeError(out, id, code_invalid_params, @errorName(err));
        }
    };
    const result = tools.memoryList(aa, la) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_list = result });
}

fn callListTags(aa: Allocator, out: *Writer, id: Json.Value, tools: *Tools) !void {
    const result = tools.listTags(aa) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .list_tags = result });
}

fn callListTagValues(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const key_v = obj.get("key") orelse return writeError(out, id, code_invalid_params, "missing key");
    if (key_v != .string) return writeError(out, id, code_invalid_params, "key must be a string");
    const result = tools.listTagValues(aa, key_v.string) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .list_tag_values = result });
}

fn callListTagSiblings(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const key_v = obj.get("key") orelse return writeError(out, id, code_invalid_params, "missing key");
    const val_v = obj.get("value") orelse return writeError(out, id, code_invalid_params, "missing value");
    if (key_v != .string or val_v != .string) return writeError(out, id, code_invalid_params, "key and value must be strings");
    const result = tools.listTagSiblings(aa, key_v.string, val_v.string) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .list_tag_siblings = result });
}

fn callMemoryHistory(
    aa: Allocator,
    out: *Writer,
    id: Json.Value,
    args: ?Json.Value,
    tools: *Tools,
) !void {
    const obj = (args orelse return writeError(out, id, code_invalid_params, "missing arguments")).object;
    const target = parseTarget(obj.get("target")) catch |e| {
        return writeAppError(out, id, .invalid_target, @errorName(e));
    };
    const result = tools.memoryHistory(aa, target) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_history = result });
}

fn callMemoryStatus(aa: Allocator, out: *Writer, id: Json.Value, tools: *Tools) !void {
    const result = tools.memoryStatus(aa) catch |err| return finalizeToolError(out, id, err);
    try writeToolResult(out, id, .{ .memory_status = result });
}

fn parseTagFilters(aa: Allocator, v: Json.Value) ![]const tools_mod.Tools.TagFilter {
    if (v != .object) return error.WhereMustBeObject;
    var list: std.ArrayList(tools_mod.Tools.TagFilter) = .empty;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .string => |s| {
                const vals = try aa.alloc([]const u8, 1);
                vals[0] = s;
                try list.append(aa, .{ .key = key, .values = vals });
            },
            .array => |arr| {
                const vals = try aa.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |it_v, i| {
                    if (it_v != .string) return error.TagFilterValueMustBeString;
                    vals[i] = it_v.string;
                }
                try list.append(aa, .{ .key = key, .values = vals });
            },
            else => return error.TagFilterValueMustBeStringOrArray,
        }
    }
    return try list.toOwnedSlice(aa);
}

// =====================================================================
// Result + error serialization
// =====================================================================

const ToolResult = union(enum) {
    memory_add: tools_mod.Tools.AddResult,
    memory_get: tools_mod.Tools.GetResult,
    memory_delete: tools_mod.Tools.DeleteResult,
    memory_clear: tools_mod.Tools.ClearResult,
    memory_update: tools_mod.Tools.UpdateResult,
    memory_tag: tools_mod.Tools.TagResult,
    memory_untag: tools_mod.Tools.UntagResult,
    memory_search: tools_mod.Tools.SearchResult,
    memory_list: tools_mod.Tools.ListResult,
    list_tags: []const tools_mod.Tools.KeyCount,
    list_tag_values: []const tools_mod.Tools.ValueCount,
    list_tag_siblings: []const tools_mod.Tools.Sibling,
    memory_history: []const tools_mod.Tools.HistoryEntry,
    memory_status: tools_mod.Tools.Status,
};

fn writeToolResult(out: *Writer, id: Json.Value, result: ToolResult) !void {
    // Build the typed payload once into a heap buffer so we can emit it
    // both as `structuredContent` (raw JSON) and as the JSON-encoded
    // string in `content[0].text` without serializing twice.
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    {
        var ps: Stringify = .{ .writer = &aw.writer };
        try emitResultPayload(&ps, result);
    }
    const payload = aw.written();

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
    try s.write(payload); // emitted as a JSON-encoded string
    try s.endObject();
    try s.endArray();

    try s.objectField("structuredContent");
    try s.beginWriteRaw();
    try out.writeAll(payload);
    s.endWriteRaw();

    try s.objectField("isError");
    try s.write(false);
    try s.endObject(); // result
    try s.endObject(); // envelope
    try out.writeByte('\n');
}

fn emitResultPayload(s: *Stringify, result: ToolResult) !void {
    switch (result) {
        .memory_add => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("slug");
            if (r.slug) |slug| try s.write(slug) else try s.write(null);
            try s.objectField("format");
            try s.write(r.format);
            try s.objectField("chunks_created");
            try s.write(r.chunks_created);
            try s.objectField("tags_created");
            try s.write(r.tags_created);
            try s.endObject();
        },
        .memory_get => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("slug");
            if (r.slug) |slug| try s.write(slug) else try s.write(null);
            try s.objectField("format");
            try s.write(r.format);
            try s.objectField("content");
            try s.write(r.content);
            try s.objectField("tags");
            try s.beginWriteRaw();
            try s.writer.writeAll(r.tags_json);
            s.endWriteRaw();
            try s.objectField("created");
            try s.write(r.created);
            try s.objectField("updated");
            try s.write(r.updated);
            try s.objectField("last_accessed");
            try s.write(r.last_accessed);
            try s.endObject();
        },
        .memory_delete => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("history_id");
            try s.write(r.history_id);
            try s.endObject();
        },
        .memory_clear => |r| {
            try s.beginObject();
            try s.objectField("removed_count");
            try s.write(r.removed_count);
            try s.objectField("history_kept");
            try s.write(r.history_kept);
            try s.endObject();
        },
        .memory_update => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("chunks_replaced");
            try s.write(r.chunks_replaced);
            try s.objectField("tags_replaced");
            try s.write(r.tags_replaced);
            try s.endObject();
        },
        .memory_tag => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("idempotent");
            try s.write(r.idempotent);
            try s.endObject();
        },
        .memory_untag => |r| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(r.id);
            try s.objectField("removed_count");
            try s.write(r.removed_count);
            try s.endObject();
        },
        .memory_list => |r| {
            try s.beginObject();
            try s.objectField("memories");
            try s.beginArray();
            for (r.memories) |m| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(m.id);
                try s.objectField("slug");
                if (m.slug) |slug| try s.write(slug) else try s.write(null);
                try s.objectField("format");
                try s.write(m.format);
                try s.objectField("content");
                try s.write(m.content);
                try s.objectField("tags");
                try s.beginWriteRaw();
                try s.writer.writeAll(m.tags_json);
                s.endWriteRaw();
                try s.objectField("created");
                try s.write(m.created);
                try s.objectField("updated");
                try s.write(m.updated);
                try s.objectField("last_accessed");
                try s.write(m.last_accessed);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        },
        .list_tags => |r| {
            try s.beginArray();
            for (r) |kc| {
                try s.beginObject();
                try s.objectField("key");
                try s.write(kc.key);
                try s.objectField("memory_count");
                try s.write(kc.memory_count);
                try s.endObject();
            }
            try s.endArray();
        },
        .list_tag_values => |r| {
            try s.beginArray();
            for (r) |vc| {
                try s.beginObject();
                try s.objectField("value");
                try s.write(vc.value);
                try s.objectField("memory_count");
                try s.write(vc.memory_count);
                try s.endObject();
            }
            try s.endArray();
        },
        .list_tag_siblings => |r| {
            try s.beginArray();
            for (r) |sib| {
                try s.beginObject();
                try s.objectField("key");
                try s.write(sib.key);
                try s.objectField("value");
                try s.write(sib.value);
                try s.objectField("co_occurrence_count");
                try s.write(sib.co_occurrence_count);
                try s.endObject();
            }
            try s.endArray();
        },
        .memory_history => |r| {
            try s.beginArray();
            for (r) |h| {
                try s.beginObject();
                try s.objectField("history_id");
                try s.write(h.id);
                try s.objectField("memory_id");
                try s.write(h.memory_id);
                try s.objectField("slug");
                if (h.slug) |slug| try s.write(slug) else try s.write(null);
                try s.objectField("format");
                try s.write(h.format);
                try s.objectField("content");
                try s.write(h.content);
                try s.objectField("tags_snapshot");
                try s.beginWriteRaw();
                try s.writer.writeAll(h.tags_snapshot);
                s.endWriteRaw();
                try s.objectField("created");
                try s.write(h.created);
                try s.objectField("updated");
                try s.write(h.updated);
                try s.objectField("last_accessed");
                try s.write(h.last_accessed);
                try s.objectField("archived_at");
                try s.write(h.archived_at);
                try s.objectField("archive_reason");
                try s.write(h.archive_reason);
                try s.endObject();
            }
            try s.endArray();
        },
        .memory_status => |r| {
            try s.beginObject();
            try s.objectField("total_memories");
            try s.write(r.total_memories);
            try s.objectField("total_chunks");
            try s.write(r.total_chunks);
            try s.objectField("total_tags");
            try s.write(r.total_tags);
            try s.objectField("history_entries");
            try s.write(r.history_entries);
            try s.objectField("embedding_model");
            try s.write(r.embedding_model);
            try s.objectField("embedding_dim");
            try s.write(r.embedding_dim);
            try s.objectField("database_size_bytes");
            try s.write(r.database_size_bytes);
            try s.objectField("by_format");
            try s.beginObject();
            try s.objectField("text");
            try s.write(r.text_count);
            try s.objectField("markdown");
            try s.write(r.markdown_count);
            try s.endObject();
            try s.endObject();
        },
        .memory_search => |r| {
            try s.beginObject();
            try s.objectField("memories");
            try s.beginArray();
            for (r.memories) |m| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(m.id);
                try s.objectField("slug");
                if (m.slug) |slug| try s.write(slug) else try s.write(null);
                try s.objectField("format");
                try s.write(m.format);
                try s.objectField("content");
                try s.write(m.content);
                try s.objectField("tags");
                try s.beginWriteRaw();
                try s.writer.writeAll(m.tags_json);
                s.endWriteRaw();
                try s.objectField("score");
                try s.write(m.score);
                try s.objectField("matches");
                try s.beginArray();
                for (m.matches) |ch| {
                    try s.beginObject();
                    try s.objectField("ord");
                    try s.write(ch.ord);
                    try s.objectField("text");
                    try s.write(ch.text);
                    try s.objectField("score");
                    try s.write(ch.score);
                    try s.endObject();
                }
                try s.endArray();
                try s.objectField("created");
                try s.write(m.created);
                try s.objectField("updated");
                try s.write(m.updated);
                try s.objectField("last_accessed");
                try s.write(m.last_accessed);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        },
    }
}

fn finalizeToolError(out: *Writer, id: Json.Value, err: ToolsError) !void {
    if (appErrorFor(err)) |app| {
        try writeAppError(out, id, app, @errorName(err));
    } else {
        try writeError(out, id, -32603, @errorName(err));
    }
}

// =====================================================================
// Argument helpers
// =====================================================================

fn parseTarget(v: ?Json.Value) !tools_mod.Target {
    const val = v orelse return error.MissingTarget;
    return switch (val) {
        .integer => |n| .{ .id = n },
        .string => |s| .{ .slug = s },
        else => error.InvalidTarget,
    };
}

fn parseTagPairs(aa: Allocator, v: Json.Value) ![]const tools_mod.TagPair {
    if (v != .object) return error.TagsMustBeObject;
    var list: std.ArrayList(tools_mod.TagPair) = .empty;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .string => |s| try list.append(aa, .{ .key = key, .value = s }),
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .string) return error.TagValueMustBeString;
                    try list.append(aa, .{ .key = key, .value = item.string });
                }
            },
            else => return error.TagValueMustBeStringOrArray,
        }
    }
    return try list.toOwnedSlice(aa);
}

// =====================================================================
// JSON-RPC error envelopes
// =====================================================================

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
