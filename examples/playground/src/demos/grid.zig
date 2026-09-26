const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Spacer = ui.component.Spacer;

const cols = [_]Rect.GridTrack{ .{ .fixed = 100 }, .{ .fr = 1 }, .{ .fr = 1 } };
const rows = [_]Rect.GridTrack{ .{ .fixed = 28 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .fixed = 24 } };

pub fn main(app: *knots.Frame) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .fixed(260), .direction = .grid, .gap = 6, .grid = .{ .cols = &cols, .rows = &rows } },
        },
        .{
            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .primary, .radius = .sm, .padding = .init(0, 12, 0, 12), .@"align" = .center, .grid_cell = .{ .row = 0, .col = 0, .col_span = 3 } },
            },
            .{Text{ .content = "Cluster overview", .key = .src(@src()), .style = &.{ .foreground = .on_primary } }},

            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .elevated, .radius = .sm, .border_width = .all(1), .border_color = .toned, .padding = .init(10, 12, 10, 12), .direction = .column, .gap = 4, .grid_cell = .{ .row = 1, .col = 0, .row_span = 2 } },
            },
            .{
                Text{ .content = "regions", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
                Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(4) } },
                Text{ .content = "us-east-1", .key = .src(@src()), .style = &.{ .font_size = .sm } },
                Text{ .content = "eu-west-2", .key = .src(@src()), .style = &.{ .font_size = .sm } },
                Text{ .content = "ap-south-1", .key = .src(@src()), .style = &.{ .font_size = .sm } },
            },

            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .success, .radius = .sm, .padding = .init(8, 12, 8, 12), .direction = .column, .justify = .center, .grid_cell = .{ .row = 1, .col = 1 } },
            },
            .{
                Text{ .content = "uptime", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .on_success } },
                Text{ .content = "99.98%", .key = .src(@src()), .style = &.{ .font_size = .xl, .foreground = .on_success } },
            },

            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .info, .radius = .sm, .padding = .init(8, 12, 8, 12), .direction = .column, .justify = .center, .grid_cell = .{ .row = 1, .col = 2 } },
            },
            .{
                Text{ .content = "latency p99", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .on_info } },
                Text{ .content = "42 ms", .key = .src(@src()), .style = &.{ .font_size = .xl, .foreground = .on_info } },
            },

            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned, .padding = .init(8, 12, 8, 12), .direction = .column, .justify = .center, .grid_cell = .{ .row = 2, .col = 1, .col_span = 2 } },
            },
            .{
                Text{ .content = "active incidents", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
                Text{ .content = "0 critical - 2 warnings", .key = .src(@src()), .style = &.{ .font_size = .sm } },
            },

            Rect{
                .key = .src(@src()),
                .style = &.{ .background = .toned, .radius = .sm, .padding = .init(0, 12, 0, 12), .@"align" = .center, .grid_cell = .{ .row = 3, .col = 0, .col_span = 3 } },
            },
            .{Text{ .content = "last sync 12s ago", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } }},
        },
    });
}
