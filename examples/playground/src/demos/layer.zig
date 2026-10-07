const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Spacer = ui.component.Spacer;

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .direction = .layer } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(96), .height = .fixed(96), .background = .info, .radius = .{ .fixed = 48 } } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(64), .height = .fixed(64), .background = .success, .radius = .{ .fixed = 32 } } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(32), .height = .fixed(32), .background = .@"error", .radius = .{ .fixed = 16 } } },
        },
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });

    try app.e(Text{ .content = "useful for badges, overlays, and z-stacked icons.", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
}
