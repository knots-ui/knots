const std = @import("std");

const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const math = @import("math");
const ui_mod = @import("../root.zig");

const Key = ui_mod.Key;
const State = ui_mod.State;
const Style = ui_mod.Style;

pub const Placement = struct {
    x: f32,
    y: f32,
    width: f32,
    max_height: f32,
};

pub fn ContextMenu(comptime Menu: type) type {
    return struct {
        key: Key,
        menu: Menu,
        fallback_menu_height: f32 = 180,
        style: *const Style = &.{},
        parts: Parts = .{},

        pub const Parts = context_parts;
        pub const base = context_base;

        const Self = @This();
        const POPUP_INDEX: usize = 1;

        pub fn open(self: *const Self, frame: *Frame) !Element.Id {
            const ui = frame.ui();
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.context_menu, ui.allocator, id);

            if (s.open and (ui.input.mouseButton(.left).pressed or ui.input.mouseButton(.right).pressed)) {
                if (!isPointerInside(s, ui.input.mouse_pos)) {
                    s.open = false;
                }
            }

            if (s.open and ui.input.containsKey(.escape)) {
                s.open = false;
                ui.input.consumeKeyboard();
            }

            if (ui.input.mouseButton(.right).pressed and containsInputPoint(s.anchor_box, ui.input.mouse_pos)) {
                openAtPointer(s, ui.input.mouse_pos);
                frame.requestRedraw();
            } else if (ui.focused(id) and ui.input.containsKey(.menu)) {
                openAtAnchor(s);
                ui.input.consumeKeyboard();
                frame.requestRedraw();
            }

            const root = try ui.openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{ .open = s.open }, .{ .interactive = true });
            try ui.setAccessibility(root.id, .{
                .role = .menu,
                .state = .{ .expanded = s.open },
            });
            return root.id;
        }

        pub fn close(self: *const Self, frame: *Frame) !void {
            const ui = frame.ui();
            const id = self.key.hash();
            const content = ui.contents.items[ui.currentSlot()];
            ui.close();

            const s = try ui.state.getOrCreate(.context_menu, ui.allocator, id);
            if (!s.open) return;

            try self.renderPopup(frame, s, &content);

            const popup_id = self.key.indexed(POPUP_INDEX).hash();
            if (ui.input.mouseButton(.left).released and ui.isHoveredWithin(popup_id)) {
                s.open = false;
                frame.requestRedraw();
            }
        }

        fn renderPopup(self: *const Self, frame: *Frame, s: *State.ContextMenu, parent: *const Style.Content) !void {
            const ui = frame.ui();
            const popup_key = self.key.indexed(POPUP_INDEX);
            const popup_id = popup_key.hash();

            _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
            const measured = ui.state.get(.measured, popup_id);
            const measured_box = if (measured) |m| m.box else math.Rect.zero;
            if (!sameRect(s.popup_box, measured_box)) {
                s.popup_box = measured_box;
                frame.requestRedraw();
            }

            const popup = ui.resolveStyle(popup_id, .{ .base = &base.popup, .user = self.parts.popup }, .{}, parent);
            const measured_h = if (measured_box.h() > 0) measured_box.h() else self.fallback_menu_height;
            const requested_w = if (popup.layout.width.kind == .fixed) popup.layout.width.value else 180;
            const p = placePopup(s.viewport_box, s.click_pos, requested_w, measured_h);

            var config = popup.element(.{ .interactive = true });
            config.width = .fixed(p.width);
            config.height = .{ .kind = .fit, .max = p.max_height };
            _ = try ui.openResolved(popup_key, &popup, config, .{ p.x, p.y });

            try frame.e(self.menu);

            ui.close();
        }
    };
}

const context_parts = struct {
    /// A fixed `width` sizes the popup.
    popup: *const Style = &.{},
};

const context_base = struct {
    pub const root: Style = .{};
    pub const popup: Style = .{
        .width = .fixed(180),
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

fn openAtPointer(s: *State.ContextMenu, mouse_pos: [2]f64) void {
    s.open = true;
    s.click_pos = .{
        @floatCast(mouse_pos[0]),
        @floatCast(mouse_pos[1]),
    };
}

fn openAtAnchor(s: *State.ContextMenu) void {
    s.open = true;
    s.click_pos = .{
        s.anchor_box.x(),
        s.anchor_box.y() + s.anchor_box.h(),
    };
}

fn isPointerInside(s: *const State.ContextMenu, mouse_pos: [2]f64) bool {
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

pub fn placePopup(viewport: math.Rect, click_pos: math.Vec2, requested_width: f32, estimated_height: f32) Placement {
    const viewport_w = @max(0, viewport.w());
    const viewport_h = @max(0, viewport.h());
    const width = @max(0, @min(requested_width, viewport_w));

    const left = viewport.x();
    const top = viewport.y();
    const right = left + viewport_w;
    const bottom = top + viewport_h;

    const opens_left = click_pos[0] + width > right and click_pos[0] - width >= left;
    const raw_x = if (opens_left) click_pos[0] - width else click_pos[0];
    const x = clampAxis(raw_x, left, right - width);

    const space_below = @max(0, bottom - click_pos[1]);
    const space_above = @max(0, click_pos[1] - top);
    const opens_above = estimated_height > space_below and space_above > space_below;
    const max_height = if (opens_above) space_above else space_below;
    const height = @min(estimated_height, max_height);
    const raw_y = if (opens_above) click_pos[1] - height else click_pos[1];
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

fn sameRect(a: math.Rect, b: math.Rect) bool {
    return a.x() == b.x() and
        a.y() == b.y() and
        a.w() == b.w() and
        a.h() == b.h();
}
