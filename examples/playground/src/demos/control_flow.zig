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

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    const arena = app.arena();

    const actions = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 8, .@"align" = .center } };
    _ = try actions.open(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .label = "+1",
        .style = &.{ .height = .fixed(28), .width = .fixed(60), .tone = .success },
    })).clicked) pushItem(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .label = "-1",
        .style = &.{ .height = .fixed(28), .width = .fixed(60), .tone = .@"error" },
    })).clicked) popItem(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .label = if (show_details) "hide" else "show",
        .style = &.{ .height = .fixed(28), .width = .fixed(96) },
    })).clicked) toggle(app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} items", .{counter_items_count}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try actions.close(app);

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    const collapsible = ui.component.Collapsible{
        .key = .str("control_flow.details"),
        .open = show_details,
    };
    if (try collapsible.openContent(app)) {
        try dynamicList(app);
        collapsible.closeContent(app);
    }

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try app.e(Text{
        .content = "VirtualList: 100,000 items",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm, .foreground = .dimmed },
    });
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(8) } });
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .fixed(320), .direction = .column, .overflow = .scroll_y, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
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
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .padding = .init(8, 8, 8, 8), .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned, .direction = .column, .gap = 4 },
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
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .width = .grow(), .height = .fixed(virtual_row_height), .padding = .init(2, 12, 2, 12), .@"align" = .center },
        },
        .{Text{
            .content = try std.fmt.allocPrint(arena, "row #{d}", .{item}),
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .font_size = .sm },
        }},
    });
}

fn renderItem(app: *ui.Frame, item: isize, i: usize) !void {
    const arena = app.arena();
    try app.e(.{
        Rect{
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .width = .grow(), .height = .fixed(24), .padding = .init(0, 8, 0, 8), .@"align" = .center, .background = .elevated, .radius = .sm },
        },
        .{Text{
            .content = try std.fmt.allocPrint(arena, "item #{d}", .{item}),
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .font_size = .sm },
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
