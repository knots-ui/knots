const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Layer",
        "dir=.layer stacks children on the z-axis. Later children render on top. Children share the same origin so the parent sizes to the largest.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .fit(),
            .height = .fit(),
            .dir = .layer,
            .key = .src(@src()),
        },
        .{
            Rect{ .width = .fixed(96), .height = .fixed(96), .style = .{ .color = .info, .corner_radius = .{ .fixed = 48 } }, .key = .src(@src()) },
            Rect{ .width = .fixed(64), .height = .fixed(64), .style = .{ .color = .success, .corner_radius = .{ .fixed = 32 } }, .key = .src(@src()) },
            Rect{ .width = .fixed(32), .height = .fixed(32), .style = .{ .color = .@"error", .corner_radius = .{ .fixed = 16 } }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });

    try app.e(Text{ .content = "useful for badges, overlays, and z-stacked icons.", .size = .xs, .color = .dimmed, .key = .src(@src()) });
}
