const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const math = @import("math");
const ui_mod = @import("../root.zig");
const placePopup = @import("popup.zig").place;

const Key = ui_mod.Key;
const State = ui_mod.State;
const Style = ui_mod.Style;

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

            if (ui.input.mouseButton(.right).pressed and ui.isHoveredWithin(id)) {
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
            // Clicks on popup padding keep the menu open
            if (ui.isHoveredWithin(popup_id) and ui.state.hovered != popup_id and ui.leftClicked(ui.state.hovered, .within)) {
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
            const p = placePopup(s.viewport_box, .init(s.click_pos[0], s.click_pos[1], 0, 0), requested_w, measured_h);

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

fn sameRect(a: math.Rect, b: math.Rect) bool {
    return a.x() == b.x() and
        a.y() == b.y() and
        a.w() == b.w() and
        a.h() == b.h();
}
