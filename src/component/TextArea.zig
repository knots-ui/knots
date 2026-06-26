const std = @import("std");

const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Color = @import("ui").Color;
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const Radius = @import("ui").Radius;
const Decoration = @import("ui").Decoration;

const Element = @import("layout").Element;
const util = @import("util.zig");
const edit = @import("text_edit.zig");

const BODY_INDEX: usize = 1;
const CURSOR_INDEX: usize = 2;
const HANDLE_INDEX: usize = 3;
const PILL_INDEX: usize = 4;
const SELECTION_BASE: usize = 16;
const GRIP_HIT_H: f32 = 10;
const GRIP_W: f32 = 40;
const GRIP_H: f32 = 5;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fixed(96),
size: Size.Input = .sm,
buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
color: Color.Input = .text,
placeholder_color: Color.Input = .dimmed,
style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
hover_style: ?Style.Override = .{ .border_color = .dimmed },
focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = .all(1) },
padding: Element.Padding = .init(6, 10, 6, 10),
key: Key,

const TextArea = @This();

pub fn open(self: *const TextArea, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    if (ui.hovering(id)) ui.requestCursor(.text);
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    if (is_focused) {
        const s = try ui.state.getOrCreate(.text_input, ui.allocator, id);
        try edit.processInputEarly(self.buf, app, s, true);
    }

    const rs = try ui.state.getOrCreate(.resize, ui.allocator, id);
    const handle_id = self.key.indexed(HANDLE_INDEX).hash();

    const line_h = try ui.lineHeight(self.size.resolve(), null);
    const min_h = line_h + self.padding.top() + self.padding.bottom();

    if (ui.pressing(handle_id) and ui.input.mouseButton(.left).down and rs.box.h() > 0) {
        const my: f32 = @floatCast(ui.input.mouse_pos[1]);
        rs.height = @max(min_h, my - rs.box.y());
    }

    var height = if (rs.height > 0) Element.sizing.Axis.fixed(@max(min_h, rs.height)) else self.height;
    height.min = @max(height.min, min_h);

    const is_hovered = ui.hovering(id) or ui.hovering(handle_id);
    const current_style = if (is_focused)
        self.focused_style
    else if (is_hovered)
        if (self.hover_style) |hs| self.style.merge(hs) else self.style
    else
        self.style;

    const decoration: Decoration = if (current_style.hasDecoration())
        .{ .rect = current_style.toRect(&ui.theme) }
    else
        .none;

    const element_id = try ui.open(self.key, .{
        .width = self.width,
        .height = height,
        .overflow = .scroll_y,
        .interactive = true,
        .focusable = true,
        .padding = self.padding,
    }, decoration);
    try ui.setAccessibility(element_id, .{
        .role = .text_input,
        .name = self.placeholder,
        .state = .{ .value_text = self.buf.items, .multiline = true },
    });
    return element_id;
}

pub fn close(self: *const TextArea, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const resolved_color = self.color.resolve(&ui.theme);
    const size = self.size.resolve();

    const display, const color = if (!is_focused and items.len == 0)
        .{ self.placeholder, self.placeholder_color.resolve(&ui.theme) }
    else
        .{ items, resolved_color };

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const scale = ui.content_scale;

        const face = try ui.font.getFace(null);
        const m = try ui.state.getOrCreate(.measured, ui.allocator, id);
        const content_w = m.width - self.padding.left() - self.padding.right();
        const wrap_px: f32 = @max(0, content_w * scale);
        const shaped = try face.shapeWrapped(items, size.value * scale, wrap_px);
        const line_h = shaped.line_height / scale;
        const scroll = try ui.state.getOrCreate(.scroll, ui.allocator, id);
        const content_origin = [2]f32{
            m.box.x() + self.padding.left(),
            m.box.y() + self.padding.top(),
        };

        edit.processMouse(ui, id, items, s, shaped, content_origin, scroll.offset, scale);

        try edit.processInputLate(self.buf, true, ui, s, shaped, line_h);
        ui.input.consumeKeyboard();

        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;
        const cursor_pos = util.posAtByte(shaped, s.cursor, scale);
        const viewport_h = @max(0, m.height - self.padding.top() - self.padding.bottom());
        ensureCaretVisibleY(scroll, cursor_pos.y, line_h, viewport_h, shaped.height / scale);
        const scroll_offset = scroll.offset;

        if (has_sel) {
            const sel_color = blk: {
                const base: Color.Input = .primary;
                var c = base.resolve(&ui.theme);
                c[3] = 0.4;
                break :blk c;
            };
            const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
            defer ui.allocator.free(spans);
            for (spans, 0..) |sp, i| {
                _ = try ui.openAt(self.key.indexed(SELECTION_BASE + i), sp.x - scroll_offset[0], sp.y - scroll_offset[1], sp.w, line_h, .{}, .{ .rect = .{ .color = sel_color } });
                ui.close();
            }
        } else {
            _ = try ui.openAt(self.key.indexed(CURSOR_INDEX), cursor_pos.x - scroll_offset[0], cursor_pos.y - scroll_offset[1], 1, line_h, .{}, .{ .rect = .{ .color = resolved_color } });
            ui.close();
        }

        if (has_sel) ui.state.selection_text = items[sel_lo..sel_hi];
    }

    if (display.len > 0) {
        var deco = try ui.textDecoration(display, size, null, true);
        deco.text.color = color;
        _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = .grow(), .height = .fit() }, deco);
        ui.close();
    }

    const rs = ui.state.get(.resize, id).?;
    if (rs.box.h() > 0) {
        const handle_id = self.key.indexed(HANDLE_INDEX).hash();
        const active = ui.hovering(handle_id) or ui.pressing(handle_id);
        if (active) ui.requestCursor(.resize_vertical);
        var grip: Color.Input = .text;
        var grip_color = grip.resolve(&ui.theme);
        grip_color[3] = if (active) 0.6 else 0.35;

        const cur_h = if (rs.height > 0) rs.height else rs.box.h();
        const bottom = cur_h - self.padding.top();
        const left = -self.padding.left();

        const hit_y = bottom - GRIP_HIT_H;
        _ = try ui.openAt(self.key.indexed(HANDLE_INDEX), left, hit_y, rs.box.w(), GRIP_HIT_H, .{ .interactive = true }, .none);
        ui.close();

        const pill_y = bottom - (GRIP_HIT_H + GRIP_H) * 0.5;
        const pill_x = (rs.box.w() - GRIP_W) * 0.5 + left;
        _ = try ui.openAt(self.key.indexed(PILL_INDEX), pill_x, pill_y, GRIP_W, GRIP_H, .{}, .{ .rect = .{ .color = grip_color, .corner_radius = .all(2) } });
        ui.close();
    }

    ui.close();
}

fn ensureCaretVisibleY(scroll: *State.Scroll, caret_y: f32, line_h: f32, viewport_h: f32, content_h: f32) void {
    const max_off = @max(0, content_h - viewport_h);
    if (viewport_h <= 0) {
        scroll.offset[1] = std.math.clamp(scroll.offset[1], 0, max_off);
        return;
    }

    if (caret_y < scroll.offset[1]) {
        scroll.offset[1] = caret_y;
    } else if (caret_y + line_h > scroll.offset[1] + viewport_h) {
        scroll.offset[1] = caret_y + line_h - viewport_h;
    }
    scroll.offset[1] = std.math.clamp(scroll.offset[1], 0, max_off);
}
