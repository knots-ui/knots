const std = @import("std");

const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const math = @import("math");
const ui_mod = @import("../root.zig");

const Button = @import("Button.zig");

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
        label: ?[]const u8 = null,
        fallback_menu_height: f32 = 180,
        close_on_popup_click: bool = true,
        style: *const Style = &.{},
        parts: Parts = .{},

        pub const Parts = menu_parts;
        pub const base = menu_base;

        const Self = @This();
        const POPUP_INDEX: usize = 1;
        const TEXT_INDEX: usize = 2;

        pub fn open(self: *const Self, frame: *Frame) !Element.Id {
            const ui = frame.ui();
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.menu_button, ui.allocator, id);

            if (s.open and ui.input.mouseButton(.left).pressed and !isPointerInside(s, ui.input.mouse_pos)) {
                s.open = false;
                frame.requestRedraw();
            }

            if (ui.leftPressed(id, .exact)) {
                s.open = !s.open;
                frame.requestRedraw();
            } else if (ui.focused(id) and openKeyPressed(ui.input)) {
                s.open = true;
                ui.input.consumeKeyboard();
                frame.requestRedraw();
            }

            if (s.open and ui.input.containsKey(.escape)) {
                s.open = false;
                ui.input.consumeKeyboard();
                frame.requestRedraw();
            }

            const st = ui.states(id, .{ .open = s.open });
            const root = try ui.openStyled(self.key, .{ .base = &base.root, .user = self.style }, st, .{ .interactive = true, .focusable = true });
            try ui.setAccessibility(root.id, .{
                .role = .button,
                .name = self.label orelse &.{},
                .state = .{ .expanded = s.open },
            });

            if (self.label) |label| {
                _ = try ui.styledText(self.key.indexed(TEXT_INDEX), label, .{ .base = &base.label, .user = self.parts.label }, st);
            }

            return root.id;
        }

        pub fn close(self: *const Self, frame: *Frame) !void {
            const ui = frame.ui();
            const id = self.key.hash();
            const content = ui.contents.items[ui.currentSlot()];
            ui.close();

            const s = try ui.state.getOrCreate(.menu_button, ui.allocator, id);
            if (!s.open) return;

            try self.renderPopup(frame, s, &content);

            if (self.close_on_popup_click) {
                const popup_id = self.key.indexed(POPUP_INDEX).hash();
                if (ui.leftClicked(popup_id, .within)) {
                    s.open = false;
                    frame.requestRedraw();
                }
            }
        }

        fn renderPopup(self: *const Self, frame: *Frame, s: *State.MenuButton, parent: *const Style.Content) !void {
            const ui = frame.ui();
            const popup_key = self.key.indexed(POPUP_INDEX);
            const popup_id = popup_key.hash();

            _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
            const measured = ui.state.get(.measured, popup_id);
            const measured_box = if (measured) |m| m.box else math.Rect.zero;
            if (!s.popup_box.eql(measured_box)) {
                s.popup_box = measured_box;
                frame.requestRedraw();
            }

            const popup = ui.resolveStyle(popup_id, .{ .base = &base.popup, .user = self.parts.popup }, .{}, parent);
            const measured_h = if (measured_box.h() > 0) measured_box.h() else self.fallback_menu_height;
            const requested_w = if (popup.layout.width.kind == .fixed) popup.layout.width.value else s.anchor_box.w();
            const p = placePopup(s.viewport_box, s.anchor_box, requested_w, measured_h);

            var config = popup.element(.{ .interactive = true });
            config.width = .fixed(p.width);
            config.height = .{ .kind = .fit, .max = p.max_height };
            _ = try ui.openResolved(popup_key, &popup, config, .{ p.x, p.y });

            try frame.e(self.menu);

            ui.close();
        }
    };
}

const menu_parts = struct {
    label: *const Style = &.{},
    /// A fixed `width` sizes the popup; otherwise it matches the button.
    popup: *const Style = &.{},
};

const menu_base = struct {
    pub const root = Button.base.root;
    pub const label = Button.base.label;
    pub const popup: Style = .{
        .direction = .column,
        .padding = .all(4),
        .gap = 2,
        .overflow = .scroll_y,
        .layer = .popup,
        .background = .elevated,
        .foreground = .text,
        .radius = .sm,
        .border_width = .all(1),
        .border_color = .toned,
    };
};

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
