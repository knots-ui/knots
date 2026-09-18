const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Spacer = ui.component.Spacer;
const Text = ui.component.Text;

pub fn main(app: *knots.Frame) !void {
    @setEvalBranchQuota(3000);
    try section(app, "Sizing", .src(@src()));
    try sizing(app);
    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try section(app, "Nesting", .src(@src()));
    try nesting(app);
    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try section(app, "Alignment", .src(@src()));
    try alignment(app);
    try app.e(Spacer{ .height = .fixed(20), .key = .src(@src()) });
    try section(app, "Justify", .src(@src()));
    try justify(app);
}

fn section(app: *ui.Frame, title: []const u8, key: ui.Key) !void {
    try app.e(Text{ .content = title, .size = .md, .key = key.indexed(1) });
    try app.e(Spacer{ .height = .fixed(8), .key = key.indexed(2) });
}

fn caption(app: *ui.Frame, content: []const u8, key: ui.Key) !void {
    try app.e(Text{ .content = content, .size = .xs, .color = .dimmed, .key = key.indexed(1) });
    try app.e(Spacer{ .height = .fixed(4), .key = key.indexed(2) });
}

fn sizing(app: *ui.Frame) !void {
    try caption(app, "grow | fixed(80) | grow", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(28), .dir = .row, .gap = 6, .key = .src(@src()) },
        .{
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .info, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(80), .height = .fixed(28), .style = .{ .color = .warning, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .grow(), .height = .fixed(28), .style = .{ .color = .info, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(10), .key = .src(@src()) });
    try caption(app, "percent(0.25) | percent(0.50) | percent(0.25)", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(28), .dir = .row, .gap = 6, .key = .src(@src()) },
        .{
            Rect{ .width = .percent(0.25), .height = .fixed(28), .style = .{ .color = .secondary, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .percent(0.50), .height = .fixed(28), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .percent(0.25), .height = .fixed(28), .style = .{ .color = .secondary, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });

    try app.e(Spacer{ .height = .fixed(10), .key = .src(@src()) });
    try caption(app, "fixed(60) | grow | fixed(120) | grow", .src(@src()));
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
    try caption(app, "fit content - children dictate width", .src(@src()));
    try app.e(.{
        Rect{ .width = .fit(), .gap = 6, .padding = .init(6, 6, 6, 6), .style = .{ .color = .muted, .corner_radius = .sm }, .key = .src(@src()) },
        .{
            Rect{ .width = .fixed(40), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(70), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
            Rect{ .width = .fixed(30), .height = .fixed(20), .style = .{ .color = .accented, .corner_radius = .sm }, .key = .src(@src()) },
        },
    });
}

fn nesting(app: *ui.Frame) !void {
    try app.e(.{
        Rect{ .width = .grow(), .padding = .init(12, 12, 12, 12), .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .xl, .border_width = .all(2), .border_color = .@"error" } },
        .{.{
            Rect{ .width = .grow(), .padding = .init(12, 12, 12, 12), .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .lg, .border_width = .all(2), .border_color = .success } },
            .{.{
                Rect{ .width = .grow(), .padding = .init(12, 12, 12, 12), .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .md, .border_width = .all(2), .border_color = .primary } },
                .{.{
                    Rect{ .width = .grow(), .padding = .init(10, 10, 10, 10), .@"align" = .center, .justify = .center, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(2), .border_color = .warning } },
                    .{Text{ .content = "innermost", .size = .sm, .color = .warning, .key = .src(@src()) }},
                }},
            }},
        }},
    });
}

fn alignment(app: *ui.Frame) !void {
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(140), .dir = .row, .gap = 8, .key = .src(@src()) },
        .{
            .{
                Rect{ .width = .grow(), .height = .fixed(140), .@"align" = .start, .padding = .init(6, 6, 6, 6), .dir = .column, .gap = 4, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .@"error", .corner_radius = .sm }, .key = .src(@src()) },
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .@"error", .corner_radius = .sm }, .key = .src(@src()) },
                    Text{ .content = "start", .size = .xs, .color = .dimmed, .key = .src(@src()) },
                },
            },
            .{
                Rect{ .width = .grow(), .height = .fixed(140), .@"align" = .center, .padding = .init(6, 6, 6, 6), .dir = .column, .gap = 4, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .success, .corner_radius = .sm }, .key = .src(@src()) },
                    Text{ .content = "center", .size = .xs, .color = .dimmed, .key = .src(@src()) },
                },
            },
            .{
                Rect{ .width = .grow(), .height = .fixed(140), .@"align" = .end, .padding = .init(6, 6, 6, 6), .dir = .column, .gap = 4, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
                    Rect{ .width = .fixed(24), .height = .fixed(24), .style = .{ .color = .primary, .corner_radius = .sm }, .key = .src(@src()) },
                    Text{ .content = "end", .size = .xs, .color = .dimmed, .key = .src(@src()) },
                },
            },
        },
    });
}

fn justify(app: *ui.Frame) !void {
    try justifyRow(app, .start, .@"error", "start", .src(@src()));
    try justifyRow(app, .center, .success, "center", .src(@src()));
    try justifyRow(app, .end, .primary, "end", .src(@src()));
    try justifyRow(app, .space_between, .info, "space_between", .src(@src()));
    try justifyRow(app, .space_around, .warning, "space_around", .src(@src()));
}

fn justifyRow(app: *ui.Frame, comptime distribution: @FieldType(Rect, "justify"), comptime color: ui.Color.Input, comptime label: []const u8, key: ui.Key) !void {
    try caption(app, label, key.indexed(1));
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .gap = if (distribution == .space_between or distribution == .space_around) 0 else 6, .justify = distribution, .key = key.indexed(2), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{
            Rect{ .width = .fixed(28), .height = .fixed(28), .style = .{ .color = color, .corner_radius = .sm }, .key = key.indexed(3) },
            Rect{ .width = .fixed(28), .height = .fixed(28), .style = .{ .color = color, .corner_radius = .sm }, .key = key.indexed(4) },
            Rect{ .width = .fixed(28), .height = .fixed(28), .style = .{ .color = color, .corner_radius = .sm }, .key = key.indexed(5) },
        },
    });
    try app.e(Spacer{ .height = .fixed(8), .key = key.indexed(6) });
}
