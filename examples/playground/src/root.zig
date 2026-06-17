const std = @import("std");
const knots = @import("knots");
const code_viewer = @import("code_viewer.zig");
const demos = @import("demos.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Canvas = knots.component.Canvas;
const Color = knots.ui.Color;

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
debug_devtools: knots.debug.DevTools,
active_demo: usize = 0,
demo_state: demos.Demo.State,
source_cache: [demos.all.len]?code_viewer.Highlighted = @splat(null),

const Self = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
    var app = try knots.App.init(io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Playground",
            .canvas_selector = "#canvas",
        },
        .arena_reset_mode = .free_all,
    });
    errdefer app.deinit();

    try app.ui.font.addFace("jetbrains-mono", @embedFile("fonts/JetBrainsMono-VariableFont_wght.ttf"));

    var debug_devtools = try knots.debug.DevTools.init(allocator, app.renderer.cfg.present_mode);
    errdefer debug_devtools.deinit(allocator);

    return Self{
        .io = io,
        .allocator = allocator,
        .app = app,
        .debug_devtools = debug_devtools,
        .demo_state = .{},
    };
}

pub fn deinit(self: *Self) void {
    for (&self.source_cache) |*entry| {
        if (entry.*) |highlighted| highlighted.deinit(self.allocator);
    }
    self.demo_state.deinit(self.allocator);
    self.debug_devtools.deinit(self.allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const size = app.window.getSize();

    try app.e(.{
        Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(16, 16, 16, 16),
            .dir = .column,
            .key = .src(@src()),
            .style = .{ .color = .bg, .corner_radius = .none },
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

    try app.e(.{self.debug_devtools});
}

fn renderActiveDemo(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .grow(),
            .dir = .column,
            .gap = 10,
            .key = .src(@src()),
        },
        .{
            renderDemoSummary,
            Rect{
                .width = .grow(),
                .height = .grow(),
                .dir = .row,
                .gap = 12,
                .key = .src(@src()),
            },
            .{
                renderDemoPane,
                renderSourcePane,
            },
        },
    });
}

fn renderDemoSummary(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const demo = demos.all[self.active_demo];

    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(64),
            .padding = .init(10, 14, 10, 14),
            .dir = .row,
            .@"align" = .center,
            .justify = .space_between,
            .key = .src(@src()),
            .style = .{
                .color = .elevated,
                .corner_radius = .lg,
                .border_width = .all(1),
                .border_color = .toned,
            },
        },
        .{
            Rect{
                .width = .grow(),
                .dir = .column,
                .gap = 2,
                .key = .src(@src()),
            },
            .{
                Text{
                    .content = demo.name,
                    .size = .lg,
                    .key = .src(@src()),
                },
                Text{
                    .content = demo.description,
                    .size = .xs,
                    .color = .dimmed,
                    .wrap = true,
                    .width = .grow(),
                    .key = .src(@src()),
                },
            },
        },
    });
}

fn toggleSource(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.show_source = !self.demo_state.show_source;
    try app.signal(.redraw);
}

fn renderDemoPane(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try demos.all[self.active_demo].render(app);
}

fn renderSourcePane(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const demo = demos.all[self.active_demo];
    if (self.demo_state.show_source and self.source_cache[self.active_demo] == null) {
        self.source_cache[self.active_demo] = try code_viewer.highlight(self.allocator, demo.source);
    }
    try code_viewer.render(app, demo.source_path, self.source_cache[self.active_demo], self.demo_state.show_source, toggleSource);
}

fn renderHeader(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(48),
            .padding = .init(8, 16, 8, 16),
            .justify = .space_between,
            .@"align" = .center,
            .key = .src(@src()),
            .style = .{ .corner_radius = .none },
        },
        .{
            Text{
                .content = "knots playground",
                .size = .lg,
                .key = .src(@src()),
                .selectable = false,
            },
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
            .style = .{ .corner_radius = .none },
        },
        .{navRows},
    });
}

fn navRows(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    var inactive_bg = app.ui.theme.muted.value;
    inactive_bg[3] = 0;

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
                .color = if (is_active) .primary else .{ .color = Color{ .value = inactive_bg } },
                .corner_radius = .sm,
            },
            .hover_style = if (!is_active) .{ .color = .muted } else .{},
            .hover_anim = .{ .opts = .{ .duration_ms = 80 } },
            .onClick = handler,
            .text = .{ .content = d.name, .size = .sm, .color = if (!is_active) .dimmed else null },
        });
    }
}
