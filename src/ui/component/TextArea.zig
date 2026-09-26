const std = @import("std");

const Frame = @import("../root.zig").Frame;
const UI = @import("../root.zig").UI;
const State = @import("../root.zig").State;
const Style = @import("../root.zig").Style;
const Key = @import("../root.zig").Key;
const Decoration = @import("../root.zig").Decoration;
const Face = @import("text").Face;

const Element = @import("layout").Element;
const Accessibility = @import("../Accessibility.zig");
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

buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
bytes_max: u32 = Face.text_bytes_max,
key: Key,
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    placeholder: *const Style = &.{},
    /// `background` colors the caret.
    caret: *const Style = &.{},
    selection: *const Style = &.{},
    /// Resize grip: `width`, `height`, `background`, `radius`, `opacity`.
    thumb: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{
        .width = .grow(),
        .height = .fixed(96),
        .padding = .init(6, 10, 6, 10),
        .overflow = .scroll_y,
        .background = .elevated,
        .border_width = .all(1),
        .border_color = .toned,
        .hover = &.{ .border_color = .dimmed },
        .focus = &.{ .border_color = .accent },
    };
    pub const placeholder: Style = .{ .foreground = .dimmed, .width = .grow(), .wrap = true };
    pub const caret: Style = .{ .background = .current };
    pub const selection: Style = .{ .background = .accent, .opacity = 0.4 };
    pub const thumb: Style = .{
        .width = .fixed(40),
        .height = .fixed(5),
        .background = .current,
        .radius = .{ .fixed = 2 },
        .opacity = 0.35,
        .hover = &.{ .opacity = 0.6 },
        .active = &.{ .opacity = 0.6 },
    };
};

const TextArea = @This();

pub fn open(self: *const TextArea, frame: *Frame) !Element.Id {
    try edit.validateByteLimit(self.bytes_max);
    const ui = frame.ui();
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    if (ui.hovering(id)) ui.requestCursor(.text);
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    const edit_state = try ui.state.getOrCreate(.text_input, ui.allocator, id);
    try edit.processAccessibility(self.buf, frame, edit_state, id, self.bytes_max);

    if (is_focused) {
        ui.requestTextInput();
        try edit.processInputEarly(self.buf, frame, edit_state, true, self.bytes_max);
    }

    const rs = try ui.state.getOrCreate(.resize, ui.allocator, id);
    const handle_id = self.key.indexed(HANDLE_INDEX).hash();

    const st = ui.states(id, .{ .hover = ui.hovering(handle_id) });
    const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, st, null);
    const padding = root.layout.padding;
    const line_h = try ui.lineHeight(root.content.font_size, root.content.font);
    const min_h = line_h + padding.top() + padding.bottom();

    if (ui.pressing(handle_id) and ui.input.mouseButton(.left).down and rs.box.h() > 0) {
        const my: f32 = @floatCast(ui.input.mouse_pos[1]);
        rs.height = @max(min_h, my - rs.box.y());
    }

    var config = root.element(.{ .interactive = true, .focusable = true });
    if (rs.height > 0) config.height = .fixed(@max(min_h, rs.height));
    config.height.min = @max(config.height.min, min_h);

    const element_id = try ui.openResolved(self.key, &root, config, null);
    return element_id;
}

