const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Nesting",
        "Nested containers inherit grow/fit from their parent. Each level shows a different border color.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(12, 12, 12, 12),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .xl, .border_width = 2, .border_color = .@"error" },
        },
        .{level1},
    });
}

fn level1(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(12, 12, 12, 12),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .lg, .border_width = 2, .border_color = .success },
        },
        .{level2},
    });
}

fn level2(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(12, 12, 12, 12),
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .md, .border_width = 2, .border_color = .primary },
        },
        .{level3},
    });
}

fn level3(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .@"align" = .center,
            .justify = .center,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 2, .border_color = .warning },
        },
        .{Text{ .content = "innermost", .size = .sm, .color = .warning, .key = .src(@src()) }},
    });
}
