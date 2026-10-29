const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const MenuButton = ui.component.MenuButton;
const Spacer = ui.component.Spacer;

const Menu = MenuButton(ButtonMenu);

counter: isize = 0,
menu_action: []const u8 = "none",

/// Reusable styles are plain `Style` constants; `with` derives variants at comptime.
const small: ui.Style = .{ .width = .fixed(80), .height = .fixed(32) };
const menu_item: ui.Style = .{
    .width = .grow(),
    .height = .fixed(30),
    .padding = .xy(10, 0),
    .justify = .start,
    .background = .transparent,
    .foreground = .text,
    .font_size = .sm,
    .hover = &.{ .background = .muted, .state_layer = 0 },
};

pub fn render(self: *@This(), _: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "counter: {d}", .{self.counter}),
            .key = .src(@src()),
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "menu action: {s}", .{self.menu_action}),
            .key = .src(@src()),
        },
        Spacer{ .style = &.{ .height = .fixed(12) }, .key = .src(@src()) },
    });
    const actions = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .direction = .column, .gap = 8, .overflow = .scroll, .padding = .all(8) },
    };
    _ = try actions.open(frame);
    // `tone` rebinds the accent: background, hover layer and label contrast follow.
    if ((try frame.interact(Button{
        .label = "+1",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .tone = .success }),
    })).clicked) self.add(frame, 1);
    if ((try frame.interact(Button{
        .label = "-1",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .tone = .@"error" }),
    })).clicked) self.add(frame, -1);
    if ((try frame.interact(Button{
        .label = "reset",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .radius = .{ .fixed = 16 } }),
    })).clicked) self.add(frame, -self.counter);
    // A partial override keeps Button's centering, transition and hover feedback.
    if ((try frame.interact(Button{
        .label = "ghost",
        .key = .src(@src()),
        .style = &comptime small.with(.{
            .background = .transparent,
            .foreground = .text,
            .border_width = .all(1),
            .border_color = .dimmed,
            .hover = &.{ .border_color = .accent },
        }),
    })).clicked) self.add(frame, 1);
    try frame.e(Menu{
        .key = .str("buttons.menu"),
        .menu = .{ .action = &self.menu_action },
        .label = "menu",
        .style = &.{ .width = .fixed(96), .height = .fixed(32) },
    });
    _ = try frame.interact(Button{
        .label = "disabled",
        .key = .src(@src()),
        .disabled = true,
        .style = &small,
    });
    try actions.close(frame);
}

const ButtonMenu = struct {
    action: *[]const u8,

    pub fn render(self: *const ButtonMenu, frame: *ui.Frame) anyerror!void {
        inline for (.{ "Copy", "Rename", "Archive" }) |label| {
            if ((try frame.interact(Button{ .key = .str("buttons.menu." ++ label), .label = label, .style = &menu_item })).clicked) {
                self.action.* = label;
                frame.requestRedraw();
            }
        }
    }
};

fn add(self: *@This(), frame: *ui.Frame, amount: isize) void {
    self.counter += amount;
    frame.requestRedraw();
}
