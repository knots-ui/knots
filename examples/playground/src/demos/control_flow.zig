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
const max_items = 100;

/// The numbers the lists show: 1, 2, 3, ...
const numbers = blk: {
    @setEvalBranchQuota(virtual_items_count + 1);
    var items: [virtual_items_count]usize = undefined;
    for (&items, 1..) |*item, number| item.* = number;
    break :blk items;
};

item_count: usize = 0,
show_details: bool = true,

pub fn render(self: *@This(), _: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    const actions = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 8, .@"align" = .center } };
    _ = try actions.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "+1",
        .style = &.{ .height = .fixed(28), .width = .fixed(60), .tone = .success },
    })).clicked) self.setItemCount(frame, @min(self.item_count + 1, max_items));
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "-1",
        .style = &.{ .height = .fixed(28), .width = .fixed(60), .tone = .@"error" },
    })).clicked) self.setItemCount(frame, self.item_count -| 1);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = if (self.show_details) "hide" else "show",
        .style = &.{ .height = .fixed(28), .width = .fixed(96) },
    })).clicked) {
        self.show_details = !self.show_details;
        frame.requestRedraw();
    }
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} items", .{self.item_count}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try actions.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    const collapsible = ui.component.Collapsible{
        .key = .str("control_flow.details"),
        .open = self.show_details,
    };
    if (try collapsible.openContent(frame)) {
        try dynamicList(frame, self.item_count);
        collapsible.closeContent(frame);
    }

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try frame.e(Text{
        .content = "VirtualList: 100,000 items",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm, .foreground = .dimmed },
    });
    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(8) } });
    try frame.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .fixed(320), .direction = .column, .overflow = .scroll_y, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{
            VirtualList(usize){
                .key = .src(@src()),
                .items = &numbers,
                .row_height = virtual_row_height,
                .each = renderVirtualItem,
            },
        },
    });
}

fn dynamicList(frame: *ui.Frame, count: usize) !void {
    try frame.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .padding = .init(8, 8, 8, 8), .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned, .direction = .column, .gap = 4 },
        },
        .{
            For(usize){
                .items = numbers[0..count],
                .each = renderItem,
            },
        },
    });
}

fn renderVirtualItem(frame: *ui.Frame, item: usize, i: usize) !void {
    const arena = frame.arena();
    try frame.e(.{
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

fn renderItem(frame: *ui.Frame, item: usize, i: usize) !void {
    const arena = frame.arena();
    try frame.e(.{
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

fn setItemCount(self: *@This(), frame: *ui.Frame, count: usize) void {
    self.item_count = count;
    frame.requestRedraw();
}
