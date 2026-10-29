const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const TextInput = ui.component.TextInput;
const SelectInput = ui.component.SelectInput;
const SliderInput = ui.component.SliderInput;
const ColorPicker = ui.component.ColorPicker;
const Checkbox = ui.component.Checkbox;
const RadioGroup = ui.component.RadioGroup;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const Dialog = ui.component.Dialog;
const Tooltip = ui.component.Tooltip;

const Role = enum { admin, editor, viewer, guest };
const delivery_values = [_]u32{ 0, 1, 2 };
const delivery_labels = [_][]const u8{ "immediate", "daily digest", "weekly digest" };

color: ui.Color = ui.Color.hex("#4F8CFFFF") catch unreachable,
confirm_open: bool = false,
delivery_cadence: u32 = 1,
email: std.ArrayList(u8) = .empty,
notifications_enabled: bool = true,
password: std.ArrayList(u8) = .empty,
role: u32 = 0,
volume: f32 = 0.7,

pub fn render(self: *@This(), _: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    const form = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .fixed(420), .direction = .column, .gap = 12 },
    };
    _ = try form.open(frame);
    try self.emailField(frame);
    try self.passwordField(frame);
    try self.roleField(frame);
    try self.notificationsField(frame);
    try self.deliveryField(frame);
    try self.volumeField(frame);
    try self.colorField(frame);
    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(4) } });
    const tooltip = Tooltip{
        .key = .src(@src()),
        .content = "Open the confirmation dialog.",
        .style = &.{ .@"align" = .center },
    };
    _ = try tooltip.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "submit",
        .style = &.{ .width = .fixed(120), .height = .fixed(34), .background = .{ .color = self.color } },
    })).clicked) {
        self.confirm_open = true;
        frame.requestRedraw();
    }
    try tooltip.close(frame);
    try frame.e(Text{
        .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{self.volume * 100}),
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
    try form.close(frame);

    const dialog = Dialog{
        .is_open = &self.confirm_open,
        .key = .src(@src()),
        .style = &.{ .width = .fixed(320), .gap = 16 },
    };
    if (self.confirm_open) {
        _ = try dialog.open(frame);
        try frame.e(Text{
            .content = "Are you sure?",
            .key = .src(@src()),
            .style = &.{ .font_size = .lg },
        });
        const actions = Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .justify = .end },
        };
        _ = try actions.open(frame);
        if ((try frame.interact(Button{
            .key = .src(@src()),
            .label = "Yes",
            .style = &.{ .width = .fixed(80), .height = .fixed(32), .tone = .success },
        })).clicked) self.submit(frame);
        if ((try frame.interact(Button{
            .key = .src(@src()),
            .label = "Cancel",
            .style = &.{ .width = .fixed(80), .height = .fixed(32), .tone = .@"error" },
        })).clicked) self.closeConfirm(frame);
        try actions.close(frame);
        _ = try dialog.closeResponse(frame);
    }
}

fn openLabeled(frame: *ui.Frame, comptime label: []const u8) !Rect {
    // Returned to the caller: the style literal must be comptime so the pointer outlives this call.
    const field = Rect{ .key = .str("form.field:" ++ label), .style = comptime &.{ .width = .grow(), .direction = .column, .gap = 2 } };
    _ = try field.open(frame);
    try frame.e(Text{ .content = label, .key = .str("form.label:" ++ label), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    return field;
}

fn emailField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "email");
    try frame.e(TextInput{
        .key = .src(@src()),
        .buf = &self.email,
        .placeholder = "you@example.com",
    });
    try field.close(frame);
}

fn passwordField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "password");
    try frame.e(TextInput{
        .key = .src(@src()),
        .buf = &self.password,
        .placeholder = "...",
    });
    try field.close(frame);
}

fn roleField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "role");
    const response = try frame.interact(SelectInput(Role){
        .key = .src(@src()),
        .initial_selected = self.role,
    });
    if (response.selected) |selected| self.role = selected.index;
    try field.close(frame);
}

fn notificationsField(self: *@This(), frame: *ui.Frame) !void {
    _ = try frame.interact(Checkbox{
        .key = .src(@src()),
        .checked = &self.notifications_enabled,
        .label = "send notifications",
    });
}

fn deliveryField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "delivery cadence");
    _ = try frame.interact(RadioGroup(u32){
        .key = .src(@src()),
        .selected = &self.delivery_cadence,
        .values = &delivery_values,
        .labels = &delivery_labels,
        .style = &.{ .direction = .row, .gap = 14 },
    });
    try field.close(frame);
}

fn volumeField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "notification volume");
    const slider = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0) } };
    _ = try slider.open(frame);
    _ = try frame.interact(SliderInput{
        .key = .src(@src()),
        .value = &self.volume,
        .steps = 0.02,
    });
    try slider.close(frame);
    try field.close(frame);
}

fn colorField(self: *@This(), frame: *ui.Frame) !void {
    const field = try openLabeled(frame, "accent color");
    _ = try frame.interact(ColorPicker{
        .key = .src(@src()),
        .value = &self.color,
    });
    try field.close(frame);
}

fn closeConfirm(self: *@This(), frame: *ui.Frame) void {
    self.confirm_open = false;
    frame.requestRedraw();
}

fn submit(self: *@This(), frame: *ui.Frame) void {
    std.log.info(
        "form submit -> email='{s}' password='{s}' role={d} notifications={} cadence={d} volume={d:.2}",
        .{
            self.email.items,
            self.password.items,
            self.role,
            self.notifications_enabled,
            self.delivery_cadence,
            self.volume,
        },
    );
    self.confirm_open = false;
    frame.requestRedraw();
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.email.deinit(allocator);
    self.password.deinit(allocator);
}
