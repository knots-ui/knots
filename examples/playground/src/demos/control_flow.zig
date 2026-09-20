const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const For = ui.control.For;
const VirtualList = ui.control.VirtualList;

const virtual_items_count: usize = 100_000;
const virtual_row_height: f32 = 22;
var counter: isize = 0;
var counter_items: [100]isize = undefined;
var counter_items_count: usize = 0;
var show_details = true;

pub fn main(app: *knots.Frame) !void {
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
    })).clicked) pushItem(app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(60),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "-1" },
    })).clicked) popItem(app);
    if ((try app.interact(Button{
        .height = .fixed(28),
        .width = .fixed(96),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = if (show_details) "hide" else "show" },
    })).clicked) toggle(app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} items", .{counter_items_count}),
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        },
    });
    try actions.close(app);

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    const collapsible = ui.component.Collapsible{
        .key = .str("control_flow.details"),
        .open = show_details,
    };
    if (try collapsible.openContent(app)) {
        try dynamicList(app);
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

fn dynamicList(app: *ui.Frame) !void {
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
                .items = counter_items[0..counter_items_count],
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

fn renderVirtualItem(app: *ui.Frame, item: usize, i: usize) !void {
    const arena = app.arena();
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(virtual_row_height),
            .padding = .init(2, 12, 2, 12),
            .@"align" = .center,
            .key = ui.Key.src(@src()).indexed(i),
        },
        .{Text{
            .content = try std.fmt.allocPrint(arena, "row #{d}", .{item}),
            .size = .sm,
            .key = ui.Key.src(@src()).indexed(i),
        }},
    });
}

fn renderItem(app: *ui.Frame, item: isize, i: usize) !void {
    const arena = app.arena();
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
            .content = try std.fmt.allocPrint(arena, "item #{d}", .{item}),
            .size = .sm,
            .key = ui.Key.src(@src()).indexed(i),
        }},
    });
}

fn pushItem(app: *ui.Frame) void {
    if (counter_items_count == counter_items.len) return;
    counter += 1;
    counter_items[counter_items_count] = counter;
    counter_items_count += 1;
    app.requestRedraw();
}

fn popItem(app: *ui.Frame) void {
    if (counter_items_count > 0) {
        counter_items_count -= 1;
        counter -= 1;
    }
    app.requestRedraw();
}

fn toggle(app: *ui.Frame) void {
    show_details = !show_details;
    app.requestRedraw();
}
