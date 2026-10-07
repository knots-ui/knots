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

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    allocator = app.ui().allocator;
    const arena = app.arena();

    const form = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .fixed(420), .direction = .column, .gap = 12 },
    };
    _ = try form.open(app);
    try emailField(app);
    try passwordField(app);
    try roleField(app);
    try notificationsField(app);
    try deliveryField(app);
    try volumeField(app);
    try colorField(app);
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(4) } });
    const tooltip = Tooltip{
        .key = .src(@src()),
        .content = "Open the confirmation dialog.",
        .style = &.{ .@"align" = .center },
    };
    _ = try tooltip.open(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .label = "submit",
        .style = &.{ .width = .fixed(120), .height = .fixed(34), .background = .{ .color = form_state.color } },
    })).clicked) {
        form_state.confirm_open = true;
        app.requestRedraw();
    }
    try tooltip.close(app);
    try app.e(Text{
        .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{form_state.volume * 100}),
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
    try form.close(app);

    const dialog = Dialog{
        .is_open = &form_state.confirm_open,
        .key = .src(@src()),
        .style = &.{ .width = .fixed(320), .gap = 16 },
    };
    if (form_state.confirm_open) {
        _ = try dialog.open(app);
        try app.e(Text{
            .content = "Are you sure?",
            .key = .src(@src()),
            .style = &.{ .font_size = .lg },
        });
        const actions = Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .justify = .end },
        };
        _ = try actions.open(app);
        if ((try app.interact(Button{
            .key = .src(@src()),
            .label = "Yes",
            .style = &.{ .width = .fixed(80), .height = .fixed(32), .tone = .success },
        })).clicked) submit(app);
        if ((try app.interact(Button{
            .key = .src(@src()),
            .label = "Cancel",
            .style = &.{ .width = .fixed(80), .height = .fixed(32), .tone = .@"error" },
        })).clicked) closeConfirm(app);
        try actions.close(app);
        _ = try dialog.closeResponse(app);
    }
}

fn openLabeled(app: *ui.Frame, comptime label: []const u8) !Rect {
    // Returned to the caller: the style literal must be comptime so the pointer outlives this call.
    const field = Rect{ .key = .str("form.field:" ++ label), .style = comptime &.{ .width = .grow(), .direction = .column, .gap = 2 } };
    _ = try field.open(app);
    try app.e(Text{ .content = label, .key = .str("form.label:" ++ label), .style = &.{ .font_size = .xs, .foreground = .dimmed } });
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
        .style = &.{ .direction = .row, .gap = 14 },
    });
    try field.close(app);
}

fn volumeField(app: *ui.Frame) !void {
    const field = try openLabeled(app, "notification volume");
    const slider = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0) } };
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
