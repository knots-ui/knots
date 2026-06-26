const std = @import("std");
const builtin = @import("builtin");

const knots = @import("knots");
const gpu = @import("gpu");
const Perf = @import("Perf.zig");

const Element = @import("layout").Element;

pub const PresentMode = gpu.Context.PresentMode;

const config = @import("debug_config");

const Button = knots.component.Button;
const Graph = knots.component.Graph;
const Rect = knots.component.Rect;
const SelectInput = knots.component.SelectInput;
const Text = knots.component.Text;

const panel_w: f32 = 680.0;
const panel_landscape_h: f32 = 260.0;
const panel_portrait_max_h: f32 = 360.0;
const margin: f32 = 16.0;
const trigger_size: f32 = 40.0;
const trigger_visible_h: f32 = trigger_size / 2.0;
const panel_gap: f32 = 6.0;
const panel_z: u8 = 240;
const trigger_z: u8 = 245;
const popup_z: u8 = 250;

const Tab = enum {
    metrics,
    runtime,
    renderer,
};

const RuntimeHistory = struct {
    latest: usize = 0,
    peak: usize = 0,

    fn update(self: *RuntimeHistory, capacity: usize) void {
        self.latest = capacity;
        self.peak = @max(self.peak, capacity);
    }
};

const State = struct {
    present_mode: PresentMode,
    panel_open: bool = false,
    active_tab: Tab = .metrics,
    perf: Perf = .{},
    runtime: RuntimeHistory = .{},
};

state: *State,
onClick: ?*const fn (*knots.App) anyerror!void = null,

const DevTools = @This();

fn mustFindIdx(slice: anytype, needle: anytype) u32 {
    for (slice, 0..) |value, i| {
        if (needle == value) return @intCast(i);
    }
    unreachable;
}

pub fn init(allocator: std.mem.Allocator, present_mode: PresentMode) !DevTools {
    const state = try allocator.create(State);
    state.* = .{
        .present_mode = present_mode,
    };
    return .{ .state = state };
}

pub fn deinit(self: *const DevTools, allocator: std.mem.Allocator) void {
    allocator.destroy(self.state);
}

const trigger_key: knots.ui.Key = .str("debug_devtools_trigger");
const trigger_button_key: knots.ui.Key = .str("debug_devtools_trigger_button");
const panel_key: knots.ui.Key = .str("debug_devtools_panel");
const metrics_tab_key: knots.ui.Key = .str("debug_devtools_metrics_tab");
const runtime_tab_key: knots.ui.Key = .str("debug_devtools_runtime_tab");
const renderer_tab_key: knots.ui.Key = .str("debug_devtools_renderer_tab");
const close_key: knots.ui.Key = .str("debug_devtools_close");
const apply_key: knots.ui.Key = .str("debug_devtools_apply");
const present_mode_key: knots.ui.Key = .str("debug_devtools_present_mode");
const spark_key: knots.ui.Key = .str("debug_devtools_spark");

fn selectedIdx(app: *knots.App, key: knots.ui.Key, fallback: u32) u32 {
    const s = app.ui.state.get(.select_input, key.hash()) orelse return fallback;
    return s.selected orelse fallback;
}

pub fn render(self: *const DevTools, app: *knots.App) anyerror!void {
    self.state.perf.update(app.timer.delta);
    self.state.runtime.update(app.frame_arena.queryCapacity());

    const size = app.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);
    const trigger_x = @max(0, (w - trigger_size) / 2.0);
    const trigger_y = @max(0, h - trigger_visible_h);

    try self.renderTrigger(app, trigger_x, trigger_y);
    if (app.ui.leftClickedWithin(trigger_button_key.hash())) self.state.panel_open = !self.state.panel_open;

    if (self.state.panel_open) try self.renderPanel(app, w, trigger_y);
    if (app.ui.leftClickedWithin(close_key.hash())) self.state.panel_open = false;
}

