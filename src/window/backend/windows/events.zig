const input_types = @import("input");
const std = @import("std");
const win32 = @import("win32").everything;
const window = @import("window");

const keymap = @import("keymap.zig");

const Backend = @import("root.zig").Backend;

fn keyDown(vk: anytype) bool {
    return win32.GetKeyState(@backingInt(vk)) < 0;
}

pub fn modsFromKeyState() input_types.Mods {
    return .{
        .shift = keyDown(win32.VK_SHIFT),
        .ctrl = keyDown(win32.VK_CONTROL),
        .alt = keyDown(win32.VK_MENU),
        .super = keyDown(win32.VK_LWIN) or keyDown(win32.VK_RWIN),
    };
}

pub fn onKey(owner: *window.Window, wparam: win32.WPARAM, lparam: win32.LPARAM, pressed: bool) void {
    const vk: u32 = @intCast(wparam);
    const key = keymap.translateVk(vk, lparam);
    const lp: u64 = @bitCast(@as(i64, lparam));
    const repeat_bit: u1 = @intCast((lp >> 30) & 1);
    const action: input_types.KeyAction =
        if (!pressed)
            .release
        else if (repeat_bit == 1)
            .repeat
        else
            .press;

    const typed = if (pressed) typedChar(vk, @intCast((lp >> 16) & 0xFF)) orelse 0 else 0;
    owner.pushKeyText(@backingInt(key), action, modsFromKeyState(), typed);
}

fn typedChar(vk: u32, scancode: u32) ?u21 {
    var state: [256]u8 = undefined;
    if (win32.GetKeyboardState(&state) == 0)
        return null;

    const altgr = state[@backingInt(win32.VK_RMENU)] & 0x80 != 0;
    if (!altgr) {
        for ([_]u32{ @backingInt(win32.VK_CONTROL), @backingInt(win32.VK_LCONTROL), @backingInt(win32.VK_RCONTROL), @backingInt(win32.VK_MENU), @backingInt(win32.VK_LMENU) }) |k| {
            state[k] = 0;
        }
    }

    var buf: [4:0]u16 = @splat(0);
    if (win32.ToUnicode(vk, scancode, &state, &buf, 4, 0x4) != 1)
        return null;

    const w = buf[0];
    if (w < 0x20 or w == 0x7F or (w >= 0xD800 and w <= 0xDFFF))
        return null;

    return w;
}

pub fn onChar(owner: *window.Window, high_surrogate: *u16, w: u16) void {
    if (w < 0x20 or w == 0x7F) return;

    var cp: u21 = undefined;
    if (w >= 0xD800 and w <= 0xDBFF) {
        high_surrogate.* = w;
        return;
    } else if (w >= 0xDC00 and w <= 0xDFFF) {
        if (high_surrogate.* == 0) return;
        const hi: u21 = high_surrogate.*;
        const lo: u21 = w;
        cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
        high_surrogate.* = 0;
    } else {
        high_surrogate.* = 0;
        cp = @intCast(w);
    }

    const ctrl = keyDown(win32.VK_CONTROL);
    const alt = keyDown(win32.VK_MENU);
    if ((ctrl and !alt) or keyDown(win32.VK_LWIN) or keyDown(win32.VK_RWIN)) return;
    owner.pushChar(cp);
}

pub fn onDropFiles(self: *Backend, owner: *window.Window, hdrop: win32.HDROP) void {
    const count = win32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    const n: usize = @min(@as(usize, @intCast(count)), self.drop_paths_buf.len);
    var w_buf: [260]u16 = undefined;
    for (0..n) |i| {
        const len = win32.DragQueryFileW(hdrop, @intCast(i), @ptrCast(&w_buf), @intCast(w_buf.len));
        if (len == 0) {
            self.drop_slices[i] = self.drop_paths_buf[i][0..0];
            continue;
        }
        const out = std.unicode.utf16LeToUtf8(&self.drop_paths_buf[i], w_buf[0..len]) catch {
            self.drop_slices[i] = self.drop_paths_buf[i][0..0];
            continue;
        };
        self.drop_slices[i] = self.drop_paths_buf[i][0..out];
    }
    win32.DragFinish(hdrop);
    owner.markDropped(n);
}
