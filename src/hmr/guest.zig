//! The exports of every HMR module. The host copies a request into `input`,
//! calls an export, and copies the result from `output`.

const std = @import("std");
const hmr = @import("hmr");
const source = @import("hmr_source").source;
const ui = @import("ui");

// Freestanding modules have no stderr.
pub const std_options: std.Options = .{ .logFn = log };

fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

const allocator = std.heap.wasm_allocator;

var input: std.ArrayList(u8) = .empty;
var output: std.ArrayList(u8) = .empty;
var guest: ?hmr.Guest = null;

const variables = @import("hmr_source").vars;

// The name is not a Zig identifier, so it cannot collide with a variable.
var widgets: ui.State.Saved = .{};
const carried = variables ++ .{.{ .name = "knots.widgets", .pointer = &widgets, .initial = 0 }};

export fn knots_hmr_fingerprint() u32 {
    return hmr.fingerprint;
}

export fn knots_hmr_init() u32 {
    if (guest != null)
        return 1;

    guest = hmr.Guest.init(allocator, &source.main) catch return 2;
    return 0;
}

export fn knots_hmr_deinit() void {
    if (@hasDecl(source, "deinit"))
        source.deinit();

    if (guest) |*value|
        value.deinit();

    guest = null;
}

export fn knots_hmr_input(length: u32) u32 {
    input.resize(allocator, length) catch return 0;
    return @intFromPtr(input.items.ptr);
}

export fn knots_hmr_output() u32 {
    return @intFromPtr(output.items.ptr);
}

export fn knots_hmr_output_length() u32 {
    return @intCast(output.items.len);
}

export fn knots_hmr_source() u32 {
    return @intFromPtr(@import("hmr_source").text.ptr);
}

export fn knots_hmr_source_length() u32 {
    return @intCast(@import("hmr_source").text.len);
}

export fn knots_hmr_frame() u32 {
    const active = if (guest) |*value| value else return 1;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    output.clearRetainingCapacity();
    const request = hmr.wire.decode(hmr.Request, arena.allocator(), input.items) catch return 2;
    const response = active.execute(&request) catch return 3;
    hmr.wire.encode(allocator, &output, response) catch return 4;
    return 0;
}

export fn knots_hmr_snapshot() u32 {
    output.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    defer widgets = .{};

    if (guest) |*active|
        widgets = active.executor.ui.state.save(arena.allocator()) catch return 2;

    hmr.transfer.snapshot(carried, allocator, &output) catch return 1;
    return 0;
}

export fn knots_hmr_restore() u32 {
    output.clearRetainingCapacity();
    defer {
        inline for (@typeInfo(ui.State.Saved).@"struct".field_names) |name|
            allocator.free(@field(widgets, name));

        widgets = .{};
    }

    hmr.transfer.restore(carried, input.items, allocator, &output) catch return 1;
    if (guest) |*active|
        active.executor.ui.state.load(&widgets) catch return 2;

    return 0;
}
