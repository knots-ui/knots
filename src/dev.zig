const std = @import("std");
const ui = @import("ui");
const wire = @import("wire");
const allocator = @import("platform_impl").allocator;
const App = @import("App.zig");

pub const Problem = enum(u32) { none, build_failed, crashed };

var app: ?*App = null;
var buffer: std.ArrayList(u8) = .empty;
var problem: Problem = .none;
var details: []u8 = &.{};

pub fn attach(value: *App) void {
    app = value;
}

const WidgetState = struct { viewports: []const ui.State.Saved };

export fn knots_dev_buffer(length: usize) usize {
    buffer.ensureTotalCapacity(allocator, @max(length, 1)) catch return 0;
    buffer.items.len = length;
    return @intFromPtr(buffer.items.ptr);
}

export fn knots_dev_save() usize {
    const target = app orelse return 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewports = arena.allocator().alloc(ui.State.Saved, 1 + target.secondary_viewports.items.len) catch return 0;
    viewports[0] = target.main_viewport.ui_ctx.ui.state.save(arena.allocator()) catch return 0;
    for (target.secondary_viewports.items, viewports[1..]) |viewport, *saved|
        saved.* = viewport.ui_ctx.ui.state.save(arena.allocator()) catch return 0;
    buffer.clearRetainingCapacity();
    wire.encode(allocator, &buffer, WidgetState{ .viewports = viewports }) catch return 0;
    return buffer.items.len;
}

export fn knots_dev_load() void {
    const target = app orelse return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const state = wire.decode(WidgetState, arena.allocator(), buffer.items) catch return;
    for (state.viewports, 0..) |*saved, index| {
        const viewport = if (index == 0) target.main_viewport else if (index - 1 < target.secondary_viewports.items.len) target.secondary_viewports.items[index - 1] else break;
        viewport.ui_ctx.ui.state.load(saved) catch {};
    }
    target.main_viewport.window.requestFrame();
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
        .crashed => .{ "The app crashed", "It restarted. Fix the error and save to reload." },
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
