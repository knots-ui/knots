const std = @import("std");
const knots = @import("knots");
const Playground = @import("Playground.zig");

pub const std_options: std.Options = if (knots.platform.is_wasm) .{ .logFn = knots.wasm.logFn } else .{};

pub const main = if (knots.platform.is_wasm) struct {
    fn main() void {}
}.main else nativeMain;

fn nativeMain(init: std.process.Init) !void {
    var playground = try Playground.init(init.io, init.gpa);
    defer playground.deinit();
    try playground.start();
}

comptime {
    if (knots.platform.is_wasm) @export(&webMain, .{ .name = "main" });
}

/// The page calls this once. The playground outlives it, so it lives on the heap.
fn webMain() callconv(.{ .wasm_mvp = .{} }) i32 {
    const allocator = knots.wasm.allocator;
    const playground = allocator.create(Playground) catch |err| return knots.wasm.fail(err);
    playground.* = Playground.init(knots.wasm.io, allocator) catch |err| {
        allocator.destroy(playground);
        return knots.wasm.fail(err);
    };
    playground.start() catch |err| {
        playground.deinit();
        allocator.destroy(playground);
        return knots.wasm.fail(err);
    };
    return 0;
}
