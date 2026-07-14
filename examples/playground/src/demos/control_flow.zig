const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const For = knots.control.For;
const VirtualList = knots.control.VirtualList;

const virtual_items_count: usize = 100_000;
const virtual_row_height: f32 = 22;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, "Control flow", body);
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Rect{ .width = .grow(), .gap = 8, .@"align" = .center, .key = .src(@src()) },
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
        .child = dynamicList,
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try app.e(Text{
        .content = "VirtualList: 100,000 items",
        .size = .sm,
        .color = .dimmed,
        .key = .src(@src()),
    });
    try app.e(Spacer{ .height = .fixed(8), .key = .src(@src()) });
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(320),
            .dir = .column,
            .overflow = .scroll_y,
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .sm,
                .border_width = .all(1),
                .border_color = .toned,
            },
        },
        .{
            VirtualList(usize){
                .key = .src(@src()),
                .items = virtualItems(),
                .row_height = virtual_row_height,
                .each = renderVirtualItem,
            },
        },
    });
}

fn dynamicList(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
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
            For(isize){
                .items = self.demo_state.counter_items.items,
                .each = renderItem,
            },
        },
    });
}

fn virtualItems() []const usize {
    const State = struct {
        var items: [virtual_items_count]usize = @splat(0);
        var initialized = false;
    };
    if (!State.initialized) {
        for (&State.items, 0..) |*item, i| item.* = i;
        State.initialized = true;
    }
    return &State.items;
}

fn renderVirtualItem(app: *knots.App, item: usize, i: usize) !void {
    const arena = app.arena();
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(virtual_row_height),
            .padding = .init(2, 12, 2, 12),
            .@"align" = .center,
            .key = knots.ui.Key.src(@src()).indexed(i),
        },
        .{Text{
            .content = try std.fmt.allocPrint(arena, "row #{d}", .{item}),
            .size = .sm,
            .key = knots.ui.Key.src(@src()).indexed(i),
        }},
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
    app.requestFrame();
}

fn popItem(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    if (self.demo_state.counter_items.pop() != null) self.demo_state.counter -= 1;
    app.requestFrame();
}

fn toggle(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.show_details = !self.demo_state.show_details;
    app.requestFrame();
}
