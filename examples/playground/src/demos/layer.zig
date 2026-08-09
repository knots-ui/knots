const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Layer", body);
}

fn body(_: *knots.App, app: *knots.Frame) !void {
    try app.e(.{
        Rect{ .dir = .layer, .key = .src(@src()) },
        .{
            Rect{ .width = .fixed(96), .height = .fixed(96), .style = .{ .color = .info, .corner_radius = .{ .fixed = 48 } }, .key = .src(@src()) },
            Rect{ .width = .fixed(64), .height = .fixed(64), .style = .{ .color = .success, .corner_radius = .{ .fixed = 32 } }, .key = .src(@src()) },
            Rect{ .width = .fixed(32), .height = .fixed(32), .style = .{ .color = .@"error", .corner_radius = .{ .fixed = 16 } }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });

    try app.e(Text{ .content = "useful for badges, overlays, and z-stacked icons.", .size = .xs, .color = .dimmed, .key = .src(@src()) });
}
