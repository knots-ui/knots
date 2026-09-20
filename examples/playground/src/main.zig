const std = @import("std");
const knots = @import("knots");
const playground = @import("playground");

pub const std_options: std.Options = if (knots.platform.is_browser_wasm) .{ .logFn = knots.web.logFn } else .{};

pub const main = if (knots.platform.is_browser_wasm) struct {
    fn main() void {}
}.main else nativeMain;

fn nativeMain(init: std.process.Init) !void {
    var app = try playground.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    try app.start();
}

comptime {
    if (knots.platform.is_browser_wasm) {
        @export(&struct {
            fn webMain() callconv(.{ .wasm_mvp = .{} }) i32 {
                const allocator = knots.web.allocator;
                const app = allocator.create(playground) catch |err| return knots.web.fail(err);
                app.* = playground.init(knots.web.io, allocator, &.{}) catch |err| {
                    allocator.destroy(app);
                    return knots.web.fail(err);
                };
                app.start() catch |err| {
                    app.deinit();
                    allocator.destroy(app);
                    return knots.web.fail(err);
                };
                return 0;
            }
        }.webMain, .{ .name = "main" });
    }
}
