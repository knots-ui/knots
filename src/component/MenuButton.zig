const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const Grid = @import("layout").Grid;
const math = @import("math");
const ui_mod = @import("ui");

const Button = @import("Button.zig");
const Text = @import("Text.zig");

const Color = ui_mod.Color;
const BorderWidth = ui_mod.BorderWidth;
const Key = ui_mod.Key;
const State = ui_mod.State;
const Style = ui_mod.Style;

pub const Placement = struct {
    x: f32,
    y: f32,
    width: f32,
    max_height: f32,
};

pub fn MenuButton(comptime Menu: type) type {
    return struct {
        key: Key,
        menu: Menu,

        @"align": Element.Align = .start,
        justify: Element.Justify = .start,
        width: Element.sizing.Axis = .fit(),
        height: Element.sizing.Axis = .fit(),
        padding: Element.Padding = .init(0, 0, 0, 0),
        style: Style = .{ .color = .primary },
        hover_style: ?Style.Override = null,
        hover_anim: ?Button.HoverAnim = null,
        text: ?Button.ButtonText = null,
        grid_placement: ?Grid.Placement = null,

        menu_width: ?f32 = null,
        fallback_menu_height: f32 = 180,
        popup_z_index: u8 = 10,
        popup_padding: Element.Padding = .init(4, 4, 4, 4),
        popup_gap: f32 = 2,
        popup_style: Style = .{ .color = .elevated, .corner_radius = .sm, .border_color = .toned, .border_width = .all(1) },
        close_on_popup_click: bool = true,

        const Self = @This();
        const POPUP_INDEX: usize = 1;
        const TEXT_INDEX: usize = 2;

        pub fn open(self: *const Self, app: *App) !Element.Id {
            const ui = &app.ui;
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.menu_button, ui.allocator, id);

            if (s.open and ui.input.mouse_left_pressed and !isPointerInside(s, ui.input.mouse_pos)) {
                s.open = false;
                try app.signal(.redraw);
            }

            if (ui.leftClicked(id)) {
                s.open = !s.open;
                try app.signal(.redraw);
            } else if (ui.focused(id) and openKeyPressed(ui.input)) {
                s.open = true;
                ui.input.consumeKeyboard();
                try app.signal(.redraw);
            }

            if (s.open and ui.input.containsKey(.escape)) {
                s.open = false;
                ui.input.consumeKeyboard();
                try app.signal(.redraw);
            }

            const is_hovered = ui.hovering(id);
            const is_active = is_hovered or ui.focused(id) or s.open;
            const t: f32 = if (self.hover_anim) |ha|
                ui.anim(id, "hover", if (is_active) 1.0 else 0.0, ha.opts)
            else if (is_active) 1.0 else 0.0;

            var deco_rect = self.style.toRect(&ui.theme);
            if (self.hover_style) |hs| {
                const hover_rect = self.style.merge(hs).toRect(&ui.theme);
                deco_rect.color = math.lerp(@as(math.Vec4, deco_rect.color), @as(math.Vec4, hover_rect.color), t);
                deco_rect.corner_radius = .lerp(deco_rect.corner_radius, hover_rect.corner_radius, t);
                deco_rect.border_width = BorderWidth.lerp(deco_rect.border_width, hover_rect.border_width, t);
                deco_rect.border_color = math.lerp(@as(math.Vec4, deco_rect.border_color), @as(math.Vec4, hover_rect.border_color), t);
            } else if (t > 0.0) {
                const brighten = if (self.hover_anim) |ha| ha.brighten else 0.15;
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
                .focusable = true,
                .grid_placement = self.grid_placement,
            }, .{ .rect = deco_rect });
            try ui.setAccessibility(rect, .{
                .role = .button,
                .name = if (self.text) |t_| t_.content else &.{},
                .state = .{ .expanded = s.open },
            });

            if (self.text) |text| {
                const text_color: Color.Input =
                    self.style.color.onColor() orelse
                    text.color orelse .text;
                try app.e(Text{
                    .content = text.content,
                    .font = text.font,
                    .key = self.key.indexed(TEXT_INDEX),
                    .selectable = false,
                    .size = text.size,
                    .color = text_color,
                });
            }

            return rect;
        }

        pub fn close(self: *const Self, app: *App) !void {
            const ui = &app.ui;
            const id = self.key.hash();
            ui.close();

            const s = try ui.state.getOrCreate(.menu_button, ui.allocator, id);
            if (!s.open) return;

            try self.renderPopup(app, s);

            if (self.close_on_popup_click) {
                const popup_id = self.key.indexed(POPUP_INDEX).hash();
                if (ui.leftClickedWithin(popup_id)) {
                    s.open = false;
                    try app.signal(.redraw);
                }
            }
        }

        fn renderPopup(self: *const Self, app: *App, s: *State.MenuButton) !void {
            const ui = &app.ui;
            const popup_key = self.key.indexed(POPUP_INDEX);
            const popup_id = popup_key.hash();

            _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
            const measured = ui.state.get(.measured, popup_id);
            const measured_box = if (measured) |m| m.box else math.Rect.zero;
            if (!s.popup_box.eql(measured_box)) {
                s.popup_box = measured_box;
                try app.signal(.redraw);
            }

            const measured_h = if (measured_box.h() > 0) measured_box.h() else self.fallback_menu_height;
            const requested_w = self.menu_width orelse s.anchor_box.w();
            const p = placePopup(s.viewport_box, s.anchor_box, requested_w, measured_h);

            _ = try ui.openRoot(popup_key, p.x, p.y, .{
                .direction = .column,
                .width = .fixed(p.width),
                .height = .{ .kind = .fit, .max = p.max_height },
                .overflow = .scroll_y,
                .z_index = self.popup_z_index,
                .padding = self.popup_padding,
                .gap = self.popup_gap,
                .interactive = true,
            }, .{ .rect = self.popup_style.toRect(&ui.theme) });

            try app.e(self.menu);

            ui.close();
        }
    };
}

