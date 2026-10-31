const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
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

pub const demo_panel_key = ui.Key.str("playground.demo-panel");

/// One field per demo, which holds that demo's state.
const Demos = struct {
    buttons: @import("demos/buttons.zig") = .{},
    context_menu: @import("demos/context_menu.zig") = .{},
    layout: @import("demos/layout.zig") = .{},
    control_flow: @import("demos/control_flow.zig") = .{},
    form: @import("demos/form.zig") = .{},
    layer: @import("demos/layer.zig") = .{},
    overflow: @import("demos/overflow.zig") = .{},
    grid: @import("demos/grid.zig") = .{},
    glass: @import("demos/glass.zig") = .{},
    canvas: @import("demos/canvas.zig") = .{},
    gpu_shader: @import("demos/gpu_shader.zig") = .{},
    async_dispatch: @import("demos/async_dispatch.zig") = .{},
    windows: @import("demos/windows.zig") = .{},
    drops: @import("demos/drops.zig") = .{},
    shaping: @import("demos/shaping.zig") = .{},
    text_wrap: @import("demos/text_wrap.zig") = .{},
    theme: @import("demos/theme.zig") = .{},
};

const Demo = std.meta.FieldEnum(Demos);

const Entry = struct {
    demo: Demo,
    name: []const u8,
    icon: []const u8,
    description: []const u8,
};

const entries = [_]Entry{
    .{ .demo = .buttons, .name = "Buttons", .icon = "\u{e913}", .description = "Button variants, click handlers, disabled state and a menu button." },
    .{ .demo = .context_menu, .name = "Context menu", .icon = "\u{e5d2}", .description = "Right-click wrapper component with custom user-defined actions." },
    .{ .demo = .layout, .name = "Layout", .icon = "\u{e8f1}", .description = "Sizing, nesting, cross-axis alignment and main-axis distribution." },
    .{ .demo = .control_flow, .name = "Control flow", .icon = "\u{e8d5}", .description = "For, VirtualList and component.Collapsible composed together." },
    .{ .demo = .form, .name = "Form", .icon = "\u{e890}", .description = "Text inputs, radio buttons, tooltip, dropdown and slider wired into a single form." },
    .{ .demo = .layer, .name = "Layer", .icon = "\u{e53b}", .description = "dir=.layer stacks children on the z-axis." },
    .{ .demo = .overflow, .name = "Overflow", .icon = "\u{e5d7}", .description = "visible, hidden, scroll_x and scroll_y side by side." },
    .{ .demo = .grid, .name = "Grid", .icon = "\u{e871}", .description = "Dashboard tiles using fr tracks and cell spans." },
    .{ .demo = .glass, .name = "Glass", .icon = "\u{e3a5}", .description = "Style.backdrop: blur, saturation and refraction over an animated scene." },
    .{ .demo = .canvas, .name = "Canvas", .icon = "\u{e3ae}", .description = "Painter primitives: gradient grid, clock face, bar chart, polygon." },
    .{ .demo = .gpu_shader, .name = "GPU geometry", .icon = "\u{e1b1}", .description = "Thousands of indexed, instanced facets forming an interactive torus knot." },
    .{ .demo = .async_dispatch, .name = "Async dispatch", .icon = "\u{e627}", .description = "Schedule background work via app.dispatch and react to wakeups." },
    .{ .demo = .windows, .name = "Windows", .icon = "\u{e30c}", .description = "Floating windows in the current viewport and secondary native windows." },
    .{ .demo = .drops, .name = "Drops", .icon = "\u{e2c6}", .description = "Drag files onto the window and consume the paths from the frame input." },
    .{ .demo = .shaping, .name = "Shaping", .icon = "\u{e262}", .description = "Type text, pick a font, toggle its features and inspect every shaped glyph." },
    .{ .demo = .text_wrap, .name = "Text wrap", .icon = "\u{e25b}", .description = "Text and TextInput with wrap=true." },
    .{ .demo = .theme, .name = "Theme", .icon = "\u{e40a}", .description = "Switch UI theme at runtime between dark, light and the playground's custom theme." },
};

app: knots.App,
devtools: knots.debug.DevTools,
demos: Demos = .{},
active: Demo = .buttons,
viewer: code_viewer.Viewer = .{},
/// The highlighted source of the active demo, made when it is first shown.
source: ?code_viewer.Highlighted = null,

const Playground = @This();

pub fn of(app: *knots.App) *Playground {
    return @alignCast(@fieldParentPtr("app", app));
}

pub fn init(io: std.Io, allocator: std.mem.Allocator) !Playground {
    var app = try knots.App.init(io, allocator, .{ .window = .{ .width = 1280, .height = 720, .title = "Playground", .canvas_selector = "#canvas" }, .arena_reset_mode = .free_all });
    errdefer app.deinit();
    try app.main_viewport.ui_ctx.ui.text_system.addFace("jetbrains-mono", @embedFile("fonts/JetBrainsMono-VariableFont_wght.ttf"));
    const devtools = try knots.debug.DevTools.init(allocator, app.main_viewport.renderer.cfg.present_mode);
    return .{ .app = app, .devtools = devtools };
}

