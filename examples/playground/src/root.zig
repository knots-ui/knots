const std = @import("std");
const knots = @import("knots");
const demos = @import("demos.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Canvas = knots.component.Canvas;

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
renderer_settings: knots.debug.RendererSettings,
active_demo: usize = 0,
demo_state: demos.Demo.State,

const Self = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
    const app = try knots.App.init(io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Playground",
            .canvas_selector = "#canvas",
        },
    });

    return Self{
        .io = io,
        .allocator = allocator,
        .app = app,
        .renderer_settings = try .init(allocator, app.renderer.cfg.gpu_backend, app.renderer.cfg.present_mode),
        .demo_state = .{},
    };
}

pub fn deinit(self: *Self) void {
    self.demo_state.deinit(self.allocator);
    self.renderer_settings.deinit(self.allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const size = app.window.getSize();

    try app.e(.{
        Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(16, 16, 16, 16),
            .dir = .column,
            .key = .src(@src()),
        },
        .{
            renderHeader,
            Spacer{ .height = .fixed(12), .key = .src(@src()) },
            Rect{
                .width = .grow(),
                .height = .grow(),
                .dir = .row,
                .key = .src(@src()),
            },
            .{
                renderNav,
                Spacer{ .width = .fixed(12), .key = .src(@src()) },
                renderActiveDemo,
            },
        },
    });
}

fn renderActiveDemo(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try demos.all[self.active_demo].render(app);
}

fn renderHeader(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(48),
            .padding = .init(8, 16, 8, 16),
            .justify = .space_between,
            .@"align" = .center,
            .key = .src(@src()),
            .style = .{
                .color = .bg,
                .corner_radius = .lg,
                .border_width = 1,
                .border_color = .toned,
            },
        },
        .{
            Text{
                .content = try std.fmt.allocPrint(arena, "\u{e88a} knots playground - {s}", .{@tagName(app.renderer.cfg.gpu_backend)}),
                .size = .xl,
                .key = .src(@src()),
            },
            Rect{
                .key = .src(@src()),
                .@"align" = .center,
                .justify = .center,
                .gap = 4,
            },
            .{self.renderer_settings},
        },
    });
}

fn renderNav(app: *knots.App) !void {
    @setEvalBranchQuota(50000);
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .grow(),
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 4,
            .overflow = .scroll_y,
            .key = .src(@src()),
            .style = .{
                .color = .bg,
                .corner_radius = .lg,
                .border_width = 1,
                .border_color = .toned,
            },
        },
        .{navRows},
    });
}

fn navRows(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);

    inline for (demos.all, 0..) |d, i| {
        const handler = struct {
            fn click(a: *knots.App) !void {
                const s: *Self = @fieldParentPtr("app", a);
                s.active_demo = i;
                try a.signal(.redraw);
            }
        }.click;

        const is_active = self.active_demo == i;
        try app.e(Button{
            .key = .str("nav:" ++ d.name),
            .width = .grow(),
            .height = .fixed(28),
            .padding = .init(0, 10, 0, 10),
            .@"align" = .center,
            .justify = .start,
            .style = .{
                .color = if (is_active) .primary else .{ .color = .rgba(0, 0, 0, 0) },
                .corner_radius = .sm,
            },
            .hover_style = if (!is_active) .{ .color = .muted } else null,
            .hover_anim = .{ .opts = .{ .duration_ms = 80 } },
            .onClick = handler,
            .text = .{ .content = d.name, .size = .sm },
        });
    }
}
