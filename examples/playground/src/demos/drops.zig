const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const For = knots.control.For;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, "Drops", body);
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    const new_paths = try app.viewport.window.consumeDrops(self.allocator);
    if (new_paths.len > 0) {
        {
            errdefer {
                for (new_paths) |path| self.allocator.free(path);
                self.allocator.free(new_paths);
            }
            try self.demo_state.dropped_paths.appendSlice(self.allocator, new_paths);
        }
        self.allocator.free(new_paths);
        app.requestFrame();
    }

    try app.e(.{
        Rect{ .width = .grow(), .gap = 8, .@"align" = .center, .key = .src(@src()) },
        .{
            Button{
                .height = .fixed(28),
                .width = .fixed(80),
                .style = .{ .color = .@"error", .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = clear,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "clear" },
            },
            Text{
                .content = try std.fmt.allocPrint(arena, "{d} paths", .{self.demo_state.dropped_paths.items.len}),
                .size = .sm,
                .color = .dimmed,
                .key = .src(@src()),
            },
        },
    });

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

fn renderItem(app: *knots.App, path: []const u8, i: usize) !void {
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

fn clear(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    for (self.demo_state.dropped_paths.items) |p| self.allocator.free(p);
    self.demo_state.dropped_paths.clearRetainingCapacity();
    app.requestFrame();
}
