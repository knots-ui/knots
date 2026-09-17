const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const MenuButton = ui.component.MenuButton;
const Spacer = ui.component.Spacer;

const Menu = MenuButton(ButtonMenu);
const DEMO_TITLE = "Buttons";

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    try ui_helpers.panel(desktop, app, DEMO_TITLE, body);
}

fn body(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "counter: {d}", .{self.demo_state.counter}),
            .key = .src(@src()),
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "menu action: {s}", .{self.demo_state.menu_button_last_action}),
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
    })).clicked) try increment(self, app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "-1" },
    })).clicked) decrement(self, app);
    if ((try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(80),
        .style = .{ .color = .primary, .corner_radius = .{ .fixed = 16 } },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "reset" },
    })).clicked) reset(self, app);
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
    })).clicked) try increment(self, app);
    try app.e(Menu{
        .key = .str("buttons.menu"),
        .menu = .{ .state = self },
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
    state: *Self,

    pub fn render(self: *const ButtonMenu, app: *ui.Frame) anyerror!void {
        if ((try app.interact(menuAction(
            "Copy",
            ui.Key.str("buttons.menu.copy"),
        ))).clicked) {
            self.state.demo_state.menu_button_last_action = "copy";
            app.requestRedraw();
        }
        if ((try app.interact(menuAction(
            "Rename",
            ui.Key.str("buttons.menu.rename"),
        ))).clicked) {
            self.state.demo_state.menu_button_last_action = "rename";
            app.requestRedraw();
        }
        if ((try app.interact(menuAction(
            "Archive",
            ui.Key.str("buttons.menu.archive"),
        ))).clicked) {
            self.state.demo_state.menu_button_last_action = "archive";
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

fn increment(self: *Self, app: *ui.Frame) !void {
    self.demo_state.counter += 1;
    try self.demo_state.counter_items.append(self.allocator, self.demo_state.counter);
    app.requestRedraw();
}

fn decrement(self: *Self, app: *ui.Frame) void {
    self.demo_state.counter -= 1;
    _ = self.demo_state.counter_items.pop();
    app.requestRedraw();
}

fn reset(self: *Self, app: *ui.Frame) void {
    self.demo_state.counter = 0;
    self.demo_state.counter_items.clearRetainingCapacity();
    app.requestRedraw();
}
