const std = @import("std");
const window = @import("window");

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_moved: bool = false,
mouse_idle_ms: i64 = 0,
now_ms: i64 = 0,
mouse_down: bool = false,
mouse_pressed: bool = false,
mouse_released: bool = false,
mouse_r_down: bool = false,
mouse_r_pressed: bool = false,
mouse_r_released: bool = false,
scroll: window.ScrollInput = .{},
scroll_delta: [2]f32 = .{ 0, 0 },
chars: []const u21 = &.{},
keys: []const window.Key = &.{},
shift_held: bool = false,
ctrl_held: bool = false,
super_held: bool = false,

_char_buf: [32]u21 = undefined,
_char_len: usize = 0,
_key_buf: [32]window.Key = undefined,
_key_len: usize = 0,
_prev_mouse_down: bool = false,
_prev_mouse_r_down: bool = false,
_prev_mouse_pos: [2]f64 = .{ 0, 0 },
_last_move_ms: i64 = 0,

const Input = @This();

pub fn collect(self: *Input, raw: window.Input, now_ms: i64) void {
    self.mouse_pos = raw.pos;
    self.mouse_moved = raw.pos[0] != self._prev_mouse_pos[0] or raw.pos[1] != self._prev_mouse_pos[1];
    self._prev_mouse_pos = raw.pos;
    self.mouse_pressed = raw.mouse_down_now and !self._prev_mouse_down;
    self.mouse_released = !raw.mouse_down_now and self._prev_mouse_down;
    self.mouse_down = raw.mouse_down_now;
    self._prev_mouse_down = raw.mouse_down_now;
    self.mouse_r_pressed = raw.mouse_r_down_now and !self._prev_mouse_r_down;
    self.mouse_r_released = !raw.mouse_r_down_now and self._prev_mouse_r_down;
    self.mouse_r_down = raw.mouse_r_down_now;
    self._prev_mouse_r_down = raw.mouse_r_down_now;
    if (self.mouse_moved) self._last_move_ms = now_ms;
    self.mouse_idle_ms = now_ms - self._last_move_ms;
    self.now_ms = now_ms;
    self.scroll = raw.scroll;
    self.scroll_delta = .{ 0, 0 };
    self.shift_held = raw.shift_held;
    self.ctrl_held = raw.ctrl_held;
    self.super_held = raw.super_held;

    const nc = @min(raw.chars.len, self._char_buf.len);
    @memcpy(self._char_buf[0..nc], raw.chars[0..nc]);
    self._char_len = nc;
    self.chars = self._char_buf[0..nc];

    const nk = @min(raw.keys.len, self._key_buf.len);
    @memcpy(self._key_buf[0..nk], raw.keys[0..nk]);
    self._key_len = nk;
    self.keys = self._key_buf[0..nk];
}

pub fn consumeKeyboard(self: *Input) void {
    self.chars = self._char_buf[0..0];
    self.keys = self._key_buf[0..0];
}

pub fn containsKey(self: *const Input, key: window.Key) bool {
    for (self.keys) |k| if (k == key) return true;
    return false;
}
