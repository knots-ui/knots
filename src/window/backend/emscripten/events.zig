const std = @import("std");
const window = @import("window");
const root = @import("root.zig");
const keymap = @import("keymap.zig");

fn ownerOf(user_data: ?*anyopaque) ?*window.Window {
    return @ptrCast(@alignCast(user_data orelse return null));
}

fn modsOf(ev: *const root.EmscriptenKeyboardEvent) window.Mods {
    return .{ .shift = ev.shiftKey, .ctrl = ev.ctrlKey, .alt = ev.altKey, .super = ev.metaKey };
}

fn decodePrintableChar(buf: []const u8) ?u21 {
    const slice = std.mem.sliceTo(buf, 0);
    if (slice.len == 0 or slice.len > 4) return null;
    const len = std.unicode.utf8ByteSequenceLength(slice[0]) catch return null;
    if (len != slice.len) return null;
    const cp = std.unicode.utf8Decode(slice[0..len]) catch return null;
    if (cp < 0x20 or cp == 0x7F) return null;
    return @intCast(cp);
}

pub fn onKeyDown(_: c_int, ev: *const root.EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const mods = modsOf(ev);
    const action: window.KeyAction = if (ev.repeat) .repeat else .press;
    if (keymap.translateCode(&ev.code)) |key| {
        if (((mods.ctrl and !mods.alt) or mods.super) and key == .v) {
            owner.backend.preparePaste();
            return false;
        }
        owner.pushKey(@intFromEnum(key), action, mods);
    }
    if ((!mods.ctrl or mods.alt) and !mods.super) {
        if (decodePrintableChar(&ev.key)) |cp| owner.pushChar(cp);
    }
    return true;
}

pub fn onKeyUp(_: c_int, ev: *const root.EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const mods = modsOf(ev);
    if (keymap.translateCode(&ev.code)) |key| owner.pushKey(@intFromEnum(key), .release, mods);
    return true;
}

pub fn onMouseDown(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const pos = mousePos(ev);
    switch (ev.button) {
        0 => owner.setMouseButton(.left, true, pos),
        1 => owner.setMouseButton(.middle, true, pos),
        2 => owner.setMouseButton(.right, true, pos),
        3 => owner.setMouseButton(.back, true, pos),
        4 => owner.setMouseButton(.forward, true, pos),
        else => return false,
    }
    return true;
}

pub fn onMouseUp(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const pos = mousePos(ev);
    switch (ev.button) {
        0 => owner.setMouseButton(.left, false, pos),
        1 => owner.setMouseButton(.middle, false, pos),
        2 => owner.setMouseButton(.right, false, pos),
        3 => owner.setMouseButton(.back, false, pos),
        4 => owner.setMouseButton(.forward, false, pos),
        else => return false,
    }
    return true;
}

pub fn onMouseMove(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    owner.setCursorPos(mousePos(ev));
    return true;
}

pub fn onWheel(_: c_int, ev: *const root.EmscriptenWheelEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    owner.setCursorPos(mousePos(&ev.*.mouse));
    switch (ev.deltaMode) {
        0 => owner.addScrollPixels(ev.deltaX, ev.deltaY), // DOM_DELTA_PIXEL
        1 => owner.addScrollLines(ev.deltaX, ev.deltaY), // DOM_DELTA_LINE
        2 => owner.addScrollPages(ev.deltaX, ev.deltaY), // DOM_DELTA_PAGE
        else => owner.addScrollPixels(ev.deltaX, ev.deltaY),
    }
    return true;
}

pub fn onResize(_: c_int, _: *const root.EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const owner = ownerOf(user_data) orelse return 0;
    owner.backend.refreshCanvas();
    owner.markResized();
    owner.requestFrame();
    return 1;
}

pub fn onBlur(_: c_int, _: *const root.EmscriptenFocusEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    owner.setFocused(false);
    return true;
}

pub fn onFocus(_: c_int, _: *const root.EmscriptenFocusEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    owner.setFocused(true);
    return true;
}

fn mousePos(ev: *const root.EmscriptenMouseEvent) [2]f64 {
    return .{ @floatFromInt(ev.targetX), @floatFromInt(ev.targetY) };
}
