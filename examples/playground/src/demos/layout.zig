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
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(app, "Nesting", .src(@src()));
    try nesting(app);
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(app, "Alignment", .src(@src()));
    try alignment(app);
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(app, "Justify", .src(@src()));
    try justify(app);
}

fn section(app: *ui.Frame, title: []const u8, key: ui.Key) !void {
    try app.e(Text{ .content = title, .key = key.indexed(1), .style = &.{ .font_size = .md } });
    try app.e(Spacer{ .key = key.indexed(2), .style = &.{ .height = .fixed(8) } });
}

fn caption(app: *ui.Frame, content: []const u8, key: ui.Key) !void {
    try app.e(Text{ .content = content, .key = key.indexed(1), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    try app.e(Spacer{ .key = key.indexed(2), .style = &.{ .height = .fixed(4) } });
}

fn sizing(app: *ui.Frame) !void {
    try caption(app, "grow | fixed(80) | grow", .src(@src()));
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .info, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(80), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .info, .radius = .sm } },
        },
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(app, "percent(0.25) | percent(0.50) | percent(0.25)", .src(@src()));
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.25), .height = .fixed(28), .background = .secondary, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.50), .height = .fixed(28), .background = .primary, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.25), .height = .fixed(28), .background = .secondary, .radius = .sm } },
        },
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(app, "fixed(60) | grow | fixed(120) | grow", .src(@src()));
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(60), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .success, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(120), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .success, .radius = .sm } },
        },
    });

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(app, "fit content - children dictate width", .src(@src()));
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .fit(), .gap = 6, .padding = .init(6, 6, 6, 6), .background = .muted, .radius = .sm } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(40), .height = .fixed(20), .background = .accented, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(70), .height = .fixed(20), .background = .accented, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(30), .height = .fixed(20), .background = .accented, .radius = .sm } },
        },
    });
}

fn nesting(app: *ui.Frame) !void {
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .padding = .init(12, 12, 12, 12), .background = .muted, .radius = .xl, .border_width = .all(2), .border_color = .@"error" } },
        .{.{
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .padding = .init(12, 12, 12, 12), .background = .muted, .radius = .lg, .border_width = .all(2), .border_color = .success } },
            .{.{
                Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .padding = .init(12, 12, 12, 12), .background = .muted, .radius = .md, .border_width = .all(2), .border_color = .primary } },
                .{.{
                    Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .padding = .init(10, 10, 10, 10), .@"align" = .center, .justify = .center, .background = .muted, .radius = .sm, .border_width = .all(2), .border_color = .warning } },
                    .{Text{ .content = "innermost", .key = .src(@src()), .style = &.{ .font_size = .sm, .foreground = .warning } }},
                }},
            }},
        }},
    });
}

fn alignment(app: *ui.Frame) !void {
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(140), .direction = .row, .gap = 8 } },
        .{
            .{
                Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(140), .@"align" = .start, .padding = .init(6, 6, 6, 6), .direction = .column, .gap = 4, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .@"error", .radius = .sm } },
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .@"error", .radius = .sm } },
                    Text{ .content = "start", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
                },
            },
            .{
                Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(140), .@"align" = .center, .padding = .init(6, 6, 6, 6), .direction = .column, .gap = 4, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .success, .radius = .sm } },
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .success, .radius = .sm } },
                    Text{ .content = "center", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
                },
            },
            .{
                Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(140), .@"align" = .end, .padding = .init(6, 6, 6, 6), .direction = .column, .gap = 4, .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned } },
                .{
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .primary, .radius = .sm } },
                    Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(24), .height = .fixed(24), .background = .primary, .radius = .sm } },
                    Text{ .content = "end", .key = .src(@src()), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
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

fn justifyRow(app: *ui.Frame, comptime distribution: ui.layout.Element.Justify, comptime color: ui.Color.Input, comptime label: []const u8, key: ui.Key) !void {
    try caption(app, label, key.indexed(1));
    try app.e(.{
        Rect{ .key = key.indexed(2), .style = &.{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .direction = .row, .gap = if (distribution == .space_between or distribution == .space_around) 0 else 6, .justify = distribution, .background = .muted, .radius = .sm } },
        .{
            Rect{ .key = key.indexed(3), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
            Rect{ .key = key.indexed(4), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
            Rect{ .key = key.indexed(5), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
        },
    });
    try app.e(Spacer{ .key = key.indexed(6), .style = &.{ .height = .fixed(8) } });
}
