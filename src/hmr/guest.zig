const std = @import("std");
const hmr = @import("hmr");
const source = @import("hmr_source").source;
const ui = @import("ui");

const Protocol = hmr.Protocol;

// Freestanding modules have no stderr. Logging must not pull in OS I/O.
pub const std_options: std.Options = .{ .logFn = log };

fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

comptime {
    if (@hasDecl(source, "main")) {
        const entry: *const fn (*ui.Frame) anyerror!void = &source.main;
        _ = entry;
        @export(&knots_hmr_module, .{ .name = "knots_hmr_module" });
        @export(&knots_hmr_version, .{ .name = "knots_hmr_version" });
        @export(&knots_hmr_init, .{ .name = "knots_hmr_init" });
        @export(&knots_hmr_input, .{ .name = "knots_hmr_input" });
        @export(&knots_hmr_frame, .{ .name = "knots_hmr_frame" });
        @export(&knots_hmr_output, .{ .name = "knots_hmr_output" });
        @export(&knots_hmr_output_length, .{ .name = "knots_hmr_output_length" });
        @export(&knots_hmr_deinit, .{ .name = "knots_hmr_deinit" });
        @export(&knots_hmr_source, .{ .name = "knots_hmr_source" });
        @export(&knots_hmr_source_length, .{ .name = "knots_hmr_source_length" });
    } else {
        @export(&knots_hmr_helper, .{ .name = "knots_hmr_helper" });
    }
}

fn knots_hmr_module() callconv(.c) u32 {
    return Protocol.version;
}

fn knots_hmr_helper() callconv(.c) u32 {
    return Protocol.version;
}

fn knots_hmr_source() callconv(.c) u32 {
    return @intFromPtr(@import("hmr_source").text.ptr);
}

fn knots_hmr_source_length() callconv(.c) u32 {
    return @intCast(@import("hmr_source").text.len);
}

var input: std.ArrayList(u8) = .empty;
var output: hmr.Wire.Writer = .{ .allocator = std.heap.wasm_allocator };
var module: ?hmr.Guest = null;

fn knots_hmr_version() callconv(.c) u32 {
    return Protocol.version;
}

fn knots_hmr_init() callconv(.c) u32 {
    if (module != null) return 1;
    module = hmr.Guest.init(std.heap.wasm_allocator, &source.main) catch return 2;
    return 0;
}

fn knots_hmr_input(length: u32) callconv(.c) u32 {
    if (length > Protocol.bytes_max) return 0;
    input.resize(std.heap.wasm_allocator, length) catch return 0;
    return @intFromPtr(input.items.ptr);
}

fn knots_hmr_frame() callconv(.c) u32 {
    const active = if (module) |*value| value else return 1;
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();
    output.data.clearRetainingCapacity();
    const request = hmr.FrameProtocol.decodeRequest(arena.allocator(), input.items) catch return 2;
    const result = active.execute(&request) catch return 3;
    hmr.FrameProtocol.encodeResponse(&output, &result) catch return 4;
    return 0;
}

fn knots_hmr_output() callconv(.c) u32 {
    return @intFromPtr(output.data.items.ptr);
}

fn knots_hmr_output_length() callconv(.c) u32 {
    return @intCast(output.data.items.len);
}

fn knots_hmr_deinit() callconv(.c) u32 {
    if (@hasDecl(source, "deinit")) source.deinit();
    if (module) |*value| value.deinit();
    module = null;
    input.deinit(std.heap.wasm_allocator);
    input = .empty;
    output.deinit();
    output = .{ .allocator = std.heap.wasm_allocator };
    return 0;
}
