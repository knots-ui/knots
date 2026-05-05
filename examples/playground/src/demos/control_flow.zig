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
    try ui_helpers.panel(
        app,
        "Control flow",
        "If, For and animation.Collapsible composed together. The list shrinks/grows with the counter.",
        body,
    );
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Rect{ .width = .grow(), .height = .fit(), .dir = .row, .gap = 8, .@"align" = .center, .key = .src(@src()) },
        .{
            Button{
                .height = .fixed(28),
                .width = .fixed(60),
                .style = .{ .color = .success, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = pushItem,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "+1" },
            },
            Button{
                .height = .fixed(28),
                .width = .fixed(60),
                .style = .{ .color = .@"error", .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = popItem,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "-1" },
            },
            Button{
                .height = .fixed(28),
                .width = .fixed(96),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = toggle,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = if (self.demo_state.show_details) "hide" else "show" },
            },
            Text{
                .content = try std.fmt.allocPrint(arena, "{d} items", .{self.demo_state.counter_items.items.len}),
                .size = .sm,
                .color = .dimmed,
                .key = .src(@src()),
            },
        },
    });

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    try app.e(knots.animation.Collapsible{
        .key = .str("control_flow.details"),
        .open = self.demo_state.show_details,
        .child = list,
    });
}

fn list(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(8, 8, 8, 8),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
            .dir = .column,
            .gap = 4,
        },
        .{
            For(isize){
                .items = self.demo_state.counter_items.items,
                .each = renderItem,
            },
        },
    });
}

fn renderItem(app: *knots.App, item: isize, i: usize) !void {
    const arena = app.arena();
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
            .content = try std.fmt.allocPrint(arena, "item #{d}", .{item}),
            .size = .sm,
            .key = knots.ui.Key.src(@src()).indexed(i),
        }},
    });
}

fn pushItem(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.counter += 1;
    try self.demo_state.counter_items.append(self.allocator, self.demo_state.counter);
    try app.signal(.redraw);
}

fn popItem(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    if (self.demo_state.counter_items.pop() != null) self.demo_state.counter -= 1;
    try app.signal(.redraw);
}

fn toggle(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.show_details = !self.demo_state.show_details;
    try app.signal(.redraw);
}
