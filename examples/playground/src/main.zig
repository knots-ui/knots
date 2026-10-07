const std = @import("std");
const knots = @import("knots");
const playground = @import("playground");

pub const std_options: std.Options = if (knots.platform.is_wasm) .{ .logFn = knots.wasm.logFn } else .{};

pub const main = if (knots.platform.is_wasm) struct {
    fn main() void {}
}.main else nativeMain;

fn nativeMain(init: std.process.Init) !void {
    var app = try playground.init(init.io, init.gpa);
    defer app.deinit();
    try app.start();
}

comptime {
    if (knots.platform.is_wasm) {
        @export(&struct {
            fn webMain() callconv(.{ .wasm_mvp = .{} }) i32 {
                const allocator = knots.wasm.allocator;
                const app = allocator.create(playground) catch |err| return knots.wasm.fail(err);
                app.* = playground.init(knots.wasm.io, allocator) catch |err| {
                    allocator.destroy(app);
                    return knots.wasm.fail(err);
                };
                app.start() catch |err| {
                    app.deinit();
                    allocator.destroy(app);
                    return knots.wasm.fail(err);
                };
                return 0;
            }
        }.webMain, .{ .name = "main" });
    }
}
