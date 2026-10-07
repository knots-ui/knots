const std = @import("std");
const ui = @import("ui");
const wire = @import("wire");
const Problem = @import("abi").Problem;
const allocator = @import("platform_impl").allocator;
const buffer = &@import("wasm_buffer").bytes;
const App = @import("App.zig");

var app: ?*App = null;
var problem: Problem = .none;
var details: []u8 = &.{};

pub fn attach(value: *App) void {
    app = value;
}

const WidgetState = struct { viewports: []const ui.State.Saved };
const widget_state_schema = wire.schema(WidgetState);

export fn knots_dev_save() usize {
    const target = app orelse return 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewports = arena.allocator().alloc(ui.State.Saved, 1 + target.secondary_viewports.items.len) catch return 0;
    viewports[0] = target.main_viewport.ui_ctx.ui.state.save(arena.allocator()) catch return 0;
    for (target.secondary_viewports.items, viewports[1..]) |viewport, *saved|
        saved.* = viewport.ui_ctx.ui.state.save(arena.allocator()) catch return 0;
    buffer.clearRetainingCapacity();
    wire.encode(allocator, buffer, widget_state_schema) catch return 0;
    wire.encode(allocator, buffer, WidgetState{ .viewports = viewports }) catch return 0;
    return buffer.items.len;
}

export fn knots_dev_load() void {
    const target = app orelse return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .allocator = arena.allocator(), .data = buffer.items };
    const schema = reader.value(u64) catch return;
    if (schema != widget_state_schema) return std.log.info("dev: the widget state changed shape, so it starts over", .{});
    const state = reader.value(WidgetState) catch return;
    reader.finish() catch return;
    for (state.viewports, 0..) |*saved, index| {
        const viewport = viewportAt(target, index) orelse break;
        viewport.ui_ctx.ui.state.load(saved) catch {};
    }
    target.main_viewport.window.requestFrame();
}

fn viewportAt(target: *App, index: usize) ?@FieldType(App, "main_viewport") {
    if (index == 0) return target.main_viewport;
    if (index - 1 >= target.secondary_viewports.items.len) return null;
    return target.secondary_viewports.items[index - 1];
}

export fn knots_dev_problem(kind: Problem) void {
    allocator.free(details);
    problem = kind;
    details = allocator.dupe(u8, buffer.items) catch &.{};
    if (app) |target| target.main_viewport.window.requestFrame();
}

pub fn render(frame: *ui.Frame) !void {
    const title, const reason = switch (problem) {
        .none => return,
        .build_failed => .{ "Build failed", "The last working build is still running. Fix the error and save to retry." },
        .crashed => .{ "The app crashed", "It restarted on the last build that drew a frame. Fix the error and save to reload." },
    };
    const component = ui.component;
    var open = true;
    const dialog: component.Dialog = .{
        .is_open = &open,
        .key = .str("knots.dev_problem"),
        .close_on_escape = false,
        .close_on_backdrop_press = false,
        .style = &.{
            .width = .{ .kind = .fit, .min = 640, .max = 960 },
            .height = .{ .kind = .fit, .max = 720 },
            .radius = .lg,
            .border_color = .@"error",
            .border_width = .all(2),
        },
        .parts = .{ .backdrop = &.{ .background = .{ .color = .{ .value = .{ 0, 0, 0, 0.62 } } } } },
    };
    _ = try dialog.open(frame);
    try frame.e(component.Text{
        .content = title,
        .style = &.{ .font_size = .lg, .foreground = .@"error" },
        .selectable = false,
        .key = .str("knots.dev_problem.title"),
    });
    try frame.e(component.Text{
        .content = reason,
        .style = &.{ .width = .grow(), .wrap = true },
        .selectable = false,
        .key = .str("knots.dev_problem.reason"),
    });
    try frame.e(component.Text{
        .content = details,
        .style = &.{ .width = .grow(), .wrap = true, .font_size = .xs },
        .key = .str("knots.dev_problem.details"),
    });
    try dialog.close(frame);
}
