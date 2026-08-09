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

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Control flow", body);
}

fn body(desktop: *knots.App, app: *knots.Frame) !void {
    const self = Self.of(desktop);
    const arena = app.arena();

    const actions = Rect{ .width = .grow(), .gap = 8, .@"align" = .center, .key = .src(@src()) };
    _ = try actions.open(app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(60),
        .style = .{ .color = .success, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "+1" },
    })).clicked) try pushItem(self, app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(60),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "-1" },
    })).clicked) popItem(self, app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(96),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = if (self.demo_state.show_details) "hide" else "show" },
    })).clicked) toggle(self, app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} items", .{self.demo_state.counter_items.items.len}),
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        },
    });
    try actions.close(app);

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    const collapsible = knots.animation.Collapsible{
        .key = .str("control_flow.details"),
        .open = self.demo_state.show_details,
    };
    if (try collapsible.openContent(app)) {
        try dynamicList(self, app);
        collapsible.closeContent(app);
    }

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

fn dynamicList(self: *Self, app: *knots.Frame) !void {
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

fn renderVirtualItem(app: *knots.Frame, item: usize, i: usize) !void {
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

fn renderItem(app: *knots.Frame, item: isize, i: usize) !void {
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

fn pushItem(self: *Self, app: *knots.Frame) !void {
    self.demo_state.counter += 1;
    try self.demo_state.counter_items.append(self.allocator, self.demo_state.counter);
    app.requestRedraw();
}

fn popItem(self: *Self, app: *knots.Frame) void {
    if (self.demo_state.counter_items.pop() != null) self.demo_state.counter -= 1;
    app.requestRedraw();
}

fn toggle(self: *Self, app: *knots.Frame) void {
    self.demo_state.show_details = !self.demo_state.show_details;
    app.requestRedraw();
}
