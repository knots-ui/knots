const std = @import("std");
const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Overflow", body);
}

fn body(_: *knots.App, app: *knots.Frame) !void {
    try caption(app, "hidden", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fixed(80),
            .overflow = .hidden,
            .padding = .init(8, 8, 8, 8),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
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
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollOnlyYRows},
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
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollXBoxes},
    });

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    try caption(app, "scroll (both axes)", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fixed(120),
            .overflow = .scroll,
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 4,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollBothRows},
    });
}

fn caption(app: *knots.Frame, content: []const u8, key: knots.ui.Key) !void {
    try app.e(Text{ .content = content, .size = .xs, .color = .dimmed, .key = key.indexed(1) });
    try app.e(Spacer{ .height = .fixed(4), .key = key.indexed(2) });
}

fn scrollYRows(app: *knots.Frame) !void {
    try scrollRows(app, knots.ui.Key.src(@src()), null, "row");
}

fn scrollXBoxes(app: *knots.Frame) !void {
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

fn scrollOnlyYRows(app: *knots.Frame) !void {
    try scrollRows(app, knots.ui.Key.src(@src()), null, "row");
}

fn scrollBothRows(app: *knots.Frame) !void {
    try scrollRows(app, knots.ui.Key.src(@src()), 360, "wide row");
}

fn scrollRows(app: *knots.Frame, key: knots.ui.Key, fixed_width: ?f32, label: []const u8) !void {
    const arena = app.arena();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try app.e(.{
            Rect{
                .width = if (fixed_width) |w| .fixed(w) else .grow(),
                .height = .fixed(20),
                .padding = .init(0, 8, 0, 8),
                .@"align" = .center,
                .key = key.indexed(i).indexed(0),
                .style = .{ .color = .elevated, .corner_radius = .sm },
            },
            .{Text{
                .content = try std.fmt.allocPrint(arena, "{s} {d}", .{ label, i }),
                .size = .xs,
                .key = key.indexed(i).indexed(1),
            }},
        });
    }
}
