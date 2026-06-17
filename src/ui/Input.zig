const window = @import("window");

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_moved: bool = false,
mouse_idle_ms: i64 = 0,
now_ms: i64 = 0,
mouse_left_down: bool = false,
mouse_left_pressed: bool = false,
mouse_left_released: bool = false,
mouse_left_pressed_pos: ?[2]f64 = null,
mouse_left_released_pos: ?[2]f64 = null,
mouse_right_down: bool = false,
mouse_right_pressed: bool = false,
mouse_right_released: bool = false,
mouse_right_pressed_pos: ?[2]f64 = null,
mouse_right_released_pos: ?[2]f64 = null,
scroll: window.ScrollInput = .{},
scroll_delta: [2]f32 = .{ 0, 0 },
chars: []const u21 = &.{},
keys: []const window.Key = &.{},
shift_held: bool = false,
ctrl_held: bool = false,
super_held: bool = false,

_prev_mouse_left_down: bool = false,
_prev_mouse_right_down: bool = false,
_prev_mouse_pos: [2]f64 = .{ 0, 0 },
_last_move_ms: i64 = 0,
const Input = @This();

pub fn collect(self: *Input, raw: window.Input, now_ms: i64) void {
    self.mouse_pos = raw.pos;
    self.mouse_moved = raw.pos[0] != self._prev_mouse_pos[0] or raw.pos[1] != self._prev_mouse_pos[1];
    self._prev_mouse_pos = raw.pos;

    const sampled_left_pressed = raw.mouse_left_down_now and !self._prev_mouse_left_down;
    const sampled_left_released = !raw.mouse_left_down_now and self._prev_mouse_left_down;
    self.mouse_left_pressed = raw.mouse_left_pressed or sampled_left_pressed;
    self.mouse_left_released = raw.mouse_left_released or sampled_left_released;
    self.mouse_left_pressed_pos = if (raw.mouse_left_pressed)
        raw.mouse_left_pressed_pos orelse raw.pos
    else if (sampled_left_pressed)
        raw.pos
    else
        null;
    self.mouse_left_released_pos = if (raw.mouse_left_released)
        raw.mouse_left_released_pos orelse raw.pos
    else if (sampled_left_released)
        raw.pos
    else
        null;
    self.mouse_left_down = raw.mouse_left_down_now;
    self._prev_mouse_left_down = raw.mouse_left_down_now;

    const sampled_right_pressed = raw.mouse_right_down_now and !self._prev_mouse_right_down;
    const sampled_right_released = !raw.mouse_right_down_now and self._prev_mouse_right_down;
    self.mouse_right_pressed = raw.mouse_right_pressed or sampled_right_pressed;
    self.mouse_right_released = raw.mouse_right_released or sampled_right_released;
    self.mouse_right_pressed_pos = if (raw.mouse_right_pressed)
        raw.mouse_right_pressed_pos orelse raw.pos
    else if (sampled_right_pressed)
        raw.pos
    else
        null;
    self.mouse_right_released_pos = if (raw.mouse_right_released)
        raw.mouse_right_released_pos orelse raw.pos
    else if (sampled_right_released)
        raw.pos
    else
        null;
    self.mouse_right_down = raw.mouse_right_down_now;
    self._prev_mouse_right_down = raw.mouse_right_down_now;
    if (self.mouse_moved) self._last_move_ms = now_ms;
    self.mouse_idle_ms = now_ms - self._last_move_ms;
    self.now_ms = now_ms;
    self.scroll = raw.scroll;
    self.scroll_delta = .{ 0, 0 };
    self.shift_held = raw.shift_held;
    self.ctrl_held = raw.ctrl_held;
    self.super_held = raw.super_held;

    self.chars = raw.chars;
    self.keys = raw.keys;
}

pub fn consumeKeyboard(self: *Input) void {
    self.chars = &.{};
    self.keys = &.{};
}

pub fn containsKey(self: *const Input, key: window.Key) bool {
    for (self.keys) |k| if (k == key) return true;
    return false;
}
