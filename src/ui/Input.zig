const window = @import("window");
const mouse_button_count = window.mouse_button_count;

mouse_pos: [2]f64 = .{ 0, 0 },
mouse_moved: bool = false,
mouse_idle_ms: i64 = 0,
now_ms: i64 = 0,
focused: bool = true,
focus_lost: bool = false,
pointer_cancelled: bool = false,
mouse: [mouse_button_count]window.MouseButtonState = @splat(.{}),
scroll: window.ScrollInput = .{},
scroll_delta: [2]f32 = .{ 0, 0 },
chars: []const u21 = &.{},
key_events: []const window.KeyEvent = &.{},
key_down: *const [window.key_count]bool = &window.no_keys_down,
shift_held: bool = false,
ctrl_held: bool = false,
alt_held: bool = false,
super_held: bool = false,

_prev_mouse_down: [mouse_button_count]bool = @splat(false),
_prev_mouse_pos: [2]f64 = .{ 0, 0 },
_last_move_ms: i64 = 0,
const Input = @This();

pub fn collect(self: *Input, raw: window.Input, now_ms: i64) void {
    self.focus_lost = self.focused and !raw.focused;
    self.focused = raw.focused;
    self.mouse_pos = raw.pos;
    self.mouse_moved = raw.pos[0] != self._prev_mouse_pos[0] or raw.pos[1] != self._prev_mouse_pos[1];
    self._prev_mouse_pos = raw.pos;

    self.pointer_cancelled = false;
    for (raw.mouse, 0..) |button, i| {
        const cancelled = !button.down and self._prev_mouse_down[i] and !button.released;
        const sampled_pressed = button.down and !self._prev_mouse_down[i];
        const sampled_released = !cancelled and !button.down and self._prev_mouse_down[i];
        self.pointer_cancelled = self.pointer_cancelled or cancelled;
        self.mouse[i] = button;
        self.mouse[i].pressed = button.pressed or sampled_pressed;
        self.mouse[i].released = button.released or sampled_released;
        if (sampled_pressed and !button.pressed) self.mouse[i].pressed_pos = raw.pos;
        if (sampled_released and !button.released) self.mouse[i].released_pos = raw.pos;
        self._prev_mouse_down[i] = button.down;
    }

    if (self.mouse_moved) self._last_move_ms = now_ms;
    self.mouse_idle_ms = now_ms - self._last_move_ms;
    self.now_ms = now_ms;
    self.scroll = raw.scroll;
    self.scroll_delta = .{ 0, 0 };
    self.shift_held = raw.shift_held;
    self.ctrl_held = raw.ctrl_held;
    self.alt_held = raw.alt_held;
    self.super_held = raw.super_held;

    self.chars = raw.chars;
    self.key_events = raw.key_events;
    self.key_down = raw.key_down;
}

pub fn consumeKeyboard(self: *Input) void {
    self.chars = &.{};
    self.key_events = &.{};
}

pub fn containsKey(self: *const Input, key: window.Key) bool {
    return self.keyPressed(key) or self.keyRepeated(key);
}

pub inline fn mouseButton(self: *const Input, button: window.MouseButton) *const window.MouseButtonState {
    return &self.mouse[@intFromEnum(button)];
}

pub fn keyPressed(self: *const Input, key: window.Key) bool {
    for (self.key_events) |event| if (event.key == key and event.action == .press) return true;
    return false;
}

pub fn keyRepeated(self: *const Input, key: window.Key) bool {
    for (self.key_events) |event| if (event.key == key and event.action == .repeat) return true;
    return false;
}

pub fn keyReleased(self: *const Input, key: window.Key) bool {
    for (self.key_events) |event| if (event.key == key and event.action == .release) return true;
    return false;
}

pub fn keyDown(self: *const Input, key: window.Key) bool {
    const value = @intFromEnum(key);
    return value >= 0 and value < window.key_count and self.key_down[@intCast(value)];
}
