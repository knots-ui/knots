const std = @import("std");
const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Overflow",
        "Four containers showing visible (clipped by parent only), hidden (clipped here), scroll_y and scroll_x.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try caption(app, "hidden", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fixed(80),
            .overflow = .hidden,
            .padding = .init(8, 8, 8, 8),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{
            Rect{
                .width = .fixed(400),
                .height = .fixed(64),
                .style = .{ .color = .info, .corner_radius = .sm },
                .key = .src(@src()),
            },
        },
    });

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    try caption(app, "scroll_y (scroll inside)", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fixed(120),
            .overflow = .scroll_y,
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 4,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{scrollYRows},
    });

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    try caption(app, "scroll_x (scroll inside)", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fixed(60),
            .overflow = .scroll_x,
            .padding = .init(8, 8, 8, 8),
            .dir = .row,
            .gap = 6,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{scrollXBoxes},
    });
}

fn caption(app: *knots.App, content: []const u8, key: knots.ui.Key) !void {
    try app.e(Text{ .content = content, .size = .xs, .color = .dimmed, .key = key });
    try app.e(Spacer{ .height = .fixed(4), .key = key.indexed(1) });
}

fn scrollYRows(app: *knots.App) !void {
    const arena = app.arena();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try app.e(.{
            Rect{
                .width = .grow(),
                .height = .fixed(20),
                .padding = .init(0, 8, 0, 8),
                .@"align" = .center,
                .key = knots.ui.Key.src(@src()).indexed(i),
                .style = .{ .color = .elevated, .corner_radius = .sm },
            },
            .{Text{
                .content = try std.fmt.allocPrint(arena, "row {d}", .{i}),
                .size = .xs,
                .key = knots.ui.Key.src(@src()).indexed(i),
            }},
        });
    }
}

fn scrollXBoxes(app: *knots.App) !void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try app.e(Rect{
            .width = .fixed(40),
            .height = .fixed(40),
            .style = .{ .color = if (i % 2 == 0) .primary else .secondary, .corner_radius = .sm },
            .key = knots.ui.Key.src(@src()).indexed(i),
        });
    }
}
