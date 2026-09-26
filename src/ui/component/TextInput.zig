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

const BODY_INDEX: usize = 1; // text decoration
const CURSOR_INDEX: usize = 2; // cursor overlay
const SELECTION_BASE: usize = 16; // selection line overlays start here, one per line

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
};

pub const base = struct {
    pub const root: Style = .{
        .width = .grow(),
        .@"align" = .center,
        .padding = .init(6, 10, 6, 10),
        .overflow = .scroll_x,
        .background = .elevated,
        .border_width = .all(1),
        .border_color = .toned,
        .hover = &.{ .border_color = .dimmed },
        .focus = &.{ .border_color = .accent },
    };
    pub const placeholder: Style = .{ .foreground = .dimmed };
    pub const caret: Style = .{ .background = .current };
    pub const selection: Style = .{ .background = .accent, .opacity = 0.4 };
};

const TextInput = @This();

pub fn open(self: *const TextInput, frame: *Frame) !Element.Id {
    try edit.validateByteLimit(self.bytes_max);
    const ui = frame.ui();
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    const edit_state = try ui.state.getOrCreate(.text_input, ui.allocator, id);
    try edit.processAccessibility(self.buf, frame, edit_state, id, self.bytes_max);

    if (is_focused) {
        ui.requestTextInput();
        try edit.processInputEarly(self.buf, frame, edit_state, false, self.bytes_max);
    }

    if (ui.hovering(id)) ui.requestCursor(.text);
    const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, ui.states(id, .{}), null);
    var config = root.element(.{ .interactive = true, .focusable = true });
    const padding = root.layout.padding;
    config.height.min = @max(config.height.min, try ui.lineHeight(root.content.font_size, root.content.font) + padding.top() + padding.bottom());

    const element_id = try ui.openResolved(self.key, &root, config, null);
    return element_id;
}

pub fn close(self: *const TextInput, frame: *Frame) !void {
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
        const shaped = try face.shapeWrapped(items, content.font_size * scale, 0);
        const line_h = shaped.line_height / scale;
        const measured = try ui.state.getOrCreate(.measured, ui.allocator, id);
        const scroll = try ui.state.getOrCreate(.scroll, ui.allocator, id);
        const content_origin = [2]f32{
            measured.box.x() + padding.left(),
            measured.box.y() + padding.top(),
        };

        edit.processMouse(ui, id, items, s, shaped, content_origin, scroll.offset, scale);

        try edit.processInputLate(
            self.buf,
            false,
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
        const viewport_w = @max(0, measured.width - padding.left() - padding.right());
        ensureCaretVisibleX(scroll, cursor_pos.x, viewport_w, shaped.width / scale);
        const scroll_x = scroll.offset[0];

        if (has_sel) {
            const selection = ui.resolveStyle(self.key.indexed(SELECTION_BASE).hash(), .{ .base = &base.selection, .user = self.parts.selection }, .{}, null);
            const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
            defer ui.allocator.free(spans);
            for (spans, 0..) |sp, i| {
                _ = try ui.open(self.key.indexed(SELECTION_BASE + i), .at(sp.x - scroll_x, sp.y, sp.w, line_h), .{ .rect = selection.surface });
                ui.close();
            }
        } else {
            const caret = ui.resolveStyle(self.key.indexed(CURSOR_INDEX).hash(), .{ .base = &base.caret, .user = self.parts.caret }, .{}, null);
            _ = try ui.open(self.key.indexed(CURSOR_INDEX), .at(cursor_pos.x - scroll_x, cursor_pos.y, 1, line_h), .{ .rect = caret.surface });
            ui.close();
        }

        if (has_sel) ui.state.selection_text = items[sel_lo..sel_hi];
    }

    if (!is_focused and items.len == 0) {
        if (self.placeholder.len > 0)
            _ = try ui.styledText(self.key.indexed(BODY_INDEX), self.placeholder, .{ .base = &base.placeholder, .user = self.parts.placeholder }, .{});
    } else if (items.len > 0) {
        var deco = try ui.textDecoration(items, content.font_size, content.font, false);
        deco.text.color = content.foreground;
        _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = .fit(), .height = .fit() }, deco);
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

fn ensureCaretVisibleX(scroll: *State.Scroll, caret_x: f32, viewport_w: f32, content_w: f32) void {
    const max_off = @max(0, content_w - viewport_w);
    if (viewport_w <= 0) {
        scroll.offset[0] = std.math.clamp(scroll.offset[0], 0, max_off);
        return;
    }

    if (caret_x < scroll.offset[0]) {
        scroll.offset[0] = caret_x;
    } else if (caret_x + 1 > scroll.offset[0] + viewport_w) {
        scroll.offset[0] = caret_x + 1 - viewport_w;
    }
    scroll.offset[0] = std.math.clamp(scroll.offset[0], 0, max_off);
}
