const std = @import("std");

const ui_mod = @import("ui");
const Size = @import("ui").Size;
const Key = @import("ui").Key;

const UI = ui_mod.UI;
const Style = ui_mod.Style;
const animation = ui_mod.animation;
const Element = @import("layout").Element;
const App = @import("knots").App;

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
style: Style = .{ .color = .primary },
hover_style: ?Style.Override = null,
hover_anim: ?HoverAnim = null,
key: Key,
onClick: ?*const fn (*App) anyerror!void = null,
onHover: ?*const fn (*App) anyerror!void = null,
text: ?ButtonText = null,

pub const ButtonText = struct {
    content: []const u8,
    font: ?[]const u8 = null,
    size: Size.Input = .sm,
};

const Button = @This();

pub fn open(self: *const Button, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_hovered = ui.hovering(id);

    const t: f32 = if (self.hover_anim) |ha|
        ui.anim(id, "hover", if (is_hovered) 1.0 else 0.0, ha.opts)
    else if (is_hovered) 1.0 else 0.0;

    var deco_rect = self.style.toRect();
    if (self.hover_style) |hs| {
        const hover_rect = self.style.merge(hs).toRect();
        deco_rect.color = animation.lerpVec4(deco_rect.color, hover_rect.color, t);
        deco_rect.corner_radius = animation.lerp(deco_rect.corner_radius, hover_rect.corner_radius, t);
        deco_rect.border_width = animation.lerp(deco_rect.border_width, hover_rect.border_width, t);
        deco_rect.border_color = animation.lerpVec4(deco_rect.border_color, hover_rect.border_color, t);
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

    const rect = try ui.open(self.key, .{
        .alignment = self.@"align",
        .justify = self.justify,
        .width = self.width,
        .height = self.height,
        .padding = self.padding,
        .interactive = true,
    }, .{ .rect = deco_rect });

    if (self.onClick) |cb|
        if (ui.clickedWithin(rect)) try cb(app);

    if (self.onHover) |cb|
        if (is_hovered) try cb(app);

    if (self.text) |text| {
        const txt = Text{
            .content = text.content,
            .font = text.font,
            .key = self.key.indexed(1),
            .selectable = false,
            .size = text.size,
        };
        _ = try txt.open(app);
        try txt.close(app);
    }

    return rect;
}

pub fn close(_: *const Button, app: *App) !void {
    app.ui.close();
}
