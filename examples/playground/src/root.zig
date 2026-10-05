//! Stable playground shell. Reloadable modules supply only the active demo body.
const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Modules = knots.Modules;
const catalog = @import("catalog.zig");
const code_viewer = @import("code_viewer.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const Style = ui.Style;

const card: Style = .{ .background = .elevated, .radius = .lg, .border_width = .all(1), .border_color = .toned };
const nav_button: Style = .{
    .width = .grow(),
    .height = .fixed(28),
    .padding = .xy(10, 0),
    .justify = .start,
    .font_size = .sm,
    .hover = &.{ .state_layer = 0 },
    .transition = .{ .duration_ms = 80 },
};
const nav_button_inactive: Style = nav_button.with(.{
    .background = .transparent,
    .foreground = .dimmed,
    .hover = &.{ .background = .muted, .state_layer = 0 },
});

pub const DemoState = @import("native_demos/State.zig");

const SourceCache = struct {
    identity: u64,
    generation: u64,
    source: [:0]u8,
    highlighted: code_viewer.Highlighted,
};

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
debug_devtools: knots.debug.DevTools,
modules: *Modules,
/// Index into `catalog.entries`.
active: usize = 0,
show_source: bool = true,
source_cache: ?SourceCache = null,
demo_state: DemoState = .{},

const Self = @This();

pub fn of(app: *knots.App) *Self {
    return @alignCast(@fieldParentPtr("app", app));
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, environment_map: anytype) !Self {
    std.debug.assert(@intFromPtr(environment_map) != 0);
    var app = try knots.App.init(io, allocator, .{ .window = .{ .width = 1280, .height = 720, .title = "Playground", .canvas_selector = "#canvas" }, .arena_reset_mode = .free_all });
    errdefer app.deinit();
    try app.main_viewport.ui_ctx.ui.font.addFace("jetbrains-mono", @embedFile("fonts/JetBrainsMono-VariableFont_wght.ttf"));
    var debug_devtools = try knots.debug.DevTools.init(allocator, app.main_viewport.renderer.cfg.present_mode);
    errdefer debug_devtools.deinit(allocator);
    return .{ .io = io, .allocator = allocator, .app = app, .debug_devtools = debug_devtools, .modules = try Modules.create(allocator, io, environment_map) };
}

pub fn deinit(self: *Self) void {
    self.clearSourceCache();
    self.modules.destroy();
    self.app.gpuContext().waitIdle() catch |err| std.log.err("GPU shutdown: {s}", .{@errorName(err)});
    self.demo_state.deinit();
    self.debug_devtools.deinit(self.allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.modules.startWatching(.{ .context = self, .notify = wakeHmr });
    try self.app.start(frame);
}

fn wakeHmr(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.app.requestFrame(.main) catch {};
}

fn frame(view: *knots.View, context: *ui.Frame) !void {
    const self: *Self = @alignCast(@fieldParentPtr("app", view.app));
    // Applies module reloads before anything draws.
    try self.modules.update();
    const size = context.input().logical_extent;
    const root: Rect = .{ .key = .str("playground.root"), .style = &.{ .width = .fixed(@floatFromInt(size.width)), .height = .fixed(@floatFromInt(size.height)), .padding = .all(16), .direction = .column, .background = .bg } };
    _ = try root.open(context);
    try renderHeader(context);
    try context.e(Spacer{ .style = &.{ .height = .fixed(12) }, .key = .str("playground.header-space") });
    const body: Rect = .{ .key = .str("playground.body"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row } };
    _ = try body.open(context);
    try self.renderNav(context);
    try context.e(Spacer{ .style = &.{ .width = .fixed(12) }, .key = .str("playground.nav-space") });
    inline for (catalog.entries, 0..) |entry, index| {
        if (self.active == index) try self.renderDemo(context, entry);
    }
    try body.close(context);
    try root.close(context);
    try self.modules.renderOverlay(context);
    try self.debug_devtools.render(context, .{ .frame_delta_ns = context.input().delta_ns, .window_width = @floatFromInt(size.width), .window_height = @floatFromInt(size.height), .concurrency_in_flight = view.app.concurrencyInFlight(), .renderer = .{ .present_mode = view.renderer.config.present_mode, .supported_present_modes = view.renderer.supported_present_modes, .reconfigure_error = view.renderer.reconfigure_error } });
    if (self.debug_devtools.takePresentModeRequest()) |present_mode| {
        var config = view.renderer.config;
        config.present_mode = present_mode;
        try view.app.reconfigureRenderer(view.id, config);
    }
}

fn renderHeader(context: *ui.Frame) !void {
    try context.e(.{ Rect{ .key = .str("playground.header"), .style = &.{ .width = .grow(), .height = .fixed(48), .padding = .xy(16, 8), .justify = .space_between, .@"align" = .center } }, .{Text{ .content = "knots playground", .style = &.{ .font_size = .lg }, .key = .str("playground.title"), .selectable = false }} });
}

fn renderNav(self: *Self, context: *ui.Frame) !void {
    const nav: Rect = .{ .key = .str("playground.nav"), .style = &.{ .width = .fixed(220), .height = .grow(), .padding = .all(8), .direction = .column, .gap = 4, .overflow = .scroll_y } };
    _ = try nav.open(context);
    inline for (catalog.entries, 0..) |entry, index| {
        const label = entry.icon ++ " " ++ entry.name;
        const active = self.active == index;
        const response = try context.interact(Button{ .key = .str(@typeName(entry.module)), .label = label, .style = if (active) &nav_button else &nav_button_inactive });
        if (response.clicked) self.active = index;
    }
    try nav.close(context);
}

fn renderDemo(self: *Self, context: *ui.Frame, comptime entry: catalog.Entry) !void {
    const root: Rect = .{ .key = .str("playground.demo"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 10 } };
    _ = try root.open(context);
    try renderDemoSummary(context, entry);
    const body: Rect = .{ .key = .str("playground.demo-body"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row, .gap = 12 } };
    _ = try body.open(context);
    const path = @typeName(entry.module);
    if (comptime @hasDecl(entry.module, "render")) {
        try entry.module.render(&self.app, context);
        try self.renderSourcePane(context, path, entry.source, 1);
    } else {
        // Every other demo must be a module. If it is not, this is a
        // compile error that tells why.
        const panel: Rect = .{ .key = .str("playground.demo-panel"), .style = &comptime card.with(.{ .width = .grow(), .height = .grow(), .padding = .all(16), .direction = .column, .overflow = .scroll }) };
        _ = try panel.open(context);
        try self.modules.render(entry.module, context);
        try panel.close(context);
        try self.renderSourcePane(context, path, self.modules.source(entry.module), self.modules.generation(entry.module));
    }
    try body.close(context);
    try root.close(context);
}

fn renderDemoSummary(context: *ui.Frame, comptime entry: catalog.Entry) !void {
    const title = entry.icon ++ " " ++ entry.name;
    try context.e(.{ Rect{ .key = .str("playground.summary"), .style = &comptime card.with(.{ .width = .grow(), .height = .fixed(64), .padding = .xy(14, 10), .direction = .row, .@"align" = .center, .justify = .space_between }) }, .{ Rect{ .key = .str("playground.summary-copy"), .style = &.{ .width = .grow(), .direction = .column, .gap = 2 } }, .{ Text{ .content = title, .style = &.{ .font_size = .lg }, .key = .str("playground.summary-title") }, Text{ .content = entry.description, .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true, .width = .grow() }, .key = .str("playground.summary-description") } } } });
}

fn renderSourcePane(self: *Self, context: *ui.Frame, path: []const u8, source_text: []const u8, generation: u64) !void {
    const identity = std.hash.Wyhash.hash(0, path);
    if (self.source_cache) |cache| if (cache.identity != identity or cache.generation != generation) self.clearSourceCache();
    if (self.show_source and self.source_cache == null) {
        const source = try self.allocator.dupeSentinel(u8, source_text, 0);
        errdefer self.allocator.free(source);
        self.source_cache = .{ .identity = identity, .generation = generation, .source = source, .highlighted = try code_viewer.highlight(self.allocator, source) };
    }
    if (try code_viewer.render(context, path, if (self.source_cache) |cache| cache.highlighted else null, self.show_source)) {
        self.show_source = !self.show_source;
        context.requestRedraw();
    }
}

fn clearSourceCache(self: *Self) void {
    if (self.source_cache) |cache| {
        cache.highlighted.deinit(self.allocator);
        self.allocator.free(cache.source);
        self.source_cache = null;
    }
}
