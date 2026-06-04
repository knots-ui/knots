const std = @import("std");
const builtin = @import("builtin");

const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const glyph = @import("text").glyph;
const util = @import("util.zig");

pub fn processInputEarly(buf: *std.ArrayList(u8), app: *App, s: *State.TextInput, multiline: bool) !void {
    const ui = &app.ui;
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
        .emscripten => ui.input.ctrl_held or ui.input.super_held,
        else => ui.input.ctrl_held,
    };

    for (ui.input.keys) |key| {
        switch (key) {
            .c => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi) _ = app.window.setClipboardText(app.allocator, buf.items[sel.lo..sel.hi]) catch false;
            },
            .x => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi and (app.window.setClipboardText(app.allocator, buf.items[sel.lo..sel.hi]) catch false)) {
                    deleteSelection(buf, &len, s);
                }
            },
            .v => if (super_ctrl_held) {
                const raw = (app.window.getClipboardText(app.allocator) catch null) orelse continue;
                defer app.allocator.free(raw);
                _ = std.unicode.Utf8View.init(raw) catch continue;

                var paste_len: usize = 0;
                if (multiline) {
                    var i: usize = 0;
                    while (i < raw.len) {
                        if (raw[i] == '\r') {
                            raw[paste_len] = '\n';
                            paste_len += 1;
                            i += 1;
                            if (i < raw.len and raw[i] == '\n') i += 1;
                        } else {
                            raw[paste_len] = raw[i];
                            paste_len += 1;
                            i += 1;
                        }
                    }
                } else {
                    paste_len = raw.len;
                    for (raw) |*ch| {
                        if (ch.* == '\r' or ch.* == '\n') ch.* = ' ';
                    }
                }
                if (paste_len == 0) continue;

                const sel = selectionRange(s);
                const selected_len: usize = @intCast(sel.hi - sel.lo);
                const base_len = buf.items.len - selected_len;
                if (paste_len > std.math.maxInt(u32) or base_len + paste_len > std.math.maxInt(u32)) continue;
                try buf.ensureTotalCapacity(ui.allocator, base_len + paste_len);
                if (selected_len > 0) deleteSelection(buf, &len, s);
                try buf.insertSlice(ui.allocator, s.cursor, raw[0..paste_len]);
                len += @intCast(paste_len);
                s.cursor += @intCast(paste_len);
                s.sel_anchor = s.cursor;
            },
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
            .a => if (super_ctrl_held) {
                s.sel_anchor = 0;
                s.cursor = len;
            },
            else => {},
        }
    }
}

pub fn processInputLate(buf: *std.ArrayList(u8), wrap: bool, ui: *UI, s: *State.TextInput, shaped: glyph.ShapedWrappedView, line_h: f32) !void {
    var len: u32 = @intCast(buf.items.len);
    const scale = ui.content_scale;

    for (ui.input.keys) |key| {
        switch (key) {
            .enter => if (wrap) {
                if (s.sel_anchor != s.cursor) deleteSelection(buf, &len, s);
                buf.insertSlice(ui.allocator, s.cursor, "\n") catch return;
                len += 1;
                s.cursor += 1;
                s.sel_anchor = s.cursor;
                return;
            },
            .up, .down => if (wrap) {
                const cur_pos = util.posAtByte(shaped, s.cursor, scale);
                const target_y = if (key == .up) cur_pos.y - line_h * 0.5 else cur_pos.y + line_h * 1.5;
                const target: util.Pos = .{ .x = cur_pos.x, .y = target_y };
                const new_cursor = util.byteAtPos(shaped, target, scale);
                s.cursor = @min(new_cursor, len);
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .home => {
                const new_cursor: u32 = if (wrap)
                    lineBounds(shaped, s.cursor).start
                else
                    0;
                s.cursor = new_cursor;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .end => {
                const new_cursor: u32 = if (wrap)
                    lineBounds(shaped, s.cursor).end
                else
                    len;
                s.cursor = new_cursor;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            else => {},
        }
    }
}

fn lineBounds(view: glyph.ShapedWrappedView, byte: u32) struct { start: u32, end: u32 } {
    if (view.lines.len == 0) return .{ .start = 0, .end = 0 };
    for (view.lines) |line| {
        if (byte <= line.byte_end) return .{ .start = line.byte_start, .end = line.byte_end };
    }
    const last = view.lines[view.lines.len - 1];
    return .{ .start = last.byte_start, .end = last.byte_end };
}

fn deleteSelection(buf: *std.ArrayList(u8), len: *u32, s: *State.TextInput) void {
    const sel = selectionRange(s);
    const lo = sel.lo;
    const hi = sel.hi;
    const n = hi - lo;
    std.debug.assert(buf.capacity >= buf.items.len);
    buf.replaceRangeAssumeCapacity(lo, n, &.{});
    len.* -= n;
    s.cursor = lo;
    s.sel_anchor = lo;
}

fn selectionRange(s: *const State.TextInput) struct { lo: u32, hi: u32 } {
    return .{
        .lo = @min(s.cursor, s.sel_anchor),
        .hi = @max(s.cursor, s.sel_anchor),
    };
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
