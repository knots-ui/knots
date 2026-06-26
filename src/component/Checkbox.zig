const App = @import("knots").App;
const Element = @import("layout").Element;
const ui_mod = @import("ui");
const Text = @import("Text.zig");

const Color = ui_mod.Color;
const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Size = ui_mod.Size;
const Style = ui_mod.Style;

checked: *bool,
key: Key,
label: ?[]const u8 = null,
onChange: ?*const fn (*App) anyerror!void = null,

width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
box_size: f32 = 18,
gap: f32 = 8,
label_size: Size.Input = .sm,
label_color: Color.Input = .text,
unchecked_style: Style = .{ .color = .muted, .corner_radius = .sm, .border_color = .toned, .border_width = .all(1) },
checked_style: Style = .{ .color = .primary, .corner_radius = .sm, .border_color = .primary, .border_width = .all(1) },
check_color: Color.Input = .on_primary,
hover_border_color: Color.Input = .primary,

const Checkbox = @This();

pub fn open(self: *const Checkbox, app: *App) !Element.Id {
    const ui = &app.ui;

    const min_height = @max(self.box_size, try ui.lineHeight(self.label_size.resolve(), null));
    const id = try ui.open(self.key, .{
        .width = self.width,
        .height = .{ .kind = self.height.kind, .value = self.height.value, .min = @max(self.height.min, min_height), .max = self.height.max },
        .direction = .row,
        .alignment = .center,
        .gap = self.gap,
        .interactive = true,
        .focusable = true,
    }, .none);
    try ui.setAccessibility(id, .{
        .role = .checkbox,
        .name = self.label orelse &.{},
        .state = .{ .checked = self.checked.* },
    });

    const key_activate = ui.focused(id) and
        (ui.input.containsKey(.space) or ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter));
    if (ui.leftClickedWithin(id) or key_activate) {
        self.checked.* = !self.checked.*;
        if (key_activate) ui.input.consumeKeyboard();
        if (self.onChange) |cb| try cb(app);
    }

    return id;
}

pub fn close(self: *const Checkbox, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const hovered = ui.hovering(id) or ui.isHoveredWithin(id);
    const focused = ui.focused(id);
    const t = ui.anim(id, "hover", if (hovered or focused) 1.0 else 0.0, .{ .duration_ms = 100 });

    const base_style = if (self.checked.*) self.checked_style else self.unchecked_style;
    var rect = base_style.toRect(&ui.theme);
    const hover_border = self.hover_border_color.resolve(&ui.theme);
    rect.border_color = .{
        rect.border_color[0] + (hover_border[0] - rect.border_color[0]) * t,
        rect.border_color[1] + (hover_border[1] - rect.border_color[1]) * t,
        rect.border_color[2] + (hover_border[2] - rect.border_color[2]) * t,
        rect.border_color[3] + (hover_border[3] - rect.border_color[3]) * t,
    };

    const check_color = if (self.checked.*) self.check_color.resolve(&ui.theme) else .{ 0, 0, 0, 0 };
    const cmds = try app.arena().alloc(Decoration.DrawCmd, 4);
    cmds[0] = .{ .fill_rect = .{
        .x = 0,
        .y = 0,
        .w = self.box_size,
        .h = self.box_size,
        .color = rect.color,
        .corner_radius = rect.corner_radius,
    } };
    cmds[1] = .{ .stroke_rect = .{
        .x = 0.5,
        .y = 0.5,
        .w = self.box_size - 1,
        .h = self.box_size - 1,
        .color = rect.border_color,
        .corner_radius = rect.corner_radius.shrink(0.5),
        .thickness = rect.border_width.max(),
        .edge_widths = rect.border_width,
    } };
    cmds[2] = .{ .line = .{
        .from = .{ self.box_size * 0.28, self.box_size * 0.53 },
        .to = .{ self.box_size * 0.43, self.box_size * 0.68 },
        .color = check_color,
        .thickness = 2,
    } };
    cmds[3] = .{ .line = .{
        .from = .{ self.box_size * 0.43, self.box_size * 0.68 },
        .to = .{ self.box_size * 0.74, self.box_size * 0.34 },
        .color = check_color,
        .thickness = 2,
    } };

    _ = try ui.open(self.key.indexed(1), .{
        .width = .fixed(self.box_size),
        .height = .fixed(self.box_size),
    }, .{ .canvas = .{ .cmds = cmds } });
    ui.close();

    if (self.label) |label| {
        try app.e(Text{
            .content = label,
            .size = self.label_size,
            .color = self.label_color,
            .selectable = false,
            .key = self.key.indexed(2),
        });
    }

    ui.close();
}