fn renderTrigger(_: *const DevTools, app: *knots.App, x: f32, y: f32) !void {
    _ = try app.ui.openRoot(trigger_key, x, y, .{
        .width = .fixed(trigger_size),
        .height = .fixed(trigger_size),
        .z_index = trigger_z,
    }, .none);

    try app.e(Button{
        .key = trigger_button_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = .primary, .corner_radius = .{ .fixed = trigger_size / 2.0 } },
        .hover_anim = .{},
        .text = .{ .content = ">_", .size = .xs },
        .padding = .init(0, 0, 18, 0),
    });

    app.ui.close();
}

fn renderPanel(self: *const DevTools, app: *knots.App, window_w: f32, trigger_y: f32) !void {
    const width = @min(panel_w, @max(trigger_size, window_w - margin * 2.0));
    const x = centeredOverlayX(window_w, width);
    const is_landscape = width >= 560.0;
    const max_h = @max(80.0, trigger_y - margin - panel_gap);
    const desired_h = if (is_landscape) panel_landscape_h else panel_portrait_max_h;
    const height = @min(desired_h, max_h);
    const y = @max(margin, trigger_y - height - panel_gap);

    _ = try app.ui.openRoot(panel_key, x, y, .{
        .width = .fixed(width),
        .height = if (is_landscape) .fixed(height) else .{ .kind = .fit, .max = height },
        .padding = .init(14, 14, 14, 14),
        .direction = .column,
        .gap = 12,
        .overflow = .scroll_y,
        .z_index = panel_z,
    }, .{ .rect = .{
        .color = app.ui.theme.elevated.value,
        .corner_radius = app.ui.theme.radius.scale(1.5),
        .border_width = .all(1),
        .border_color = app.ui.theme.toned.value,
    } });

    try app.e(.{
        Rect{
            .width = .grow(),
            .key = .src(@src()),
            .@"align" = .center,
            .justify = .space_between,
        },
        .{
            Text{
                .content = std.fmt.comptimePrint("knots v{s}", .{config.version}),
                .size = .xs,
                .key = .src(@src()),
                .color = .dimmed,
                .selectable = false,
            },
            Text{
                .content = std.fmt.comptimePrint("{s}-{s}", .{ @tagName(builtin.target.os.tag), @tagName(builtin.target.cpu.arch) }),
                .size = .xs,
                .key = .src(@src()),
                .color = .dimmed,
                .selectable = false,
            },
        },
    });

    try self.renderTabs(app);
    if (app.ui.leftClickedWithin(metrics_tab_key.hash())) self.state.active_tab = .metrics;
    if (app.ui.leftClickedWithin(runtime_tab_key.hash())) self.state.active_tab = .runtime;
    if (app.ui.leftClickedWithin(renderer_tab_key.hash())) self.state.active_tab = .renderer;

    const content_w = @max(0, width - 28.0);
    switch (self.state.active_tab) {
        .metrics => try self.renderMetricsTab(app, content_w),
        .runtime => try self.renderRuntimeTab(app, content_w),
        .renderer => try self.renderRenderer(app),
    }

    app.ui.close();

}

fn centeredOverlayX(window_w: f32, width: f32) f32 {
    if (window_w <= width + margin * 2.0) return @max(0, (window_w - width) / 2.0);
    return std.math.clamp((window_w - width) / 2.0, margin, window_w - width - margin);
}

fn renderTabs(self: *const DevTools, app: *knots.App) !void {
    _ = try app.ui.open(panel_key.indexed(4), .{
        .width = .grow(),
        .height = .fixed(30),
        .direction = .row,
        .gap = 6,
    }, .none);

    try app.e(Button{
        .key = metrics_tab_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = if (self.state.active_tab == .metrics) .primary else .muted, .corner_radius = .sm },
        .hover_style = if (self.state.active_tab == .metrics) null else .{ .color = .toned },
        .hover_anim = .{},
        .text = .{ .content = "Metrics", .size = .xs },
    });

    try app.e(Button{
        .key = runtime_tab_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = if (self.state.active_tab == .runtime) .primary else .muted, .corner_radius = .sm },
        .hover_style = if (self.state.active_tab == .runtime) null else .{ .color = .toned },
        .hover_anim = .{},
        .text = .{ .content = "Runtime", .size = .xs },
    });

    try app.e(Button{
        .key = renderer_tab_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = if (self.state.active_tab == .renderer) .primary else .muted, .corner_radius = .sm },
        .hover_style = if (self.state.active_tab == .renderer) null else .{ .color = .toned },
        .hover_anim = .{},
        .text = .{ .content = "Renderer", .size = .xs },
    });

    app.ui.close();
}

