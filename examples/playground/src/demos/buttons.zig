const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Buttons",
        "onClick handlers, hover animations, corner radii and a ghost outline variant.",
        body,
    );
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "counter: {d}", .{self.demo_state.counter}),
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .row,
            .gap = 8,
            .key = .src(@src()),
        },
        .{
            Button{
                .height = .fixed(32),
                .width = .fixed(80),
                .style = .{ .color = .success, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = increment,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "+1" },
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(80),
                .style = .{ .color = .@"error", .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = decrement,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "-1" },
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(80),
                .style = .{ .color = .primary, .corner_radius = .{ .fixed = 16 } },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = reset,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "reset" },
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(80),
                .style = .{
                    .color = .{ .color = .rgba(0, 0, 0, 0) },
                    .corner_radius = .sm,
                    .border_width = 1,
                    .border_color = .dimmed,
                },
                .hover_style = .{ .border_color = .primary },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = increment,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "ghost" },
            },
        },
    });
}

fn increment(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.counter += 1;
    try self.demo_state.counter_items.append(self.allocator, self.demo_state.counter);
    try app.signal(.redraw);
}

fn decrement(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.counter -= 1;
    _ = self.demo_state.counter_items.pop();
    try app.signal(.redraw);
}

fn reset(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.counter = 0;
    self.demo_state.counter_items.clearRetainingCapacity();
    try app.signal(.redraw);
}
