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

pub fn main(app: *knots.Frame) !void {
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

    const row = Rect{ .width = .grow(), .gap = 8, .@"align" = .center, .key = .src(@src()) };
    _ = try row.open(app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(80),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "clear" },
    })).clicked) clear(app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} paths", .{dropped_paths.items.len}),
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        },
    });
    try row.close(app);

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    if (dropped_paths.items.len == 0) {
        try app.e(Text{
            .content = "no drops yet - try dragging a file onto the window.",
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        });
        return;
    }

    try app.e(.{
        Rect{
            .width = .grow(),
            .padding = .init(8, 8, 8, 8),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
            .dir = .column,
            .gap = 4,
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
            .width = .grow(),
            .height = .fixed(24),
            .padding = .init(0, 8, 0, 8),
            .@"align" = .center,
            .key = ui.Key.src(@src()).indexed(i),
            .style = .{ .color = .elevated, .corner_radius = .sm },
        },
        .{Text{
            .content = path,
            .size = .sm,
            .key = ui.Key.src(@src()).indexed(i),
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
