const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const For = ui.control.For;
var dropped_paths: std.ArrayList([]const u8) = .empty;
var allocator: ?std.mem.Allocator = null;

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    const active_allocator = app.ui().allocator;
    allocator = active_allocator;
    const arena = app.arena();

    const new_paths = app.droppedPaths();
    if (new_paths.len > 0) {
        for (new_paths) |path| {
            const copy = try active_allocator.dupe(u8, path);
            errdefer active_allocator.free(copy);
            try dropped_paths.append(active_allocator, copy);
        }
        app.requestRedraw();
    }

    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 8, .@"align" = .center } };
    _ = try row.open(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .label = "clear",
        .style = &.{ .height = .fixed(28), .width = .fixed(80), .tone = .@"error" },
    })).clicked) clear(app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} paths", .{dropped_paths.items.len}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try row.close(app);

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    if (dropped_paths.items.len == 0) {
        try app.e(Text{
            .content = "no drops yet - try dragging a file onto the window.",
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        });
        return;
    }

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .padding = .init(8, 8, 8, 8), .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned, .direction = .column, .gap = 4 },
        },
        .{
            For([]const u8){
                .items = dropped_paths.items,
                .each = renderItem,
            },
        },
    });
}

fn renderItem(app: *ui.Frame, path: []const u8, i: usize) !void {
    try app.e(.{
        Rect{
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .width = .grow(), .height = .fixed(24), .padding = .init(0, 8, 0, 8), .@"align" = .center, .background = .elevated, .radius = .sm },
        },
        .{Text{
            .content = path,
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .font_size = .sm },
        }},
    });
}

fn clear(app: *ui.Frame) void {
    const active_allocator = allocator.?;
    for (dropped_paths.items) |path| active_allocator.free(path);
    dropped_paths.clearRetainingCapacity();
    app.requestRedraw();
}

pub fn deinit() void {
    const active_allocator = allocator orelse return;
    for (dropped_paths.items) |path| active_allocator.free(path);
    dropped_paths.deinit(active_allocator);
    dropped_paths = .empty;
    allocator = null;
}
