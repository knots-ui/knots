const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const Grid = @import("layout").Grid;
const math = @import("math");
const ui_mod = @import("ui");

const Decoration = ui_mod.Decoration;
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

        @"align": Element.Align = .start,
        justify: Element.Justify = .start,
        width: Element.sizing.Axis = .fit(),
        height: Element.sizing.Axis = .fit(),
        padding: Element.Padding = .init(0, 0, 0, 0),
        dir: Element.Direction = .row,
        overflow: Element.Overflow = .visible,
        position: Element.Position = .static,
        gap: f32 = 0,
        style: Style = .{},
        grid_template: ?Grid.Template = null,
        grid_placement: ?Grid.Placement = null,

        menu_width: f32 = 180,
        fallback_menu_height: f32 = 180,
        popup_z_index: u8 = 10,
        popup_padding: Element.Padding = .init(4, 4, 4, 4),
        popup_gap: f32 = 2,
        popup_style: Style = .{ .color = .elevated, .corner_radius = .sm, .border_color = .toned, .border_width = .all(1) },

        const Self = @This();
        const POPUP_INDEX: usize = 1;

        pub fn open(self: *const Self, app: *App) !Element.Id {
            const ui = &app.ui;
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.context_menu, ui.allocator, id);

            if (s.open and (ui.input.mouse_left_pressed or ui.input.mouse_right_pressed)) {
                if (!isPointerInside(s, ui.input.mouse_pos)) {
                    s.open = false;
                }
            }

            if (s.open and ui.input.containsKey(.escape)) {
                s.open = false;
                ui.input.consumeKeyboard();
            }

            if (ui.input.mouse_right_pressed and containsInputPoint(s.anchor_box, ui.input.mouse_pos)) {
                openAtPointer(s, ui.input.mouse_pos);
                try app.signal(.redraw);
            } else if (ui.focused(id) and ui.input.containsKey(.menu)) {
                openAtAnchor(s);
                ui.input.consumeKeyboard();
                try app.signal(.redraw);
            }

            const decoration: Decoration = if (self.style.hasDecoration())
                .{ .rect = self.style.toRect(&ui.theme) }
            else
                .none;

            const element_id = try ui.open(self.key, .{
                .alignment = self.@"align",
                .justify = self.justify,
                .width = self.width,
                .height = self.height,
                .padding = self.padding,
                .overflow = self.overflow,
                .position = self.position,
                .direction = self.dir,
                .gap = self.gap,
                .interactive = true,
                .grid_template = self.grid_template,
                .grid_placement = self.grid_placement,
            }, decoration);
            try ui.setAccessibility(element_id, .{
                .role = .menu,
                .state = .{ .expanded = s.open },
            });
            return element_id;
        }

        pub fn close(self: *const Self, app: *App) !void {
            const ui = &app.ui;
            const id = self.key.hash();
            ui.close();

            const s = try ui.state.getOrCreate(.context_menu, ui.allocator, id);
            if (!s.open) return;

            try self.renderPopup(app, s);

            const popup_id = self.key.indexed(POPUP_INDEX).hash();
            if (ui.input.mouse_left_released and ui.isHoveredWithin(popup_id)) {
                s.open = false;
                try app.signal(.redraw);
            }
        }

        fn renderPopup(self: *const Self, app: *App, s: *State.ContextMenu) !void {
            const ui = &app.ui;
            const popup_key = self.key.indexed(POPUP_INDEX);
            const popup_id = popup_key.hash();

            _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
            const measured = ui.state.get(.measured, popup_id);
            const measured_box = if (measured) |m| m.box else math.Rect.zero;
            if (!sameRect(s.popup_box, measured_box)) {
                s.popup_box = measured_box;
                try app.signal(.redraw);
            }

            const measured_h = if (measured_box.h() > 0) measured_box.h() else self.fallback_menu_height;
            const p = placePopup(s.viewport_box, s.click_pos, self.menu_width, measured_h);

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
