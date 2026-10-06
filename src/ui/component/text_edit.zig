const std = @import("std");

const Frame = @import("../root.zig").Frame;
const input_types = @import("input");
const UI = @import("../root.zig").UI;
const State = @import("../root.zig").State;
const Element = @import("layout").Element;
const glyph = @import("text").glyph;
const Face = @import("text").Face;
const util = @import("util.zig");

const DOUBLE_CLICK_MS: i64 = 400;

pub fn processAccessibility(buf: *std.ArrayList(u8), frame: *Frame, state: *State.TextInput, id: Element.Id, bytes_max: u32) !void {
    const ui = frame.ui();
    if (ui.consumeAccessibilityAction(id, .set_value)) |request| {
        if (request.value_text) |value| {
            if (value.len <= bytes_max) {
                try buf.replaceRange(ui.allocator, 0, buf.items.len, value);
                state.cursor = @intCast(value.len);
                state.sel_anchor = state.cursor;
            }
        }
    }
    if (ui.consumeAccessibilityAction(id, .set_text_selection)) |request| {
        if (request.selection_anchor) |anchor| {
            if (request.selection_focus) |focus| {
                state.sel_anchor = characterToByte(buf.items, anchor);
                state.cursor = characterToByte(buf.items, focus);
            }
        }
    }
    if (ui.consumeAccessibilityAction(id, .replace_selected_text)) |request| {
        if (request.value_text) |value| {
            const selection = selectionRange(state);
            const final_len = buf.items.len - (selection.hi - selection.lo) + value.len;
            if (final_len <= bytes_max) {
                try buf.replaceRange(ui.allocator, selection.lo, selection.hi - selection.lo, value);
                state.cursor = selection.lo + @as(u32, @intCast(value.len));
                state.sel_anchor = state.cursor;
            }
        }
    }
}

pub fn byteToCharacter(bytes: []const u8, byte: u32) u32 {
    var offset: u32 = 0;
    var characters: u32 = 0;
    while (offset < @min(byte, bytes.len)) {
        const width: u32 = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch break;
        if (offset + width > bytes.len) break;
        offset += width;
        characters += 1;
    }
    return characters;
}

fn characterToByte(bytes: []const u8, character: u32) u32 {
    var offset: u32 = 0;
    var index: u32 = 0;
    while (offset < bytes.len and index < character) {
        const width: u32 = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch break;
        if (offset + width > bytes.len) break;
        offset += width;
        index += 1;
    }
    return offset;
}

pub fn validateByteLimit(bytes_max: u32) !void {
    if (bytes_max > Face.text_bytes_max) return error.TextLimitTooLarge;
}

fn insertPaste(buf: *std.ArrayList(u8), len: *u32, frame: *Frame, s: *State.TextInput, paste_text: []const u8, multiline: bool, bytes_max: u32) !void {
    const ui = frame.ui();
    const raw = try frame.arena().dupe(u8, paste_text);
    _ = std.unicode.Utf8View.init(raw) catch return;

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
    if (paste_len == 0) return;

    const sel = selectionRange(s);
    const selected_len: usize = @intCast(sel.hi - sel.lo);
    const base_len = buf.items.len - selected_len;
    const max_len: usize = @intCast(bytes_max);
    if (base_len > max_len or paste_len > max_len - base_len) return;
    try buf.ensureTotalCapacity(ui.allocator, base_len + paste_len);
    if (selected_len > 0) deleteSelection(buf, len, s);
    try buf.insertSlice(ui.allocator, s.cursor, raw[0..paste_len]);
    len.* += @intCast(paste_len);
    s.cursor += @intCast(paste_len);
    s.sel_anchor = s.cursor;
}

pub fn processInputEarly(buf: *std.ArrayList(u8), frame: *Frame, s: *State.TextInput, multiline: bool, bytes_max: u32) !void {
    std.debug.assert(bytes_max <= Face.text_bytes_max);
    const ui = frame.ui();
    var len: u32 = @intCast(buf.items.len);
    s.cursor = @min(s.cursor, len);
    s.sel_anchor = @min(s.sel_anchor, len);

    for (ui.input.chars) |ch| {
        if (ch == 0) break;
        var encoded: [4]u8 = undefined;
        const n: u32 = @intCast(std.unicode.utf8Encode(ch, &encoded) catch continue);

        const selection = selectionRange(s);
        const base_len = len - (selection.hi - selection.lo);
        if (base_len > bytes_max or n > bytes_max - base_len) continue;
        if (s.sel_anchor != s.cursor) deleteSelection(buf, &len, s);

        buf.insertSlice(ui.allocator, s.cursor, encoded[0..n]) catch continue;
        len += n;
        s.cursor += n;
        s.sel_anchor = s.cursor;
    }

    if (frame.pasteText()) |paste_text| {
        try insertPaste(buf, &len, frame, s, paste_text, multiline, bytes_max);
    }

    for (ui.input.key_events) |event| {
        if (event.action == .release) continue;
        const key = event.key;
        const super_ctrl_held = input_types.clipboardModifierHeld(event.mods);
        switch (key) {
            .c => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi) {
                    try frame.writeClipboard(buf.items[sel.lo..sel.hi]);
                }
            },
            .x => if (super_ctrl_held) {
                const sel = selectionRange(s);
                if (sel.lo != sel.hi) {
                    try frame.writeClipboard(buf.items[sel.lo..sel.hi]);
                    deleteSelection(buf, &len, s);
                }
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

pub fn processInputLate(
    buf: *std.ArrayList(u8),
    wrap: bool,
    ui: *UI,
    s: *State.TextInput,
    shaped: glyph.ShapedWrappedView,
    line_h: f32,
    bytes_max: u32,
) !void {
    std.debug.assert(bytes_max <= Face.text_bytes_max);
    var len: u32 = @intCast(buf.items.len);
    const scale = ui.content_scale;

    for (ui.input.key_events) |event| {
        if (event.action == .release) continue;
        const key = event.key;
        switch (key) {
            .enter => if (wrap) {
                const selection = selectionRange(s);
                const base_len = len - (selection.hi - selection.lo);
                if (base_len >= bytes_max) return;
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

test "text byte limit accepts one MiB and rejects one byte more" {
    try validateByteLimit(Face.text_bytes_max);
    try std.testing.expectError(
        error.TextLimitTooLarge,
        validateByteLimit(Face.text_bytes_max + 1),
    );
}

test "selection deletion remains available above a smaller caller limit" {
    const caller_bytes_max: u32 = 3;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "abcde");
    try std.testing.expect(buf.items.len > caller_bytes_max);

    var len: u32 = @intCast(buf.items.len);
    var state: State.TextInput = .{ .sel_anchor = 3, .cursor = 5 };
    deleteSelection(&buf, &len, &state);

    try std.testing.expectEqualStrings("abc", buf.items);
    try std.testing.expectEqual(caller_bytes_max, len);
    try std.testing.expectEqual(caller_bytes_max, state.cursor);
    try std.testing.expectEqual(caller_bytes_max, state.sel_anchor);
}
