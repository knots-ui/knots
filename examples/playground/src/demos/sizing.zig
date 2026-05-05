const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Sizing",
        "Each row mixes grow, fixed, percent and fit on the same axis.",
        body,
    );
}

fn body(app: *knots.App) !void {
    @setEvalBranchQuota(2000);
    try caption(app, "row 1: grow | fixed(80) | grow", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(28), .dir = .row, .gap = 6, .key = .src(@src()) },
        .{
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .info, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(80), .height = .fixed(28), .style = .{ .color = .warning, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .info, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(10), .key = .src(@src()) });
    try caption(app, "row 2: percent(0.25) | percent(0.50) | percent(0.25)", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(28), .dir = .row, .gap = 6, .key = .src(@src()) },
        .{
            Rect{ .width = .percent(0.25), .height = .fixed(28), .style = .{ .color = .secondary, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .percent(0.50), .height = .fixed(28), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .percent(0.25), .height = .fixed(28), .style = .{ .color = .secondary, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(10), .key = .src(@src()) });
    try caption(app, "row 3: fixed(60) | grow | fixed(120) | grow", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(28), .dir = .row, .gap = 6, .key = .src(@src()) },
        .{
            Rect{ .width = .fixed(60), .height = .fixed(28), .style = .{ .color = .warning, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(120), .height = .fixed(28), .style = .{ .color = .warning, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(10), .key = .src(@src()) });
    try caption(app, "row 4: fit content - children dictate width", .src(@src()));
    try app.e(.{
        Rect{ .width = .fit(), .height = .fit(), .dir = .row, .gap = 6, .padding = .init(6, 6, 6, 6), .style = .{ .color = .muted, .corner_radius = .sm }, .key = .src(@src()) },
        .{
            Rect{ .width = .fixed(40), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(70), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(30), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });
}

fn caption(app: *knots.App, content: []const u8, key: knots.ui.Key) !void {
    try app.e(.{
        Text{ .content = content, .size = .xs, .color = .dimmed, .key = key },
        Spacer{ .height = .fixed(4), .key = key.indexed(1) },
    });
}
