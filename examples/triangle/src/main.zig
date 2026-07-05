const std = @import("std");
const knots = @import("knots");
const triangle = @import("triangle");

pub const std_options: std.Options = if (knots.platform.is_browser_wasm) .{ .logFn = knots.web.logFn } else .{};

pub const main = if (knots.platform.is_browser_wasm) struct {
    fn main() void {}
}.main else nativeMain;

fn nativeMain(init: std.process.Init) !void {
    var app = try triangle.init(init.io, init.gpa);
    defer app.deinit(init.gpa);

    try app.start();
}

comptime {
    if (knots.platform.is_browser_wasm) @export(&struct {
        fn webMain() callconv(.{ .wasm_mvp = .{} }) i32 {
            const allocator = std.heap.wasm_allocator;
            const ptr = allocator.create(triangle) catch |err| return knots.web.fail(err);
            ptr.* = triangle.init(knots.web.io, allocator) catch |err| {
                allocator.destroy(ptr);
                return knots.web.fail(err);
            };
            ptr.start() catch |err| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
                return knots.web.fail(err);
            };

            return 0;
        }
    }.webMain, .{ .name = "main" });
}
