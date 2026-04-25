const UI = @import("ui").UI;
const State = @import("ui").State;
const Color = @import("ui").Color;
const Element = @import("layout").Element;
const Key = UI.Key;
const util = @import("util.zig");

width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
size: f32 = 14,
content: []const u8,
color: Color.Input = .text,
font: ?[]const u8 = null,
selectable: bool = true,
highlight_color: Color.Input = .primary,
key: Key,

const Text = @This();

pub fn open(self: *const Text, ui: *UI) !Element.Id {
    if (!self.selectable) {
        var decoration = try ui.textDecoration(self.content, self.size, self.font);
        decoration.text.color = self.color.resolve();
        return try ui.open(self.key, .{
            .width = self.width,
            .height = self.height,
        }, decoration);
    }

    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .interactive = true,
    }, .none);
}

pub fn close(self: *const Text, ui: *UI) !void {
    if (!self.selectable) {
        ui.close();
        return;
    }

    const id = self.key.hash();
    const s = try ui.state.getOrCreate(.text_select, ui.allocator, id);

    if (ui.input.mouse_released) s.dragging = false;

    const len: u32 = @intCast(self.content.len);
    const press_here = ui.input.mouse_pressed and ui.hovering(id);
    const is_drag = ui.pressing(id) and ui.input.mouse_down;
    const need_hit_test = (press_here or is_drag) and s.box.w > 0 and s.box.h > 0;
    const has_prior_selection = @min(s.anchor_byte, len) != @min(s.cursor_byte, len);

    if (need_hit_test or has_prior_selection) {
        try self.closeSlow(ui, s, need_hit_test, press_here);
        return;
    }

    var deco = try ui.textDecoration(self.content, self.size, self.font);
    deco.text.color = self.color.resolve();
    _ = try ui.open(self.key.indexed(1), .{ .width = .fit(), .height = .fit() }, deco);
    ui.close();

    ui.close();
}

fn closeSlow(
    self: *const Text,
    ui: *UI,
    s: *State.TextSelect,
    need_hit_test: bool,
    press_here: bool,
) !void {
    const scale = ui.content_scale;
    const face = try ui.font.getFace(self.font);
    const shaped = try face.shape(self.content, self.size * scale);
    const line_h = (try face.lineHeight(self.size * scale)) / scale;

    if (need_hit_test) {
        const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
        const local_x = mx - s.box.x;
        const byte = util.byteOffsetAtX(shaped.glyphs, self.content, local_x, scale);
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
        const xr = util.xRangeAtBytes(shaped.glyphs, sel_lo, sel_hi, scale);

        var hc = self.highlight_color.resolve();
        hc[3] = 0.4;

        _ = try ui.open(self.key.indexed(2), .{
            .width = .grow(),
            .height = .grow(),
            .position = .absolute,
            .direction = .row,
        }, .none);
        _ = try ui.open(self.key.indexed(3), .{
            .width = .fixed(xr.lo),
            .height = .fixed(0),
        }, .none);
        ui.close();
        _ = try ui.open(self.key.indexed(4), .{
            .width = .fixed(xr.hi - xr.lo),
            .height = .fixed(line_h),
        }, .{ .rect = .{ .color = hc } });
        ui.close();
        ui.close();
    }

    var deco = try ui.textDecoration(self.content, self.size, self.font);
    deco.text.color = self.color.resolve();
    _ = try ui.open(self.key.indexed(1), .{ .width = .fit(), .height = .fit() }, deco);
    ui.close();

    ui.close();
}
