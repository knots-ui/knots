const std = @import("std");
const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Hover",
        "Three buttons demonstrating hover_anim brightness, hover_style overrides, and a custom ui.anim() channel that scales a rect.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(Text{ .content = "Button hover_anim (default brighten):", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(6), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .grow(), .height = .fit(), .dir = .row, .gap = 8, .key = .src(@src()) },
        .{
            Button{
                .key = .src(@src()),
                .width = .fixed(120),
                .height = .fixed(40),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{ .brighten = 0.15 },
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "subtle" },
            },
            Button{
                .key = .src(@src()),
                .width = .fixed(120),
                .height = .fixed(40),
                .style = .{ .color = .info, .corner_radius = .sm },
                .hover_anim = .{ .brighten = 0.4 },
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "strong" },
            },
        },
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try app.e(Text{ .content = "Button hover_style (color + radius swap on hover):", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(6), .key = .src(@src()) });
    try app.e(Button{
        .key = .src(@src()),
        .width = .fixed(160),
        .height = .fixed(40),
        .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        .hover_style = .{ .color = .success, .corner_radius = .{ .fixed = 20 }, .border_color = .success },
        .hover_anim = .{ .opts = .{ .duration_ms = 200 } },
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "morph" },
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try app.e(Text{ .content = "Custom ui.anim() channel: hover the rect to grow it.", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(6), .key = .src(@src()) });
    try animatedRect(app);
}

fn animatedRect(app: *knots.App) !void {
    const key = knots.ui.Key.src(@src());
    const id = key.hash();
    const target: f32 = if (app.ui.hovering(id)) 200 else 80;
    const w = app.ui.anim(id, "w", target, .{ .duration_ms = 220, .ease = .ease_out_cubic });

    try app.e(Button{
        .key = key,
        .width = .fixed(w),
        .height = .fixed(60),
        .style = .{ .color = .primary, .corner_radius = .sm },
    });
}
