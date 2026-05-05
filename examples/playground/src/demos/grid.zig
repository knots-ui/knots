const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

const cols = [_]Rect.GridTrack{ .{ .fixed = 100 }, .{ .fr = 1 }, .{ .fr = 1 } };
const rows = [_]Rect.GridTrack{ .{ .fixed = 28 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .fixed = 24 } };

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Grid",
        "CSS-style grid: a fixed-width sidebar column, two fr columns, header and footer rows. Cells declare their own row/col placement and can span.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(260),
            .dir = .grid,
            .gap = 6,
            .grid_template = .{ .cols = &cols, .rows = &rows },
            .key = .src(@src()),
        },
        .{
            Rect{
                .style = .{ .color = .primary, .corner_radius = .sm },
                .padding = .init(0, 12, 0, 12),
                .@"align" = .center,
                .grid_placement = .{ .row = 0, .col = 0, .col_span = 3 },
                .key = .src(@src()),
            },
            .{Text{ .content = "Cluster overview", .key = .src(@src()) }},

            Rect{
                .style = .{ .color = .elevated, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
                .padding = .init(10, 12, 10, 12),
                .dir = .column,
                .gap = 4,
                .grid_placement = .{ .row = 1, .col = 0, .row_span = 2 },
                .key = .src(@src()),
            },
            .{
                Text{ .content = "regions", .size = .xs, .color = .dimmed, .key = .src(@src()) },
                Spacer{ .height = .fixed(4), .key = .src(@src()) },
                Text{ .content = "us-east-1", .size = .sm, .key = .src(@src()) },
                Text{ .content = "eu-west-2", .size = .sm, .key = .src(@src()) },
                Text{ .content = "ap-south-1", .size = .sm, .key = .src(@src()) },
            },

            Rect{
                .style = .{ .color = .success, .corner_radius = .sm },
                .padding = .init(8, 12, 8, 12),
                .dir = .column,
                .justify = .center,
                .grid_placement = .{ .row = 1, .col = 1 },
                .key = .src(@src()),
            },
            .{
                Text{ .content = "uptime", .size = .xs, .key = .src(@src()) },
                Text{ .content = "99.98%", .size = .xl, .key = .src(@src()) },
            },

            Rect{
                .style = .{ .color = .info, .corner_radius = .sm },
                .padding = .init(8, 12, 8, 12),
                .dir = .column,
                .justify = .center,
                .grid_placement = .{ .row = 1, .col = 2 },
                .key = .src(@src()),
            },
            .{
                Text{ .content = "latency p99", .size = .xs, .key = .src(@src()) },
                Text{ .content = "42 ms", .size = .xl, .key = .src(@src()) },
            },

            Rect{
                .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
                .padding = .init(8, 12, 8, 12),
                .dir = .column,
                .justify = .center,
                .grid_placement = .{ .row = 2, .col = 1, .col_span = 2 },
                .key = .src(@src()),
            },
            .{
                Text{ .content = "active incidents", .size = .xs, .color = .dimmed, .key = .src(@src()) },
                Text{ .content = "0 critical - 2 warnings", .size = .sm, .key = .src(@src()) },
            },

            Rect{
                .style = .{ .color = .toned, .corner_radius = .sm },
                .padding = .init(0, 12, 0, 12),
                .@"align" = .center,
                .grid_placement = .{ .row = 3, .col = 0, .col_span = 3 },
                .key = .src(@src()),
            },
            .{Text{ .content = "last sync 12s ago", .size = .xs, .color = .dimmed, .key = .src(@src()) }},
        },
    });
}
