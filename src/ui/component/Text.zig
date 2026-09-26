const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const UI = ui_mod.UI;
const State = ui_mod.State;
const Style = ui_mod.Style;
const Key = ui_mod.Key;
const Element = @import("layout").Element;
const util = @import("util.zig");

content: []const u8,
selectable: bool = true,
key: Key,
/// Font, size, foreground and wrap are inherited from the parent when unset.
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    selection: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{};
    pub const selection: Style = .{ .background = .accent, .opacity = 0.4 };
};

const Text = @This();

const BODY_INDEX: usize = 1; // text decoration
const SELECTION_INDEX: usize = 2; // selection style scope
const SPANS_BASE: usize = 16; // selection line overlays start here, one per line

fn resolve(self: *const Text, ui: *UI) Style.Resolved {
    return ui.resolveStyle(self.key.hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
}

pub fn open(self: *const Text, frame: *Frame) !Element.Id {
    const ui = frame.ui();
    const resolved = self.resolve(ui);
    if (!self.selectable) {
        const decoration = try ui.textDecorationStyled(self.content, &resolved);
        const id = try ui.openWith(self.key, resolved.element(.{}), decoration, .{ .content = resolved.content });
        try ui.setAccessibility(id, .{ .role = .text_run, .state = .{ .value_text = self.content } });
        return id;
    }

    const id = try ui.openWith(self.key, resolved.element(.{ .interactive = true }), .none, .{ .content = resolved.content });
    try ui.setAccessibility(id, .{ .role = .text_run, .state = .{ .value_text = self.content } });
    return id;
}

pub fn close(self: *const Text, frame: *Frame) !void {
    const ui = frame.ui();
    if (!self.selectable) {
        ui.close();
        return;
    }

    const id = self.key.hash();
    const s = try ui.state.getOrCreate(.text_select, ui.allocator, id);

    if (ui.input.mouseButton(.left).released) s.dragging = false;

    const len: u32 = @intCast(self.content.len);
    const press_here = ui.input.mouseButton(.left).pressed and ui.hovering(id);
    const is_drag = ui.pressing(id) and ui.input.mouseButton(.left).down;
    const need_hit_test = (press_here or is_drag) and s.box.w() > 0 and s.box.h() > 0;
    const has_prior_selection = @min(s.anchor_byte, len) != @min(s.cursor_byte, len);

    // Resolved again inside our own slot: the recorded content is authoritative.
    var resolved = self.resolve(ui);
    resolved.content = ui.contents.items[ui.currentSlot()];
    if (need_hit_test or has_prior_selection) {
        try self.closeSlow(ui, s, &resolved, need_hit_test, press_here);
        return;
    }

    const deco = try ui.textDecorationStyled(self.content, &resolved);
    const inner_w: Element.sizing.Axis = if (resolved.wrap) .grow() else .fit();
    _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = inner_w, .height = .fit() }, deco);
    ui.close();

    ui.close();
}

fn closeSlow(self: *const Text, ui: *UI, s: *State.TextSelect, resolved: *const Style.Resolved, need_hit_test: bool, press_here: bool) !void {
    const scale = ui.content_scale;
    const face = try ui.font.getFace(resolved.content.font);
    const wrap_px: f32 = if (resolved.wrap) @max(0, s.box.w() * scale) else 0;
    const shaped = try face.shapeWrapped(self.content, resolved.content.font_size * scale, wrap_px);
    const line_h = shaped.line_height / scale;

    if (need_hit_test) {
        const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
        const my: f32 = @floatCast(ui.input.mouse_pos[1]);
        const local: util.Pos = .{ .x = mx - s.box.x(), .y = my - s.box.y() };
        const byte = util.byteAtPos(shaped, local, scale);
        if (press_here) {
            s.dragging = true;
            s.anchor_byte = byte;
            s.cursor_byte = byte;
        } else if (s.dragging) {
            s.cursor_byte = byte;
        }
    }

    const len: u32 = @intCast(self.content.len);
    const anchor = @min(s.anchor_byte, len);
    const cursor = @min(s.cursor_byte, len);
    const sel_lo = @min(anchor, cursor);
    const sel_hi = @max(anchor, cursor);

    if (sel_lo != sel_hi) {
        ui.state.selection_text = self.content[sel_lo..sel_hi];

        const selection_key = self.key.indexed(SELECTION_INDEX);
        const selection = ui.resolveStyle(selection_key.hash(), .{ .base = &base.selection, .user = self.parts.selection }, .{}, null);

        const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
        defer ui.allocator.free(spans);

        for (spans, 0..) |sp, i| {
            _ = try ui.open(self.key.indexed(SPANS_BASE + i), .at(sp.x, sp.y, sp.w, line_h), .{ .rect = selection.surface });
            ui.close();
        }
    }

    const deco = try ui.textDecorationStyled(self.content, resolved);
    const inner_w: Element.sizing.Axis = if (resolved.wrap) .grow() else .fit();
    _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = inner_w, .height = .fit() }, deco);
    ui.close();

    ui.close();
}
