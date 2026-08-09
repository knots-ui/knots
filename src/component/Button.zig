const std = @import("std");

const math = @import("math");

const ui_mod = @import("ui");
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const Color = @import("ui").Color;
const BorderWidth = @import("ui").BorderWidth;

const UI = ui_mod.UI;
const Style = ui_mod.Style;
const animation = ui_mod.animation;
const Element = @import("layout").Element;
const Frame = @import("knots").Frame;

const Text = @import("Text.zig");

const default_brighten: f32 = 0.15;

pub const HoverAnim = struct {
    opts: animation.Options = .{ .duration_ms = 100 },
    brighten: f32 = default_brighten,
};

@"align": Element.Align = .start,
justify: Element.Justify = .start,
width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
padding: Element.Padding = .init(0, 0, 0, 0),
style: Style = .{},
hover_style: ?Style.Override = null,
disabled_style: ?Style.Override = null,
hover_anim: ?HoverAnim = null,
disabled: bool = false,
key: Key,
text: ?ButtonText = null,

pub const ButtonText = struct {
    content: []const u8,
    font: ?[]const u8 = null,
    size: Size.Input = .sm,
    color: ?Color.Input = null,
};

const Button = @This();

pub const Response = struct {
    id: Element.Id,
    clicked: bool,
    hovered: bool,
};

pub fn interact(self: *const Button, frame: *Frame) !Response {
    const response = try self.openResponse(frame);
    try self.close(frame);
    return response;
}

pub fn open(self: *const Button, frame: *Frame) !Element.Id {
    return (try self.openResponse(frame)).id;
}

pub fn openResponse(self: *const Button, frame: *Frame) !Response {
    const ui = frame.ui();
    const id = self.key.hash();
    const is_hovered = !self.disabled and ui.hovering(id);
    const effective_style = if (self.disabled)
        if (self.disabled_style) |ds| self.style.merge(ds) else self.style
    else
        self.style;

    const t: f32 = if (self.hover_anim) |ha|
        ui.anim(id, "hover", if (is_hovered) 1.0 else 0.0, ha.opts)
    else if (is_hovered) 1.0 else 0.0;

    var deco_rect = effective_style.toRect(&ui.theme);
    if (!self.disabled) {
        if (self.hover_style) |hs| {
            const hover_rect = self.style.merge(hs).toRect(&ui.theme);
            deco_rect.color = math.lerp(@as(math.Vec4, deco_rect.color), @as(math.Vec4, hover_rect.color), t);
            deco_rect.corner_radius = .lerp(deco_rect.corner_radius, hover_rect.corner_radius, t);
            deco_rect.border_width = BorderWidth.lerp(deco_rect.border_width, hover_rect.border_width, t);
            deco_rect.border_color = math.lerp(@as(math.Vec4, deco_rect.border_color), @as(math.Vec4, hover_rect.border_color), t);
        } else if (t > 0.0) {
            const brighten = if (self.hover_anim) |ha| ha.brighten else default_brighten;
            const f = t * brighten;
            deco_rect.color = .{
                deco_rect.color[0] + (1.0 - deco_rect.color[0]) * f,
                deco_rect.color[1] + (1.0 - deco_rect.color[1]) * f,
                deco_rect.color[2] + (1.0 - deco_rect.color[2]) * f,
                deco_rect.color[3],
            };
        }
    }

    const rect = try ui.open(self.key, .{
        .alignment = self.@"align",
        .justify = self.justify,
        .width = self.width,
        .height = self.height,
        .padding = self.padding,
        .interactive = !self.disabled,
        .focusable = !self.disabled,
    }, .{ .rect = deco_rect });
    try ui.setAccessibility(rect, .{
        .role = .button,
        .name = if (self.text) |t_| t_.content else &.{},
        .state = .{ .disabled = self.disabled },
    });

    var clicked = false;
    if (!self.disabled) {
        const key_activate = ui.focused(rect) and
            (ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter) or ui.input.containsKey(.space));
        clicked = ui.leftClicked(rect, .within) or key_activate;
        if (key_activate) ui.input.consumeKeyboard();
    }

    if (self.text) |text| {
        const text_color: Color.Input =
            effective_style.color.onColor() orelse
            text.color orelse .text;
        const txt = Text{
            .content = text.content,
            .font = text.font,
            .key = self.key.indexed(1),
            .selectable = false,
            .size = text.size,
            .color = text_color,
        };
        _ = try txt.open(frame);
        try txt.close(frame);
    }

    return .{ .id = rect, .clicked = clicked, .hovered = is_hovered };
}

pub fn close(_: *const Button, frame: *Frame) !void {
    frame.ui().close();
}
