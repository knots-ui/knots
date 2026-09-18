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
const FormState = struct {
    color: ui.Color = ui.Color.hex("#4F8CFFFF") catch unreachable,
    confirm_open: bool = false,
    delivery_cadence: u32 = 1,
    email: std.ArrayList(u8) = .empty,
    notifications_enabled: bool = true,
    password: std.ArrayList(u8) = .empty,
    role: u32 = 0,
    volume: f32 = 0.7,
};
var form_state: FormState = .{};
var allocator: ?std.mem.Allocator = null;

pub fn main(app: *knots.Frame) !void {
    allocator = app.ui().allocator;
    const arena = app.arena();

    const form = Rect{
        .width = .fixed(420),
        .dir = .column,
        .gap = 12,
        .key = .src(@src()),
    };
    _ = try form.open(app);
    try emailField(app);
    try passwordField(app);
    try roleField(app);
    try notificationsField(app);
    try deliveryField(app);
    try volumeField(app);
    try colorField(app);
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
        .style = .{ .color = .{ .color = form_state.color }, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "submit" },
    })).clicked) {
        form_state.confirm_open = true;
        app.requestRedraw();
    }
    try tooltip.close(app);
    try app.e(Text{
        .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{form_state.volume * 100}),
        .size = .xs,
        .color = .dimmed,
        .key = .src(@src()),
    });
    try form.close(app);

    const dialog = Dialog{
        .is_open = &form_state.confirm_open,
        .key = .src(@src()),
        .width = .fixed(320),
        .gap = 16,
    };
    if (form_state.confirm_open) {
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
        })).clicked) submit(app);
        if ((try app.interact(Button{
            .width = .fixed(80),
            .height = .fixed(32),
            .style = .{ .color = .@"error", .corner_radius = .sm },
            .key = .src(@src()),
            .justify = .center,
            .@"align" = .center,
            .text = .{ .content = "Cancel", .color = .on_error },
        })).clicked) closeConfirm(app);
        try actions.close(app);
        _ = try dialog.closeResponse(app);
    }
}

fn openLabeled(app: *ui.Frame, comptime label: []const u8) !Rect {
    const field = Rect{ .width = .grow(), .dir = .column, .gap = 2, .key = .str("form.field:" ++ label) };
    _ = try field.open(app);
    try app.e(Text{ .content = label, .size = .xs, .color = .dimmed, .key = .str("form.label:" ++ label) });
    return field;
}

fn emailField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "email");
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &form_state.email,
        .placeholder = "you@example.com",
    });
    try field.close(app);
}

fn passwordField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "password");
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &form_state.password,
        .placeholder = "...",
    });
    try field.close(app);
}

fn roleField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "role");
    const response = try app.interact(SelectInput(Role){
        .key = .src(@src()),
        .initial_selected = form_state.role,
    });
    if (response.selected) |selected| form_state.role = selected.index;
    try field.close(app);
}

fn notificationsField(app: *ui.Frame) !void {
    _ = try app.interact(Checkbox{
        .key = .src(@src()),
        .checked = &form_state.notifications_enabled,
        .label = "send notifications",
    });
}

fn deliveryField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "delivery cadence");
    _ = try app.interact(RadioGroup(u32){
        .key = .src(@src()),
        .selected = &form_state.delivery_cadence,
        .values = &delivery_values,
        .labels = &delivery_labels,
        .dir = .row,
        .gap = 14,
    });
    try field.close(app);
}

fn volumeField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "notification volume");
    const slider = Rect{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0), .key = .src(@src()) };
    _ = try slider.open(app);
    _ = try app.interact(SliderInput{
        .key = .src(@src()),
        .value = &form_state.volume,
        .steps = 0.02,
    });
    try slider.close(app);
    try field.close(app);
}

fn colorField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "accent color");
    _ = try app.interact(ColorPicker{
        .key = .src(@src()),
        .value = &form_state.color,
    });
    try field.close(app);
}

fn closeConfirm(app: *ui.Frame) void {
    form_state.confirm_open = false;
    app.requestRedraw();
}

fn submit(app: *ui.Frame) void {
    std.log.info(
        "form submit -> email='{s}' password='{s}' role={d} notifications={} cadence={d} volume={d:.2}",
        .{
            form_state.email.items,
            form_state.password.items,
            form_state.role,
            form_state.notifications_enabled,
            form_state.delivery_cadence,
            form_state.volume,
        },
    );
    form_state.confirm_open = false;
    app.requestRedraw();
}

pub fn deinit() void {
    const active_allocator = allocator orelse return;
    form_state.email.deinit(active_allocator);
    form_state.password.deinit(active_allocator);
    form_state = .{};
    allocator = null;
}
