const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Alignment",
        "@\"align\" controls cross-axis placement of children. Three columns showing start, center and end.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(140), .dir = .row, .gap = 8, .key = .src(@src()) },
        .{ startCell, centerCell, endCell },
    });
}

fn startCell(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(140),
            .@"align" = .start,
            .padding = .init(6, 6, 6, 6),
            .dir = .column,
            .gap = 4,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .@"error", .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .@"error", .corner_radius = .sm }, .key = .src(@src()) },
            Text{ .content = "start", .size = .xs, .color = .dimmed, .key = .src(@src()) },
        },
    });
}

fn centerCell(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(140),
            .@"align" = .center,
            .padding = .init(6, 6, 6, 6),
            .dir = .column,
            .gap = 4,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
            Text{ .content = "center", .size = .xs, .color = .dimmed, .key = .src(@src()) },
        },
    });
}

fn endCell(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(140),
            .@"align" = .end,
            .padding = .init(6, 6, 6, 6),
            .dir = .column,
            .gap = 4,
            .key = .src(@src()),
            .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
        },
        .{
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
            Text{ .content = "end", .size = .xs, .color = .dimmed, .key = .src(@src()) },
        },
    });
}
