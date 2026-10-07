const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const MenuButton = ui.component.MenuButton;
const Spacer = ui.component.Spacer;

const Menu = MenuButton(ButtonMenu);
var counter: isize = 0;
var menu_button_last_action: []const u8 = "none";

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

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "counter: {d}", .{counter}),
            .key = .src(@src()),
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "menu action: {s}", .{menu_button_last_action}),
            .key = .src(@src()),
        },
        Spacer{ .style = &.{ .height = .fixed(12) }, .key = .src(@src()) },
    });
    const actions = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .direction = .column, .gap = 8, .overflow = .scroll, .padding = .all(8) },
    };
    _ = try actions.open(app);
    // `tone` rebinds the accent: background, hover layer and label contrast follow.
    if ((try app.interact(Button{
        .label = "+1",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .tone = .success }),
    })).clicked) increment(app);
    if ((try app.interact(Button{
        .label = "-1",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .tone = .@"error" }),
    })).clicked) decrement(app);
    if ((try app.interact(Button{
        .label = "reset",
        .key = .src(@src()),
        .style = &comptime small.with(.{ .radius = .{ .fixed = 16 } }),
    })).clicked) reset(app);
    // A partial override keeps Button's centering, transition and hover feedback.
    if ((try app.interact(Button{
        .label = "ghost",
        .key = .src(@src()),
        .style = &comptime small.with(.{
            .background = .transparent,
            .foreground = .text,
            .border_width = .all(1),
            .border_color = .dimmed,
            .hover = &.{ .border_color = .accent },
        }),
    })).clicked) increment(app);
    try app.e(Menu{
        .key = .str("buttons.menu"),
        .menu = .{},
        .label = "menu",
        .style = &.{ .width = .fixed(96), .height = .fixed(32) },
    });
    _ = try app.interact(Button{
        .label = "disabled",
        .key = .src(@src()),
        .disabled = true,
        .style = &small,
    });
    try actions.close(app);
}

const ButtonMenu = struct {
    pub fn render(_: *const ButtonMenu, app: *ui.Frame) anyerror!void {
        if ((try app.interact(menuAction(
            "Copy",
            ui.Key.str("buttons.menu.copy"),
        ))).clicked) {
            menu_button_last_action = "copy";
            app.requestRedraw();
        }
        if ((try app.interact(menuAction(
            "Rename",
            ui.Key.str("buttons.menu.rename"),
        ))).clicked) {
            menu_button_last_action = "rename";
            app.requestRedraw();
        }
        if ((try app.interact(menuAction(
            "Archive",
            ui.Key.str("buttons.menu.archive"),
        ))).clicked) {
            menu_button_last_action = "archive";
            app.requestRedraw();
        }
    }
};

fn menuAction(comptime label: []const u8, key: ui.Key) Button {
    return Button{ .key = key, .label = label, .style = &menu_item };
}

fn increment(app: *ui.Frame) void {
    counter += 1;
    app.requestRedraw();
}

fn decrement(app: *ui.Frame) void {
    counter -= 1;
    app.requestRedraw();
}

fn reset(app: *ui.Frame) void {
    counter = 0;
    app.requestRedraw();
}
