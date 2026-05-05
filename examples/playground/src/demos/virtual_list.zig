const std = @import("std");
const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const VirtualList = knots.control.VirtualList;

const items_count: usize = 100_000;
const row_height: f32 = 22;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Virtual list",
        "100,000 rows. Only the visible band is rendered each frame; leading/trailing spacers preserve scroll geometry.",
        body,
    );
}

fn body(app: *knots.App) !void {
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
                .border_width = 1,
                .border_color = .toned,
            },
        },
        .{
            VirtualList(usize){
                .key = .src(@src()),
                .items = indexView(),
                .row_height = row_height,
                .each = renderRow,
            },
        },
    });
}

fn indexView() []const usize {
    const State = struct {
        var buf: [items_count]usize = undefined;
        var initialized = false;
    };
    if (!State.initialized) {
        for (&State.buf, 0..) |*v, i| v.* = i;
        State.initialized = true;
    }
    return &State.buf;
}

fn renderRow(app: *knots.App, item: usize, i: usize) !void {
    const arena = app.arena();
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(row_height),
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
