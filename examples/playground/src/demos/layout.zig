const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Spacer = ui.component.Spacer;
const Text = ui.component.Text;

pub fn render(_: *@This(), _: *knots.App, frame: *ui.Frame) !void {
    @setEvalBranchQuota(3000);
    try section(frame, "Sizing", .src(@src()));
    try sizing(frame);
    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(frame, "Nesting", .src(@src()));
    try nesting(frame);
    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(frame, "Alignment", .src(@src()));
    try alignment(frame);
    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(20) } });
    try section(frame, "Justify", .src(@src()));
    try justify(frame);
}

fn section(frame: *ui.Frame, title: []const u8, key: ui.Key) !void {
    try frame.e(Text{ .content = title, .key = key.indexed(1), .style = &.{ .font_size = .md } });
    try frame.e(Spacer{ .key = key.indexed(2), .style = &.{ .height = .fixed(8) } });
}

fn caption(frame: *ui.Frame, content: []const u8, key: ui.Key) !void {
    try frame.e(Text{ .content = content, .key = key.indexed(1), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    try frame.e(Spacer{ .key = key.indexed(2), .style = &.{ .height = .fixed(4) } });
}

fn sizing(frame: *ui.Frame) !void {
    try caption(frame, "grow | fixed(80) | grow", .src(@src()));
    try frame.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .info, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(80), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .info, .radius = .sm } },
        },
    });

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(frame, "percent(0.25) | percent(0.50) | percent(0.25)", .src(@src()));
    try frame.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.25), .height = .fixed(28), .background = .secondary, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.50), .height = .fixed(28), .background = .primary, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .percent(0.25), .height = .fixed(28), .background = .secondary, .radius = .sm } },
        },
    });

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(frame, "fixed(60) | grow | fixed(120) | grow", .src(@src()));
    try frame.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .direction = .row, .gap = 6 } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(60), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .success, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(120), .height = .fixed(28), .background = .warning, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(28), .background = .success, .radius = .sm } },
        },
    });

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    try caption(frame, "fit content - children dictate width", .src(@src()));
    try frame.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .fit(), .gap = 6, .padding = .init(6, 6, 6, 6), .background = .muted, .radius = .sm } },
        .{
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(40), .height = .fixed(20), .background = .accented, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(70), .height = .fixed(20), .background = .accented, .radius = .sm } },
            Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(30), .height = .fixed(20), .background = .accented, .radius = .sm } },
        },
    });
}

fn nesting(frame: *ui.Frame) !void {
    try frame.e(.{
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

fn alignment(frame: *ui.Frame) !void {
    try frame.e(.{
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

fn justify(frame: *ui.Frame) !void {
    try justifyRow(frame, .start, .@"error", "start", .src(@src()));
    try justifyRow(frame, .center, .success, "center", .src(@src()));
    try justifyRow(frame, .end, .primary, "end", .src(@src()));
    try justifyRow(frame, .space_between, .info, "space_between", .src(@src()));
    try justifyRow(frame, .space_around, .warning, "space_around", .src(@src()));
}

fn justifyRow(frame: *ui.Frame, comptime distribution: ui.layout.Element.Justify, comptime color: ui.Color.Input, comptime label: []const u8, key: ui.Key) !void {
    try caption(frame, label, key.indexed(1));
    try frame.e(.{
        Rect{ .key = key.indexed(2), .style = &.{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .direction = .row, .gap = if (distribution == .space_between or distribution == .space_around) 0 else 6, .justify = distribution, .background = .muted, .radius = .sm } },
        .{
            Rect{ .key = key.indexed(3), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
            Rect{ .key = key.indexed(4), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
            Rect{ .key = key.indexed(5), .style = &.{ .width = .fixed(28), .height = .fixed(28), .background = color, .radius = .sm } },
        },
    });
    try frame.e(Spacer{ .key = key.indexed(6), .style = &.{ .height = .fixed(8) } });
}
