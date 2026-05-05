const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const SliderInput = knots.component.SliderInput;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Slider",
        "SliderInput drives a numeric readout and the width of a colored bar in real time.",
        body,
    );
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "value: {d:.2}", .{self.demo_state.slider_value}),
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
        Rect{
            .width = .fixed(360),
            .height = .fixed(20),
            .padding = .init(8, 0, 8, 0),
            .key = .src(@src()),
        },
        .{
            SliderInput{
                .key = .src(@src()),
                .value = &self.demo_state.slider_value,
                .min = 0,
                .max = 1,
                .fill_color = .{ 0.85, 0.45, 0.18, 1.0 },
            },
        },
    });

    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try app.e(Text{ .content = "live bar (width = value * 100%):", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(6), .key = .src(@src()) });
    try app.e(.{
        Rect{
            .width = .fixed(360),
            .height = .fixed(20),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm },
        },
        .{
            Rect{
                .width = .percent(self.demo_state.slider_value),
                .height = .fixed(20),
                .key = .src(@src()),
                .style = .{ .color = .primary, .corner_radius = .sm },
            },
        },
    });
}
