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
        .devtools = try .init(allocator, app.presentMode()),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.devtools.deinit(allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

fn frameCb(app: *knots.App, frame: *knots.Frame) !void {
    const ctx: *Self = @fieldParentPtr("app", app);
    const size = app.logicalExtent();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    const commands = [_]Canvas.DrawCmd{.{ .fill_triangle = .{
        .points = .{
            .{ triangle_width / 2.0, 0.0 },
            .{ triangle_width, triangle_height },
            .{ 0.0, triangle_height },
        },
        .color = .{ 1.0, 0, 0, 1.0 },
    } }};
    try frame.e(.{
        Rect{
            .key = .src(@src()),
            .width = .fixed(w),
            .height = .fixed(h),
            .@"align" = .center,
            .justify = .center,
        },
        .{Canvas{
            .commands = &commands,
            .key = .src(@src()),
            .width = .fixed(triangle_width),
            .height = .fixed(triangle_height),
        }},
    });

    try ctx.devtools.render(frame, .{
        .frame_delta_ns = frame.input().delta_ns,
        .window_width = w,
        .window_height = h,
    });
}
