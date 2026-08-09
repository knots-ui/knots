const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const For = knots.control.For;

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Drops", body);
}

fn body(desktop: *knots.App, app: *knots.Frame) !void {
    const self = Self.of(desktop);
    const arena = app.arena();

    const new_paths = app.droppedPaths();
    if (new_paths.len > 0) {
        for (new_paths) |path| {
            const copy = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(copy);
            try self.demo_state.dropped_paths.append(self.allocator, copy);
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
    })).clicked) clear(self, app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} paths", .{self.demo_state.dropped_paths.items.len}),
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        },
    });
    try row.close(app);

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    if (self.demo_state.dropped_paths.items.len == 0) {
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
                .items = self.demo_state.dropped_paths.items,
                .each = renderItem,
            },
        },
    });
}

fn renderItem(app: *knots.Frame, path: []const u8, i: usize) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(24),
            .padding = .init(0, 8, 0, 8),
            .@"align" = .center,
            .key = knots.ui.Key.src(@src()).indexed(i),
            .style = .{ .color = .elevated, .corner_radius = .sm },
        },
        .{Text{
            .content = path,
            .size = .sm,
            .key = knots.ui.Key.src(@src()).indexed(i),
        }},
    });
}

fn clear(self: *Self, app: *knots.Frame) void {
    for (self.demo_state.dropped_paths.items) |p| self.allocator.free(p);
    self.demo_state.dropped_paths.clearRetainingCapacity();
    app.requestRedraw();
}