fn renderMetricsTab(self: *const DevTools, app: *knots.App, content_w: f32) !void {
    _ = try app.ui.open(panel_key.indexed(40), .{
        .width = .grow(),
        .direction = .column,
        .gap = 12,
    }, .none);

    try self.renderMetricsGrid(app);
    try self.renderSparkline(app, content_w);

    app.ui.close();
}

fn renderRuntimeTab(self: *const DevTools, app: *knots.App, content_w: f32) !void {
    _ = try app.ui.open(panel_key.indexed(50), .{
        .width = .grow(),
        .direction = .column,
        .gap = 12,
    }, .none);

    const columns: usize = if (content_w >= 620) 6 else if (content_w >= 420) 3 else 2;
    try self.renderRuntimeGrid(app, columns);

    app.ui.close();
}

fn renderRuntimeGrid(self: *const DevTools, app: *knots.App, columns: usize) !void {
    const arena = app.arena();
    const runtime = &self.state.runtime;

    try metricGridColumns(app, panel_key.indexed(51), columns, &.{
        .{ "Concurrency", try std.fmt.allocPrint(arena, "{d}", .{app.completion_queue.inFlight()}) },
        .{ "Arena capacity", try formatBytes(arena, runtime.latest) },
        .{ "Peak capacity", try formatBytes(arena, runtime.peak) },
    });
}

fn renderPerformance(self: *const DevTools, app: *knots.App, width: f32) !void {
    try self.renderPerformanceMetrics(app);
    try self.renderSparkline(app, width);
}

fn renderPerformanceMetrics(self: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const mm = self.state.perf.minMaxMs();

    try metricGrid(app, panel_key.indexed(11), &.{
        .{ "FPS", try std.fmt.allocPrint(arena, "{d:.1}", .{self.state.perf.averageFps()}) },
        .{ "Frame", try std.fmt.allocPrint(arena, "{d:.2} ms", .{self.state.perf.latest_ms}) },
        .{ "Min", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.min}) },
        .{ "Max", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.max}) },
    });
}

fn renderMetricsGrid(self: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const mm = self.state.perf.minMaxMs();
    const stats = app.ui.last_stats;

    try metricGridColumns(app, panel_key.indexed(12), 5, &.{
        .{ "FPS", try std.fmt.allocPrint(arena, "{d:.1}", .{self.state.perf.averageFps()}) },
        .{ "Frame", try std.fmt.allocPrint(arena, "{d:.2} ms", .{self.state.perf.latest_ms}) },
        .{ "Min", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.min}) },
        .{ "Max", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.max}) },
        .{ "Elements", try std.fmt.allocPrint(arena, "{d}", .{stats.elements}) },
        .{ "Hit records", try std.fmt.allocPrint(arena, "{d}", .{stats.hit_records}) },
        .{ "Scroll roots", try std.fmt.allocPrint(arena, "{d}", .{stats.scroll_containers}) },
        .{ "Draw layers", try std.fmt.allocPrint(arena, "{d}", .{stats.layers}) },
        .{ "Hovered", try formatId(arena, app.ui.state.hovered) },
        .{ "Focused", try formatId(arena, app.ui.state.focused) },
    });
}

