const std = @import("std");
const builtin = @import("builtin");

const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Theme = @import("ui").Theme;
const Color = @import("ui").Color;
const Key = UI.Key;

const Element = @import("layout").Element;
const Decoration = UI.Decoration;
const glyph = @import("text").glyph;
const xAtByte = @import("util.zig").xAtByte;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fit(),
size: f32 = 14,
buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
color: Color.Input = .text,
placeholder_color: Color.Input = .dimmed,
style: Style = .{ .color = .muted },
focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = 1 },
key: Key,

const TextInput = @This();

pub fn open(self: *const TextInput, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);

    if (is_focused) {
        const s = try ui.state.getOrCreate(.text_input, ui.allocator, id);
        try processInput(self, ui, s);
        ui.input.consumeKeyboard();
    }

    const current_style = if (is_focused) self.focused_style else self.style;

    var height = self.height;
    height.min = try ui.lineHeight(self.size, null);

    const decoration: Decoration = if (current_style.hasDecoration())
        .{ .rect = current_style.toRect() }
    else
        .none;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = height,
        .overflow = .scroll_x,
        .interactive = true,
        .alignment = .center,
        .padding = .init(0, 0, 0, 6),
    }, decoration);
}

// Subkey indices under `self.key`.
const SubKey = enum(usize) {
    body = 1,
    cur_overlay = 2,
    cur_spacer = 3,
    cur_rect = 4,
    hl_overlay = 5,
    hl_spacer = 6,
    hl_rect = 7,
};

pub fn close(self: *const TextInput, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const resolved_color = self.color.resolve();

    const display, const color = if (!is_focused and items.len == 0)
        .{ self.placeholder, self.placeholder_color.resolve() }
    else
        .{ items, resolved_color };

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;
        const scale = ui.content_scale;

        const face = try ui.font.getFace(null);
        const shaped = try face.shape(items, self.size * scale);
        const line_h = (try face.lineHeight(self.size * scale)) / scale;

        if (has_sel) {
            const sel_color = comptime blk: {
                const base: Color.Input = .primary;
                var c = base.resolve();
                c[3] = 0.4;
                break :blk c;
            };
            const x_lo = xAtByte(shaped.glyphs, sel_lo, scale);
            const x_hi = xAtByte(shaped.glyphs, sel_hi, scale);
            try self.emitOverlayRect(ui, .hl_overlay, .hl_spacer, .hl_rect, x_lo, x_hi - x_lo, line_h, sel_color);
        } else {
            const cx = xAtByte(shaped.glyphs, s.cursor, scale);
            try self.emitOverlayRect(ui, .cur_overlay, .cur_spacer, .cur_rect, cx, 1, line_h, resolved_color);
        }
    }

    if (display.len > 0) {
        var deco = try ui.textDecoration(display, self.size, null);
        deco.text.color = color;
        _ = try ui.open(self.key.indexed(@intFromEnum(SubKey.body)), .{ .width = .fit(), .height = .fit() }, deco);
        ui.close();
    }

    ui.close();
}

fn emitOverlayRect(
    self: *const TextInput,
    ui: *UI,
    overlay: SubKey,
    spacer: SubKey,
    rect: SubKey,
    x: f32,
    w: f32,
    h: f32,
    color: [4]f32,
) !void {
    _ = try ui.open(self.key.indexed(@intFromEnum(overlay)), .{
        .width = .grow(),
        .height = .grow(),
        .position = .absolute,
        .direction = .row,
    }, .none);
    _ = try ui.open(self.key.indexed(@intFromEnum(spacer)), .{
        .width = .fixed(x),
        .height = .fixed(0),
    }, .none);
    ui.close();
    _ = try ui.open(self.key.indexed(@intFromEnum(rect)), .{
        .width = .fixed(w),
        .height = .fixed(h),
    }, .{ .rect = .{ .color = color } });
    ui.close();
    ui.close();
}

fn processInput(self: *const TextInput, ui: *UI, s: *State.TextInput) !void {
    const buf = self.buf;
    var len: u32 = @intCast(buf.items.len);
    s.cursor = @min(s.cursor, len);
    s.sel_anchor = @min(s.sel_anchor, len);

    for (ui.input.chars) |ch| {
        if (ch == 0) break;
        var encoded: [4]u8 = undefined;
        const n: u32 = @intCast(std.unicode.utf8Encode(ch, &encoded) catch continue);

        if (s.sel_anchor != s.cursor) deleteSelection(buf, &len, s);

        buf.insertSlice(ui.allocator, s.cursor, encoded[0..n]) catch continue;
        len += n;
        s.cursor += n;
        s.sel_anchor = s.cursor;
    }

    const super_ctrl_held = switch (builtin.os.tag) {
        .macos => ui.input.super_held,
        else => ui.input.ctrl_held,
    };

    for (ui.input.keys) |key| {
        switch (key) {
            .backspace => {
                if (s.sel_anchor != s.cursor) {
                    deleteSelection(buf, &len, s);
                } else if (s.cursor > 0) {
                    const prev = prevCharStart(buf.items, s.cursor);
                    const n = s.cursor - prev;
                    buf.replaceRangeAssumeCapacity(prev, n, &.{});
                    len -= n;
                    s.cursor = prev;
                    s.sel_anchor = s.cursor;
                }
            },
            .delete => {
                if (s.sel_anchor != s.cursor) {
                    deleteSelection(buf, &len, s);
                } else if (s.cursor < len) {
                    const next = nextCharStart(buf.items, s.cursor);
                    const n = next - s.cursor;
                    buf.replaceRangeAssumeCapacity(s.cursor, n, &.{});
                    len -= n;
                }
            },
            .left => {
                const extend = ui.input.shift_held;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @min(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor > 0) {
                    s.cursor = prevCharStart(buf.items, s.cursor);
                    if (!extend) s.sel_anchor = s.cursor;
                }
            },
            .right => {
                const extend = ui.input.shift_held;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @max(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor < len) {
                    s.cursor = nextCharStart(buf.items, s.cursor);
                    if (!extend) s.sel_anchor = s.cursor;
                }
            },
            .home => {
                s.cursor = 0;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .end => {
                s.cursor = len;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .a => if (super_ctrl_held) {
                s.sel_anchor = 0;
                s.cursor = len;
            },
            else => {},
        }
    }
}

fn deleteSelection(buf: *std.ArrayList(u8), len: *u32, s: *State.TextInput) void {
    const lo = @min(s.cursor, s.sel_anchor);
    const hi = @max(s.cursor, s.sel_anchor);
    const n = hi - lo;
    std.debug.assert(buf.capacity >= buf.items.len);
    buf.replaceRangeAssumeCapacity(lo, n, &.{});
    len.* -= n;
    s.cursor = lo;
    s.sel_anchor = lo;
}

fn prevCharStart(buf: []const u8, pos: u32) u32 {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (buf[i] & 0xC0 != 0x80) return i;
    }
    return 0;
}

fn nextCharStart(buf: []const u8, pos: u32) u32 {
    var i = pos + 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] & 0xC0 != 0x80) return i;
    }
    return @intCast(buf.len);
}
