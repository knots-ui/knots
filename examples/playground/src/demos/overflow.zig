const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Spacer = ui.component.Spacer;

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    try caption(app, "hidden", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(220), .height = .fixed(80), .overflow = .hidden, .padding = .init(8, 8, 8, 8), .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{
            Rect{
                .key = .src(@src()),
                .style = &.{ .width = .fixed(400), .height = .fixed(64), .background = .info, .radius = .sm },
            },
        },
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    try caption(app, "scroll_y (scroll inside)", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(220), .height = .fixed(120), .overflow = .scroll_y, .padding = .init(8, 8, 8, 8), .direction = .column, .gap = 4, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollOnlyYRows},
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    try caption(app, "scroll_x (scroll inside)", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(220), .height = .fixed(60), .overflow = .scroll_x, .padding = .init(8, 8, 8, 8), .direction = .row, .gap = 6, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollXBoxes},
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    try caption(app, "scroll (both axes)", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(220), .height = .fixed(120), .overflow = .scroll, .padding = .init(8, 8, 8, 8), .direction = .column, .gap = 4, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned },
        },
        .{scrollBothRows},
    });
}

fn caption(app: *ui.Frame, content: []const u8, key: ui.Key) !void {
    try app.e(Text{ .content = content, .key = key.indexed(1), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    try app.e(Spacer{ .key = key.indexed(2), .style = &.{ .height = .fixed(4) } });
}

fn scrollYRows(app: *ui.Frame) !void {
    try scrollRows(app, ui.Key.src(@src()), null, "row");
}

fn scrollXBoxes(app: *ui.Frame) !void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try app.e(Rect{
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .width = .fixed(40), .height = .fixed(40), .background = if (i % 2 == 0) .primary else .secondary, .radius = .sm },
        });
    }
}

fn scrollOnlyYRows(app: *ui.Frame) !void {
    try scrollRows(app, ui.Key.src(@src()), null, "row");
}

fn scrollBothRows(app: *ui.Frame) !void {
    try scrollRows(app, ui.Key.src(@src()), 360, "wide row");
}

fn scrollRows(app: *ui.Frame, key: ui.Key, fixed_width: ?f32, label: []const u8) !void {
    const arena = app.arena();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try app.e(.{
            Rect{
                .key = key.indexed(i).indexed(0),
                .style = &.{ .width = if (fixed_width) |w| .fixed(w) else .grow(), .height = .fixed(20), .padding = .init(0, 8, 0, 8), .@"align" = .center, .background = .elevated, .radius = .sm },
            },
            .{Text{
                .content = try std.fmt.allocPrint(arena, "{s} {d}", .{ label, i }),
                .key = key.indexed(i).indexed(1),
                .style = &.{ .font_size = .xs },
            }},
        });
    }
}
