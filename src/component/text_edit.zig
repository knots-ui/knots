const std = @import("std");
const builtin = @import("builtin");

const App = @import("knots").App;
const platform = @import("knots").platform;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Element = @import("layout").Element;
const glyph = @import("text").glyph;
const util = @import("util.zig");

const DOUBLE_CLICK_MS: i64 = 400;

pub fn processInputEarly(buf: *std.ArrayList(u8), app: *App, s: *State.TextInput, multiline: bool) !void {
    const ui = &app.viewport.ui;
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

    for (ui.input.key_events) |event| {
        if (event.action == .release) continue;
        const key = event.key;
        const super_ctrl_held = if (builtin.os.tag == .macos)
            event.mods.super
        else if (platform.is_browser_wasm)
            (event.mods.ctrl and !event.mods.alt) or event.mods.super
        else
            event.mods.ctrl and !event.mods.alt;
        switch (key) {
            .c => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi) _ = app.viewport.window.setClipboardText(app.allocator, buf.items[sel.lo..sel.hi]) catch false;
            },
            .x => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi and (app.viewport.window.setClipboardText(app.allocator, buf.items[sel.lo..sel.hi]) catch false)) {
                    deleteSelection(buf, &len, s);
                }
            },
            .v => if (super_ctrl_held) {
                const raw = (app.viewport.window.getClipboardText(app.allocator) catch null) orelse continue;
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
                const extend = event.mods.shift;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @min(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor > 0) {
                    s.cursor = if (event.mods.alt)
                        wordBoundary(buf.items, s.cursor, true)
                    else
                        prevCharStart(buf.items, s.cursor);
                    if (!extend) s.sel_anchor = s.cursor;
                }
            },
            .right => {
                const extend = event.mods.shift;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @max(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor < len) {
                    s.cursor = if (event.mods.alt)
                        wordBoundary(buf.items, s.cursor, false)
                    else
                        nextCharStart(buf.items, s.cursor);
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

    for (ui.input.key_events) |event| {
        if (event.action == .release) continue;
        const key = event.key;
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
                if (!event.mods.shift) s.sel_anchor = s.cursor;
            },
            .home => {
                const new_cursor: u32 = if (wrap)
                    lineBounds(shaped, s.cursor).start
                else
                    0;
                s.cursor = new_cursor;
                if (!event.mods.shift) s.sel_anchor = s.cursor;
            },
            .end => {
                const new_cursor: u32 = if (wrap)
                    lineBounds(shaped, s.cursor).end
                else
                    len;
                s.cursor = new_cursor;
                if (!event.mods.shift) s.sel_anchor = s.cursor;
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

pub fn selectionRange(s: *const State.TextInput) struct { lo: u32, hi: u32 } {
    return .{
        .lo = @min(s.cursor, s.sel_anchor),
        .hi = @max(s.cursor, s.sel_anchor),
    };
}

pub fn processMouse(
    ui: *UI,
    id: Element.Id,
    buf: []const u8,
    s: *State.TextInput,
    shaped: glyph.ShapedWrappedView,
    content_origin: [2]f32,
    scroll_offset: [2]f32,
    scale: f32,
) void {
    if (ui.input.mouseButton(.left).pressed and ui.hovering(id)) {
        const byte = byteAtMouse(ui, shaped, content_origin, scroll_offset, scale, @intCast(buf.len));
        const double_click = if (s.last_click_ms) |last|
            ui.input.now_ms - last <= DOUBLE_CLICK_MS and s.last_click_byte == byte
        else
            false;

        if (double_click) {
            selectWordAtByte(buf, s, byte);
        } else {
            moveCursorToByte(buf, s, byte, ui.input.shift_held);
        }
        s.dragging = true;
        s.last_click_ms = ui.input.now_ms;
        s.last_click_byte = byte;
    }

    if (s.dragging and ui.input.mouseButton(.left).down) {
        const byte = byteAtMouse(ui, shaped, content_origin, scroll_offset, scale, @intCast(buf.len));
        moveCursorToByte(buf, s, byte, true);
    }

    if (!ui.input.mouseButton(.left).down) s.dragging = false;
}

pub fn moveCursorToByte(buf: []const u8, s: *State.TextInput, byte: u32, extend: bool) void {
    const b = clampByte(buf, byte);
    s.cursor = b;
    if (!extend) s.sel_anchor = b;
}

pub fn selectWordAtByte(buf: []const u8, s: *State.TextInput, byte: u32) void {
    if (buf.len == 0) {
        s.cursor = 0;
        s.sel_anchor = 0;
        return;
    }

    const len: u32 = @intCast(buf.len);
    var pos = clampByte(buf, byte);
    if (pos == len and pos > 0) pos = prevCharStart(buf, pos);
    if (!isWordStart(buf, pos)) {
        s.cursor = pos;
        s.sel_anchor = pos;
        return;
    }

    var start = pos;
    while (start > 0) {
        const prev = prevCharStart(buf, start);
        if (!isWordStart(buf, prev)) break;
        start = prev;
    }

    var end = nextCharStart(buf, pos);
    while (end < len and isWordStart(buf, end)) end = nextCharStart(buf, end);

    s.sel_anchor = start;
    s.cursor = end;
}

fn byteAtMouse(
    ui: *UI,
    shaped: glyph.ShapedWrappedView,
    content_origin: [2]f32,
    scroll_offset: [2]f32,
    scale: f32,
    len: u32,
) u32 {
    const local: util.Pos = .{
        .x = @as(f32, @floatCast(ui.input.mouse_pos[0])) - content_origin[0] + scroll_offset[0],
        .y = @as(f32, @floatCast(ui.input.mouse_pos[1])) - content_origin[1] + scroll_offset[1],
    };
    return @min(util.byteAtPos(shaped, local, scale), len);
}

fn clampByte(buf: []const u8, byte: u32) u32 {
    const len: u32 = @intCast(buf.len);
    var i: u32 = @min(byte, len);
    while (i > 0 and i < len and (buf[@intCast(i)] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn isWordStart(buf: []const u8, pos: u32) bool {
    if (pos >= @as(u32, @intCast(buf.len))) return false;
    const b = buf[@intCast(pos)];
    return b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

fn wordBoundary(buf: []const u8, pos: u32, backward: bool) u32 {
    const len: u32 = @intCast(buf.len);
    var i = pos;
    var in_word = false;
    while ((backward and i > 0) or (!backward and i < len)) {
        const char = if (backward) prevCharStart(buf, i) else i;
        const word = isWordStart(buf, char);
        if (in_word and !word) break;
        in_word = in_word or word;
        i = if (backward) char else nextCharStart(buf, i);
    }
    return i;
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
