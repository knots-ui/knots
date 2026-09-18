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

pub fn main(app: *knots.Frame) !void {
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
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
    });
    const actions = Rect{
        .width = .grow(),
        .dir = .column,
        .gap = 8,
        .key = .src(@src()),
        .overflow = .scroll,
        .padding = .init(8, 8, 8, 8),
    };
    _ = try actions.open(app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{ .color = .success, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "+1" },
    })).clicked) increment(app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "-1" },
    })).clicked) decrement(app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{ .color = .primary, .corner_radius = .{ .fixed = 16 } },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "reset" },
    })).clicked) reset(app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{
            .color = .{ .color = .rgba(0, 0, 0, 0) },
            .corner_radius = .sm,
            .border_width = .all(1),
            .border_color = .dimmed,
        },
        .hover_style = .{ .border_color = .primary },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "ghost" },
    })).clicked) increment(app);
    try app.e(Menu{
        .key = .str("buttons.menu"),
        .menu = .{},
        .height = .fixed(32),
        .width = .fixed(96),
        .padding = .init(0, 12, 0, 12),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "menu" },
    });
    _ = try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "disabled" },
        .disabled = true,
        .disabled_style = .{ .color = .muted, .corner_radius = .md },
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
    return Button{
        .key = key,
        .width = .grow(),
        .height = .fixed(30),
        .padding = .init(0, 10, 0, 10),
        .justify = .start,
        .@"align" = .center,
        .style = .{ .color = .elevated, .corner_radius = .sm },
        .hover_style = .{ .color = .muted },
        .text = .{ .content = label, .size = .sm, .color = .text },
    };
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