pub fn close(self: *const TextArea, frame: *Frame) !void {
    const ui = frame.ui();
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const content = ui.contents.items[ui.currentSlot()];
    const padding = (ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, .{}, null)).layout.padding;

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const scale = ui.content_scale;

        const face = try ui.font.getFace(content.font);
        const m = try ui.state.getOrCreate(.measured, ui.allocator, id);
        const content_w = m.width - padding.left() - padding.right();
        const wrap_px: f32 = @max(0, content_w * scale);
        const shaped = try face.shapeWrapped(items, content.font_size * scale, wrap_px);
        const line_h = shaped.line_height / scale;
        const scroll = try ui.state.getOrCreate(.scroll, ui.allocator, id);
        const content_origin = [2]f32{
            m.box.x() + padding.left(),
            m.box.y() + padding.top(),
        };

        edit.processMouse(ui, id, items, s, shaped, content_origin, scroll.offset, scale);

        try edit.processInputLate(
            self.buf,
            true,
            ui,
            s,
            shaped,
            line_h,
            self.bytes_max,
        );
        ui.input.consumeKeyboard();

        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;
        const cursor_pos = util.posAtByte(shaped, s.cursor, scale);
        const viewport_h = @max(0, m.height - padding.top() - padding.bottom());
        ensureCaretVisibleY(scroll, cursor_pos.y, line_h, viewport_h, shaped.height / scale);
        const scroll_offset = scroll.offset;

        if (has_sel) {
            const selection = ui.resolveStyle(self.key.indexed(SELECTION_BASE).hash(), .{ .base = &base.selection, .user = self.parts.selection }, .{}, null);
            const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
            defer ui.allocator.free(spans);
            for (spans, 0..) |sp, i| {
                _ = try ui.open(self.key.indexed(SELECTION_BASE + i), .at(sp.x - scroll_offset[0], sp.y - scroll_offset[1], sp.w, line_h), .{ .rect = selection.surface });
                ui.close();
            }
        } else {
            const caret = ui.resolveStyle(self.key.indexed(CURSOR_INDEX).hash(), .{ .base = &base.caret, .user = self.parts.caret }, .{}, null);
            _ = try ui.open(self.key.indexed(CURSOR_INDEX), .at(cursor_pos.x - scroll_offset[0], cursor_pos.y - scroll_offset[1], 1, line_h), .{ .rect = caret.surface });
            ui.close();
        }

        if (has_sel) ui.state.selection_text = items[sel_lo..sel_hi];
    }

    if (!is_focused and items.len == 0) {
        if (self.placeholder.len > 0)
            _ = try ui.styledText(self.key.indexed(BODY_INDEX), self.placeholder, .{ .base = &base.placeholder, .user = self.parts.placeholder }, .{});
    } else if (items.len > 0) {
        var deco = try ui.textDecoration(items, content.font_size, content.font, true);
        deco.text.color = content.foreground;
        _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = .grow(), .height = .fit() }, deco);
        ui.close();
    }

    const rs = ui.state.get(.resize, id).?;
    if (rs.box.h() > 0) {
        const handle_id = self.key.indexed(HANDLE_INDEX).hash();
        const active = ui.hovering(handle_id) or ui.pressing(handle_id);
        if (active) ui.requestCursor(.resize_vertical);
        const thumb = ui.resolveStyle(self.key.indexed(PILL_INDEX).hash(), .{ .base = &base.thumb, .user = self.parts.thumb }, ui.states(handle_id, .{}), null);
        const grip_w = if (thumb.layout.width.kind == .fixed) thumb.layout.width.value else GRIP_W;
        const grip_h = if (thumb.layout.height.kind == .fixed) thumb.layout.height.value else GRIP_H;

        const cur_h = if (rs.height > 0) rs.height else rs.box.h();
        const bottom = cur_h - padding.top();
        const left = -padding.left();

        const hit_y = bottom - GRIP_HIT_H;
        var hit_config: Element.Config = .at(left, hit_y, rs.box.w(), GRIP_HIT_H);
        hit_config.interactive = true;
        _ = try ui.open(self.key.indexed(HANDLE_INDEX), hit_config, .none);
        ui.close();

        const pill_y = bottom - (GRIP_HIT_H + grip_h) * 0.5;
        const pill_x = (rs.box.w() - grip_w) * 0.5 + left;
        _ = try ui.open(self.key.indexed(PILL_INDEX), .at(pill_x, pill_y, grip_w, grip_h), .{ .rect = thumb.surface });
        ui.close();
    }

    ui.close();
    const text_run_id = self.key.indexed(Accessibility.text_run_index).hash();
    const edit_state = ui.state.get(.text_input, id).?;
    try ui.setAccessibility(id, .{
        .role = .text_input,
        .text_run_id = text_run_id,
        .name = self.placeholder,
        .state = .{
            .value_text = self.buf.items,
            .multiline = true,
            .selection_anchor = edit.byteToCharacter(self.buf.items, edit_state.sel_anchor),
            .selection_focus = edit.byteToCharacter(self.buf.items, edit_state.cursor),
        },
    });
    try ui.setAccessibility(text_run_id, .{
        .role = .text_run,
        .parent = id,
        .state = .{ .value_text = self.buf.items },
    });
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
