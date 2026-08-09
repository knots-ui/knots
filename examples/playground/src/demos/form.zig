const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const TextInput = knots.component.TextInput;
const SelectInput = knots.component.SelectInput;
const SliderInput = knots.component.SliderInput;
const ColorPicker = knots.component.ColorPicker;
const Checkbox = knots.component.Checkbox;
const RadioGroup = knots.component.RadioGroup;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Dialog = knots.component.Dialog;
const Tooltip = knots.component.Tooltip;

const Role = enum { admin, editor, viewer, guest };
const delivery_values = [_]u32{ 0, 1, 2 };
const delivery_labels = [_][]const u8{ "immediate", "daily digest", "weekly digest" };

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Form", body);
}

fn body(desktop: *knots.App, app: *knots.Frame) !void {
    const self = Self.of(desktop);
    const arena = app.arena();

    const form = Rect{
        .width = .fixed(420),
        .dir = .column,
        .gap = 12,
        .key = .src(@src()),
    };
    _ = try form.open(app);
    try emailField(self, app);
    try passwordField(self, app);
    try roleField(self, app);
    try notificationsField(self, app);
    try deliveryField(self, app);
    try volumeField(self, app);
    try colorField(self, app);
    try app.e(Spacer{ .height = .fixed(4), .key = .src(@src()) });
    const tooltip = Tooltip{
        .key = .src(@src()),
        .@"align" = .center,
        .content = "Open the confirmation dialog.",
    };
    _ = try tooltip.open(app);
    if ((try app.interact(Button{
        .width = .fixed(120),
        .height = .fixed(34),
        .style = .{ .color = .{ .color = self.demo_state.form_color }, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "submit" },
    })).clicked) {
        self.demo_state.form_confirm_open = true;
        app.requestRedraw();
    }
    try tooltip.close(app);
    try app.e(Text{
        .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{self.demo_state.form_volume * 100}),
        .size = .xs,
        .color = .dimmed,
        .key = .src(@src()),
    });
    try form.close(app);

    const dialog = Dialog{
        .is_open = &self.demo_state.form_confirm_open,
        .key = .src(@src()),
        .width = .fixed(320),
        .gap = 16,
    };
    if (self.demo_state.form_confirm_open) {
        _ = try dialog.open(app);
        try app.e(Text{
            .content = "Are you sure?",
            .size = .lg,
            .key = .src(@src()),
        });
        const actions = Rect{
            .width = .grow(),
            .dir = .row,
            .gap = 8,
            .justify = .end,
            .key = .src(@src()),
        };
        _ = try actions.open(app);
        if ((try app.interact(Button{
            .width = .fixed(80),
            .height = .fixed(32),
            .style = .{ .color = .success, .corner_radius = .sm },
            .hover_anim = .{},
            .key = .src(@src()),
            .justify = .center,
            .@"align" = .center,
            .text = .{ .content = "Yes", .color = .on_success },
        })).clicked) submit(self, app);
        if ((try app.interact(Button{
            .width = .fixed(80),
            .height = .fixed(32),
            .style = .{ .color = .@"error", .corner_radius = .sm },
            .key = .src(@src()),
            .justify = .center,
            .@"align" = .center,
            .text = .{ .content = "Cancel", .color = .on_error },
        })).clicked) closeConfirm(self, app);
        try actions.close(app);
        _ = try dialog.closeResponse(app);
    }
}

fn openLabeled(app: *knots.Frame, comptime label: []const u8) !Rect {
    const field = Rect{ .width = .grow(), .dir = .column, .gap = 2, .key = .str("form.field:" ++ label) };
    _ = try field.open(app);
    try app.e(Text{ .content = label, .size = .xs, .color = .dimmed, .key = .str("form.label:" ++ label) });
    return field;
}

fn emailField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "email");
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_email,
        .placeholder = "you@example.com",
    });
    try field.close(app);
}

fn passwordField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "password");
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_password,
        .placeholder = "...",
    });
    try field.close(app);
}

fn roleField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "role");
    const response = try app.interact(SelectInput(Role){
        .key = .src(@src()),
        .initial_selected = self.demo_state.form_role,
    });
    if (response.selected) |selected| self.demo_state.form_role = selected.index;
    try field.close(app);
}

fn notificationsField(self: *Self, app: *knots.Frame) !void {
    _ = try app.interact(Checkbox{
        .key = .src(@src()),
        .checked = &self.demo_state.form_notifications_enabled,
        .label = "send notifications",
    });
}

fn deliveryField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "delivery cadence");
    _ = try app.interact(RadioGroup(u32){
        .key = .src(@src()),
        .selected = &self.demo_state.form_delivery_cadence,
        .values = &delivery_values,
        .labels = &delivery_labels,
        .dir = .row,
        .gap = 14,
    });
    try field.close(app);
}

fn volumeField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "notification volume");
    const slider = Rect{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0), .key = .src(@src()) };
    _ = try slider.open(app);
    _ = try app.interact(SliderInput{
        .key = .src(@src()),
        .value = &self.demo_state.form_volume,
        .steps = 0.02,
    });
    try slider.close(app);
    try field.close(app);
}

fn colorField(self: *Self, app: *knots.Frame) !void {
    const field = try openLabeled(app, "accent color");
    _ = try app.interact(ColorPicker{
        .key = .src(@src()),
        .value = &self.demo_state.form_color,
    });
    try field.close(app);
}

fn closeConfirm(self: *Self, app: *knots.Frame) void {
    self.demo_state.form_confirm_open = false;
    app.requestRedraw();
}

fn submit(self: *Self, app: *knots.Frame) void {
    std.log.info(
        "form submit -> email='{s}' password='{s}' role={d} notifications={} cadence={d} volume={d:.2}",
        .{
            self.demo_state.form_email.items,
            self.demo_state.form_password.items,
            self.demo_state.form_role,
            self.demo_state.form_notifications_enabled,
            self.demo_state.form_delivery_cadence,
            self.demo_state.form_volume,
        },
    );
    self.demo_state.form_confirm_open = false;
    app.requestRedraw();
}
