const std = @import("std");
const knots = @import("knots");

const Rect = knots.component.Rect;
const Canvas = knots.component.Canvas;

const triangle_width = 480;
const triangle_height = 320;

const Context = struct {
    app: knots.App,
    devtools: knots.debug.DevTools,
};

pub fn main(init: std.process.Init) !void {
    const app = try knots.App.init(init.io, init.gpa, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Triangle",
        },
    });
    var ctx = Context{
        .app = app,
        .devtools = try .init(init.gpa, app.renderer.cfg.present_mode),
    };
    defer {
        ctx.app.deinit();
        ctx.devtools.deinit(init.gpa);
    }

    try ctx.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const ctx: *Context = @fieldParentPtr("app", app);
    const size = app.window.getSize();
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
