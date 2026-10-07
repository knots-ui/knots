const std = @import("std");
const knots = @import("knots");
const triangle = @import("triangle");

pub const std_options: std.Options = if (knots.platform.is_wasm) .{ .logFn = knots.wasm.logFn } else .{};

pub const main = if (knots.platform.is_wasm) struct {
    fn main() void {}
}.main else nativeMain;

fn nativeMain(init: std.process.Init) !void {
    var app = try triangle.init(init.io, init.gpa);
    defer app.deinit(init.gpa);

    try app.start();
}

comptime {
    if (knots.platform.is_wasm) @export(&struct {
        fn webMain() callconv(.{ .wasm_mvp = .{} }) i32 {
            const allocator = knots.wasm.allocator;
            const ptr = allocator.create(triangle) catch |err| return knots.wasm.fail(err);
            ptr.* = triangle.init(knots.wasm.io, allocator) catch |err| {
                allocator.destroy(ptr);
                return knots.wasm.fail(err);
            };
            ptr.start() catch |err| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
                return knots.wasm.fail(err);
            };

            return 0;
        }
    }.webMain, .{ .name = "main" });
}
