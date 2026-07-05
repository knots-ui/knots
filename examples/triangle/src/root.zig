const std = @import("std");
const knots = @import("knots");

const Rect = knots.component.Rect;
const Canvas = knots.component.Canvas;

const triangle_width = 480;
const triangle_height = 320;

app: knots.App,
devtools: knots.debug.DevTools,

const Self = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
    var app = try knots.App.init(io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Triangle",
        },
    });
    errdefer app.deinit();

    return .{
        .app = app,
        .devtools = try .init(allocator, app.viewport.renderer.cfg.present_mode),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.devtools.deinit(allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const ctx: *Self = @fieldParentPtr("app", app);
    const size = app.viewport.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .fixed(w),
            .height = .fixed(h),
            .@"align" = .center,
            .justify = .center,
        },
        .{Canvas{
            .onDraw = drawTriangle,
            .key = .src(@src()),
            .width = .fixed(triangle_width),
            .height = .fixed(triangle_height),
        }},
    });

    try app.e(.{ctx.devtools});
}

fn drawTriangle(_: *knots.App, painter: *Canvas.Painter) !void {
    try painter.fillTriangle(.{
        .points = .{
            .{ triangle_width / 2.0, 0.0 },
            .{ triangle_width, triangle_height },
            .{ 0.0, triangle_height },
        },
        .color = .{ 1.0, 0, 0, 1.0 },
    });
}
