const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const TextInput = knots.component.TextInput;
const SelectInput = knots.component.SelectInput;
const SliderInput = knots.component.SliderInput;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

const Role = enum { admin, editor, viewer, guest };

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Form",
        "TextInputs, a SelectInput, a slider and a submit button working together. Submit logs the values.",
        body,
    );
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Rect{
            .width = .fixed(420),
            .height = .fit(),
            .dir = .column,
            .gap = 12,
            .key = .src(@src()),
        },
        .{
            emailField,
            passwordField,
            roleField,
            volumeField,
            Spacer{ .height = .fixed(4), .key = .src(@src()) },
            Button{
                .width = .fixed(120),
                .height = .fixed(34),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = submit,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "submit" },
            },
            Text{
                .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{self.demo_state.form_volume * 100}),
                .size = .xs,
                .color = .dimmed,
                .key = .src(@src()),
            },
        },
    });
}

fn labeled(app: *knots.App, comptime label: []const u8, body_fn: *const fn (*knots.App) anyerror!void) !void {
    try app.e(.{
        Rect{ .width = .grow(), .height = .fit(), .dir = .column, .gap = 4, .key = .str("form.field:" ++ label) },
        .{Text{ .content = label, .size = .xs, .color = .dimmed, .key = .str("form.label:" ++ label) }},
    });
    try body_fn(app);
}

fn emailField(app: *knots.App) !void {
    try labeled(app, "email", emailInput);
}

fn emailInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_email,
        .placeholder = "you@example.com",
    });
}

fn passwordField(app: *knots.App) !void {
    try labeled(app, "password", passwordInput);
}

fn passwordInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_password,
        .placeholder = "...",
    });
}

fn roleField(app: *knots.App) !void {
    try labeled(app, "role", roleInput);
}

fn roleInput(app: *knots.App) !void {
    try app.e(SelectInput(Role){ .key = .src(@src()), .onSelect = onRoleSelect });
}

fn volumeField(app: *knots.App) !void {
    try labeled(app, "notification volume", volumeInput);
}

fn volumeInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0), .key = .src(@src()) },
        .{
            SliderInput{
                .key = .src(@src()),
                .value = &self.demo_state.form_volume,
                .fill_color = .{ 0.4, 0.7, 0.9, 1.0 },
            },
        },
    });
}

fn submit(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    std.log.info(
        "form submit -> email='{s}' password='{s}' role={d} volume={d:.2}",
        .{
            self.demo_state.form_email.items,
            self.demo_state.form_password.items,
            self.demo_state.form_role,
            self.demo_state.form_volume,
        },
    );
}

fn onRoleSelect(app: *knots.App, _: Role, idx: u32) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.form_role = idx;
}