pub fn deinit(self: *Playground) void {
    const allocator = self.app.allocator;
    if (self.source) |source| source.deinit(allocator);
    self.app.gpuContext().waitIdle() catch |err| std.log.err("GPU shutdown: {t}", .{err});
    inline for (comptime std.meta.fieldNames(Demos)) |name| {
        const demo = &@field(self.demos, name);
        if (@hasDecl(@TypeOf(demo.*), "deinit")) demo.deinit(allocator);
    }
    self.devtools.deinit(allocator);
    self.app.deinit();
}

/// Runs until the main window closes. `self` must stay at one address.
pub fn start(self: *Playground) !void {
    try self.app.start(frame);
}

fn frame(view: *knots.View, context: *ui.Frame) !void {
    const self = of(view.app);
    const size = context.input().logical_extent;
    const root: Rect = .{ .key = .str("playground.root"), .style = &.{ .width = .fixed(@floatFromInt(size.width)), .height = .fixed(@floatFromInt(size.height)), .padding = .all(16), .direction = .column, .background = .bg } };
    _ = try root.open(context);
    try context.e(.{ Rect{ .key = .str("playground.header"), .style = &.{ .width = .grow(), .height = .fixed(48), .padding = .xy(16, 8), .@"align" = .center } }, .{Text{ .content = "knots playground", .style = &.{ .font_size = .lg }, .key = .str("playground.title"), .selectable = false }} });
    try context.e(Spacer{ .style = &.{ .height = .fixed(12) }, .key = .str("playground.header-space") });
    const body: Rect = .{ .key = .str("playground.body"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row } };
    _ = try body.open(context);
    try self.renderNav(context);
    try context.e(Spacer{ .style = &.{ .width = .fixed(12) }, .key = .str("playground.nav-space") });
    inline for (entries) |entry| {
        if (self.active == entry.demo) try self.renderDemo(context, entry);
    }
    try body.close(context);
    try root.close(context);
    try self.devtools.render(context, .{ .frame_delta_ns = context.input().delta_ns, .window_width = @floatFromInt(size.width), .window_height = @floatFromInt(size.height), .concurrency_in_flight = view.app.concurrencyInFlight(), .renderer = .{ .present_mode = view.renderer.config.present_mode, .supported_present_modes = view.renderer.supported_present_modes, .reconfigure_error = view.renderer.reconfigure_error } });
    if (self.devtools.takePresentModeRequest()) |present_mode| {
        var config = view.renderer.config;
        config.present_mode = present_mode;
        try view.app.reconfigureRenderer(view.id, config);
    }
}

fn renderNav(self: *Playground, context: *ui.Frame) !void {
    const nav: Rect = .{ .key = .str("playground.nav"), .style = &.{ .width = .fixed(220), .height = .grow(), .padding = .all(8), .direction = .column, .gap = 4, .overflow = .scroll_y } };
    _ = try nav.open(context);
    inline for (entries) |entry| {
        const label = entry.icon ++ " " ++ entry.name;
        const response = try context.interact(Button{ .key = .str("playground.nav:" ++ entry.name), .label = label, .style = if (self.active == entry.demo) &nav_button else &nav_button_inactive });
        if (response.clicked and self.active != entry.demo) {
            self.active = entry.demo;
            if (self.source) |source| source.deinit(self.app.allocator);
            self.source = null;
            self.viewer.clearSelection();
            context.requestRedraw();
        }
    }
    try nav.close(context);
}

fn renderDemo(self: *Playground, context: *ui.Frame, comptime entry: Entry) !void {
    const root: Rect = .{ .key = .str("playground.demo"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 10 } };
    _ = try root.open(context);
    const title = entry.icon ++ " " ++ entry.name;
    try context.e(.{ Rect{ .key = .str("playground.summary"), .style = &comptime card.with(.{ .width = .grow(), .height = .fixed(64), .padding = .xy(14, 10), .direction = .row, .@"align" = .center, .justify = .space_between }) }, .{ Rect{ .key = .str("playground.summary-copy"), .style = &.{ .width = .grow(), .direction = .column, .gap = 2 } }, .{ Text{ .content = title, .style = &.{ .font_size = .lg }, .key = .str("playground.summary-title") }, Text{ .content = entry.description, .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true, .width = .grow() }, .key = .str("playground.summary-description") } } } });
    const body: Rect = .{ .key = .str("playground.demo-body"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row } };
    _ = try body.open(context);
    const panel: Rect = .{ .key = demo_panel_key, .style = &comptime card.with(.{ .width = .grow(), .height = .grow(), .padding = .all(16), .direction = .column, .overflow = .scroll }) };
    _ = try panel.open(context);
    try @field(self.demos, @tagName(entry.demo)).render(&self.app, context);
    try panel.close(context);
    try self.renderSource(context, entry);
    try body.close(context);
    try root.close(context);
}

fn renderSource(self: *Playground, context: *ui.Frame, comptime entry: Entry) !void {
    const path = "demos/" ++ @tagName(entry.demo) ++ ".zig";
    if (self.viewer.open and self.source == null)
        self.source = try code_viewer.highlight(self.app.allocator, @embedFile(path));
    try code_viewer.render(context, path, self.source, &self.viewer);
}
