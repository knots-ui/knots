const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const code_viewer = @import("code_viewer.zig");
const demos = @import("demos.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const Canvas = ui.component.Canvas;
const Color = ui.Color;

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
debug_devtools: knots.debug.DevTools,
active_demo: usize = 0,
demo_state: demos.Demo.State,
source_cache: [demos.all.len]?code_viewer.Highlighted = @splat(null),

const Self = @This();
pub const DemoState = demos.Demo.State;

pub fn of(app: *knots.App) *Self {
    return @fieldParentPtr("app", app);
}

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

    try app.main_viewport.ui_ctx.ui.font.addFace(
        "jetbrains-mono",
        @embedFile("fonts/JetBrainsMono-VariableFont_wght.ttf"),
    );

    var debug_devtools = try knots.debug.DevTools.init(allocator, app.main_viewport.renderer.cfg.present_mode);
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
    self.app.gpuContext().waitIdle() catch {};
    self.demo_state.deinit(self.allocator);
    self.debug_devtools.deinit(self.allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

fn frameCb(view: *knots.View, frame: *ui.Frame) !void {
    const self = of(view.app);
    const size = frame.input().logical_extent;

    const root = Rect{
        .width = .fixed(@floatFromInt(size.width)),
        .height = .fixed(@floatFromInt(size.height)),
        .padding = .init(16, 16, 16, 16),
        .dir = .column,
        .key = .src(@src()),
        .style = .{ .color = .bg, .corner_radius = .none },
    };
    _ = try root.open(frame);

    try renderHeader(frame);
    try frame.e(Spacer{
        .height = .fixed(12),
        .key = .src(@src()),
    });

    const body = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .row,
        .key = .src(@src()),
    };
    _ = try body.open(frame);

    try self.renderNav(frame);
    try frame.e(Spacer{
        .width = .fixed(12),
        .key = .src(@src()),
    });

    try self.renderActiveDemo(view, frame);

    try body.close(frame);
    try root.close(frame);

    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    try self.debug_devtools.render(frame, .{
        .frame_delta_ns = frame.input().delta_ns,
        .window_width = w,
        .window_height = h,
        .concurrency_in_flight = view.app.concurrencyInFlight(),
        .renderer = .{
            .present_mode = view.renderer.config.present_mode,
            .supported_present_modes = view.renderer.supported_present_modes,
            .reconfigure_error = view.renderer.reconfigure_error,
        },
    });

    if (self.debug_devtools.takePresentModeRequest()) |present_mode| {
        var cfg = view.renderer.config;
        cfg.present_mode = present_mode;
        try view.app.reconfigureRenderer(view.id, cfg);
    }
}

fn renderActiveDemo(self: *Self, view: *knots.View, frame: *ui.Frame) !void {
    const root = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .column,
        .gap = 10,
        .key = .src(@src()),
    };
    _ = try root.open(frame);
    try self.renderDemoSummary(frame);
    const body = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .row,
        .gap = 12,
        .key = .src(@src()),
    };
    _ = try body.open(frame);
    try demos.all[self.active_demo].render(view.app, frame);
    try self.renderSourcePane(frame);
    try body.close(frame);
    try root.close(frame);
}

fn renderDemoSummary(self: *Self, frame: *ui.Frame) !void {
    const demo = demos.all[self.active_demo];

    try frame.e(.{
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

fn renderSourcePane(self: *Self, frame: *ui.Frame) !void {
    const demo = demos.all[self.active_demo];
    if (self.demo_state.show_source and self.source_cache[self.active_demo] == null) {
        self.source_cache[self.active_demo] = try code_viewer.highlight(self.allocator, demo.source);
    }
    if (try code_viewer.render(
        frame,
        demo.source_path,
        self.source_cache[self.active_demo],
        self.demo_state.show_source,
    )) {
        self.demo_state.show_source = !self.demo_state.show_source;
        frame.requestRedraw();
    }
}

fn renderHeader(app: *ui.Frame) !void {
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

fn renderNav(self: *Self, frame: *ui.Frame) !void {
    @setEvalBranchQuota(50000);
    const nav = Rect{
        .width = .fixed(220),
        .height = .grow(),
        .padding = .init(8, 8, 8, 8),
        .dir = .column,
        .gap = 4,
        .overflow = .scroll_y,
        .key = .src(@src()),
        .style = .{ .corner_radius = .none },
    };
    _ = try nav.open(frame);
    var inactive_bg = frame.ui().theme.muted.value;
    inactive_bg[3] = 0;

    inline for (demos.all, 0..) |d, i| {
        const is_active = self.active_demo == i;
        const response = try frame.interact(Button{
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
            .text = .{ .content = d.name, .size = .sm, .color = if (!is_active) .dimmed else null },
        });
        if (response.clicked) {
            self.active_demo = i;
            frame.requestRedraw();
        }
    }
    try nav.close(frame);
}