fn renderSparkline(self: *const DevTools, app: *knots.App, width: f32) !void {
    _ = width;
    const arena = app.arena();
    const samples = try arena.alloc(f32, self.state.perf.count);
    for (samples, 0..) |*sample, i| sample.* = self.state.perf.sampleAt(i);

    const mm = self.state.perf.minMaxMs();
    const max_ms = @max(16.7, mm.max);

    _ = try app.ui.open(spark_key.indexed(1), .{
        .width = .grow(),
        .height = .fixed(68),
        .direction = .row,
        .alignment = .center,
        .gap = 8,
    }, .none);

    try app.e(Text{
        .key = spark_key.indexed(2),
        .content = "ms",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });

    try app.e(Graph{
        .key = spark_key,
        .width = .grow(),
        .height = .fixed(68),
        .inset = .init(8, 0, 8, 0),
        .y_domain = .{ .min = 0, .max = max_ms },
        .rules = &.{
            .{ .axis = .y, .value = max_ms * 0.5 },
        },
        .series = &.{
            .{ .data = .{ .y_values = samples } },
        },
    });

    app.ui.close();
}

fn renderRenderer(self: *const DevTools, app: *knots.App) !void {
    if (app.rendererReconfigureError() != null) self.state.present_mode = app.renderer.cfg.present_mode;

    var supported_modes = app.renderer.supportedPresentModes();
    var mode_values: [std.enums.values(PresentMode).len]PresentMode = undefined;
    var mode_labels: [mode_values.len][]const u8 = undefined;
    var mode_count: usize = 0;
    var mode_it = supported_modes.iterator();
    while (mode_it.next()) |mode| {
        mode_values[mode_count] = mode;
        mode_labels[mode_count] = @tagName(mode);
        mode_count += 1;
    }

    _ = try app.ui.open(panel_key.indexed(20), .{
        .width = .grow(),
        .direction = .column,
        .gap = 8,
    }, .none);

    _ = try app.ui.open(panel_key.indexed(21), .{
        .width = .grow(),
        .padding = .init(8, 10, 8, 10),
        .direction = .column,
        .gap = 8,
    }, .{ .rect = .{
        .color = app.ui.theme.muted.value,
        .corner_radius = app.ui.theme.radius.scale(0.5),
        .border_width = .all(1),
        .border_color = app.ui.theme.toned.value,
    } });
    _ = try app.ui.open(panel_key.indexed(22), .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);
    try app.e(Text{
        .key = panel_key.indexed(23),
        .content = "GPU API",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
    try app.e(Text{
        .key = panel_key.indexed(26),
        .content = @tagName(gpu.Backend),
        .size = .sm,
        .width = .grow(),
        .selectable = false,
    });
    app.ui.close();

    _ = try app.ui.open(panel_key.indexed(24), .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);
    try app.e(Text{
        .key = panel_key.indexed(25),
        .content = "Present mode",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
    if (mode_count == 1) {
        try app.e(Text{
            .key = present_mode_key,
            .content = mode_labels[0],
            .size = .sm,
            .width = .grow(),
            .selectable = false,
        });
    } else if (mode_count > 1) {
        try app.e(SelectInput(PresentMode){
            .key = present_mode_key,
            .labels = mode_labels[0..mode_count],
            .values = mode_values[0..mode_count],
            .initial_selected = mustFindIdx(mode_values[0..mode_count], self.state.present_mode),
            .width = .grow(),
            .dropdown_z_index = popup_z,
            .size = .sm,
        });
    }
    app.ui.close();

    if (mode_count > 1) {
        try app.e(Button{
            .key = apply_key,
            .width = .grow(),
            .height = .fixed(32),
            .justify = .center,
            .@"align" = .center,
            .style = .{ .color = .primary, .corner_radius = .sm },
            .hover_anim = .{},
            .text = .{ .content = "Apply" },
        });
    }

    if (app.rendererReconfigureError()) |err| {
        try app.e(Text{
            .key = panel_key.indexed(27),
            .content = try std.fmt.allocPrint(app.arena(), "Reconfigure failed: {s}", .{@errorName(err)}),
            .size = .xs,
            .color = .@"error",
            .selectable = false,
        });
    }

    app.ui.close();

    app.ui.close();

    if (mode_count > 1 and app.ui.leftClickedWithin(apply_key.hash())) {
        const present_mode_idx = selectedIdx(app, present_mode_key, mustFindIdx(mode_values[0..mode_count], self.state.present_mode));
        self.state.present_mode = mode_values[present_mode_idx];
        var cfg = app.renderer.cfg;
        cfg.present_mode = self.state.present_mode;
        try app.reconfigureRenderer(cfg);
        if (self.onClick) |cb| try cb(app);
    }
}

fn renderDiagnostics(_: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const stats = app.ui.last_stats;

    try metricGrid(app, panel_key.indexed(31), &.{
        .{ "Elements", try std.fmt.allocPrint(arena, "{d}", .{stats.elements}) },
        .{ "Hit records", try std.fmt.allocPrint(arena, "{d}", .{stats.hit_records}) },
        .{ "Scroll roots", try std.fmt.allocPrint(arena, "{d}", .{stats.scroll_containers}) },
        .{ "Draw layers", try std.fmt.allocPrint(arena, "{d}", .{stats.layers}) },
        .{ "Hovered", try formatId(arena, app.ui.state.hovered) },
        .{ "Focused", try formatId(arena, app.ui.state.focused) },
    });
}

fn label(app: *knots.App, key: knots.ui.Key, content: []const u8) !void {
    try app.e(Text{
        .key = key,
        .content = content,
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
}

fn metricGrid(app: *knots.App, key: knots.ui.Key, items: []const struct { []const u8, []const u8 }) !void {
    try metricGridColumns(app, key, 2, items);
}

fn metricGridColumns(app: *knots.App, key: knots.ui.Key, columns: usize, items: []const struct { []const u8, []const u8 }) !void {
    _ = try app.ui.open(key, .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);

    var i: usize = 0;
    while (i < items.len) : (i += columns) {
        _ = try app.ui.open(key.indexed(100 + i), .{
            .width = .grow(),
            .direction = .row,
            .gap = 4,
        }, .none);

        var col: usize = 0;
        while (col < columns) : (col += 1) {
            const item_idx = i + col;
            if (item_idx < items.len) {
                try app.e(MetricCard{
                    .key = key.indexed(200 + item_idx),
                    .name_key = key.indexed(300 + item_idx * 2),
                    .value_key = key.indexed(301 + item_idx * 2),
                    .name = items[item_idx][0],
                    .value = items[item_idx][1],
                });
            } else {
                try app.e(Rect{ .key = key.indexed(200 + item_idx), .width = .grow() });
            }
        }

        app.ui.close();
    }

    app.ui.close();
}

const MetricCard = struct {
    key: knots.ui.Key,
    name_key: knots.ui.Key,
    value_key: knots.ui.Key,
    name: []const u8,
    value: []const u8,

    pub fn render(self: *const MetricCard, app: *knots.App) anyerror!void {
        try app.e(.{
            Rect{
                .key = self.key,
                .width = .grow(),
                .padding = .init(5, 8, 5, 8),
                .dir = .column,
                .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
            },
            .{
                Text{ .key = self.name_key, .content = self.name, .size = .xs, .color = .dimmed, .selectable = false },
                Text{ .key = self.value_key, .content = self.value, .size = .xs, .selectable = false },
            },
        });
    }
};

fn formatId(allocator: std.mem.Allocator, id: Element.Id) ![]const u8 {
    if (id == Element.INVALID_ID) return "none";
    return std.fmt.allocPrint(allocator, "0x{x}", .{@as(u32, @truncate(id))});
}

fn formatBytes(allocator: std.mem.Allocator, bytes: usize) ![]const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});

    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KiB", .{value / 1024.0});
    return std.fmt.allocPrint(allocator, "{d:.1} MiB", .{value / (1024.0 * 1024.0)});
}