fn openKeyPressed(input: ui_mod.Input) bool {
    return input.containsKey(.enter) or
        input.containsKey(.kp_enter) or
        input.containsKey(.space) or
        input.containsKey(.down);
}

fn isPointerInside(s: *const State.MenuButton, mouse_pos: [2]f64) bool {
    return containsInputPoint(s.anchor_box, mouse_pos) or
        containsInputPoint(s.popup_box, mouse_pos);
}

fn containsInputPoint(rect: math.Rect, mouse_pos: [2]f64) bool {
    const p: math.Vec2 = .{
        @floatCast(mouse_pos[0]),
        @floatCast(mouse_pos[1]),
    };
    return rect.contains(p);
}

fn placePopup(viewport: math.Rect, anchor: math.Rect, requested_width: f32, estimated_height: f32) Placement {
    const viewport_w = @max(0, viewport.w());
    const viewport_h = @max(0, viewport.h());
    const width = @max(0, @min(requested_width, viewport_w));

    const left = viewport.x();
    const top = viewport.y();
    const right = left + viewport_w;
    const bottom = top + viewport_h;

    const raw_x = anchor.x();
    const x = clampAxis(raw_x, left, right - width);

    const anchor_bottom = anchor.y() + anchor.h();
    const space_below = @max(0, bottom - anchor_bottom);
    const space_above = @max(0, anchor.y() - top);
    const opens_above = estimated_height > space_below and space_above > space_below;
    const max_height = if (opens_above) space_above else space_below;
    const height = @min(estimated_height, max_height);
    const raw_y = if (opens_above) anchor.y() - height else anchor_bottom;
    const y = clampAxis(raw_y, top, bottom - height);

    return .{
        .x = x,
        .y = y,
        .width = width,
        .max_height = max_height,
    };
}

fn clampAxis(value: f32, min: f32, max: f32) f32 {
    if (max <= min) return min;
    return std.math.clamp(value, min, max);
}
