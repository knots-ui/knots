const std = @import("std");
const gpu = @import("gpu");
const impl = @import("window_impl");

const Key = @import("root.zig").Key;
const Config = @import("root.zig").Config;
const Input = @import("root.zig").Input;
const ScrollInput = @import("root.zig").ScrollInput;
const KeyAction = @import("root.zig").KeyAction;
const Mods = @import("root.zig").Mods;
const KeyEvent = @import("root.zig").KeyEvent;
const Size = @import("root.zig").Size;
const ResizeEvent = @import("root.zig").ResizeEvent;
const DisplayMode = @import("root.zig").DisplayMode;
const FrameHandler = @import("root.zig").FrameHandler;

backend: impl.Backend,
allocator: std.mem.Allocator,
should_close: bool = false,
mouse: Mouse = .{},
scroll: ScrollInput = .{},
char_buf: std.ArrayList(u21) = .empty,
key_events: std.ArrayList(KeyEvent) = .empty,
key_buf: std.ArrayList(Key) = .empty,
input_error: ?std.mem.Allocator.Error = null,
resized: bool = false,
pending_drop_count: u8 = 0,
canvas_selector: ?[:0]const u8,
content_scale: f32 = 1.0,
display_mode: DisplayMode = .windowed,
frame_handler: ?FrameHandler = null,
input_dirty: bool = false,

const Window = @This();

pub const MouseButton = enum(u1) {
    left = 0,
    right = 1,
};

const Mouse = struct {
    pos: [2]f64 = .{ 0, 0 },
    down: u8 = 0,
    pressed: u8 = 0,
    released: u8 = 0,
    pressed_pos: [2]?[2]f64 = .{ null, null },
    released_pos: [2]?[2]f64 = .{ null, null },

    fn bit(button: MouseButton) u8 {
        return @as(u8, 1) << @intFromEnum(button);
    }

    fn index(button: MouseButton) usize {
        return @intFromEnum(button);
    }

    fn isDown(self: Mouse, button: MouseButton) bool {
        return (self.down & bit(button)) != 0;
    }

    fn wasPressed(self: Mouse, button: MouseButton) bool {
        return (self.pressed & bit(button)) != 0;
    }

    fn wasReleased(self: Mouse, button: MouseButton) bool {
        return (self.released & bit(button)) != 0;
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !Window {
    var be: impl.Backend = try impl.init(io, allocator, cfg);
    return Window{
        .backend = be,
        .allocator = allocator,
        .mouse = .{ .pos = be.getCursorPos() },
        .canvas_selector = cfg.canvas_selector,
        .content_scale = be.computeContentScale(),
    };
}

pub inline fn deinit(self: *Window) void {
    self.char_buf.deinit(self.allocator);
    self.key_events.deinit(self.allocator);
    self.key_buf.deinit(self.allocator);
    self.backend.deinit();
}

pub inline fn startCapture(self: *Window) void {
    self.backend.startCapture(self);
}

pub inline fn pollEvents(self: *const Window, io: std.Io) void {
    self.backend.pollEvents(io);
}

pub inline fn waitEvents(self: *const Window, io: std.Io) void {
    self.backend.waitEvents(io);
}

pub inline fn postEmptyEvent(self: *const Window) void {
    self.backend.postEmptyEvent();
}

pub inline fn setFrameHandler(self: *Window, handler: FrameHandler) void {
    self.frame_handler = handler;
}

pub inline fn clearFrameHandler(self: *Window) void {
    self.frame_handler = null;
}

pub fn requestFrame(self: *Window) void {
    if (self.frame_handler) |handler| {
        handler.request(handler.ctx);
    }
}

pub fn stepFrame(self: *Window) void {
    if (self.frame_handler) |handler| {
        handler.step(handler.ctx);
    }
}

pub fn isOpen(self: *const Window) bool {
    if (self.should_close) return false;
    return self.backend.isOpen();
}

pub fn close(self: *Window) void {
    self.should_close = true;
    self.backend.close();
}

pub inline fn getSize(self: *const Window) Size {
    return self.backend.getSize();
}

pub inline fn getFramebufferSize(self: *const Window) Size {
    return self.backend.getFramebufferSize();
}

pub fn getContentScale(self: *const Window) f32 {
    return self.content_scale;
}

pub inline fn getWindowHandle(self: *const Window) gpu.Context.WindowHandle {
    return self.backend.getNativeHandle(self.canvas_selector);
}

pub inline fn setDisplayMode(self: *Window, mode: DisplayMode) void {
    self.backend.setDisplayMode(mode);
    self.display_mode = mode;
}

pub inline fn setCursorVisible(self: *const Window, visible: bool) void {
    self.backend.setCursorVisible(visible);
}

pub fn collectInput(self: *Window) !Input {
    if (self.input_error) |err| {
        self.input_error = null;
        return err;
    }

    var shift_held = false;
    var ctrl_held = false;
    var super_held = false;

    try self.key_buf.ensureTotalCapacity(self.allocator, self.key_events.items.len);
    self.key_buf.clearRetainingCapacity();
    for (self.key_events.items) |ev| {
        if (ev.mods.shift) shift_held = true;
        if (ev.mods.ctrl) ctrl_held = true;
        if (ev.mods.super) super_held = true;
        if (ev.action != .press and ev.action != .repeat) continue;

        const key = std.enums.fromInt(Key, ev.key) orelse continue;
        self.key_buf.appendAssumeCapacity(key);
    }

    const scroll = self.scroll;
    const mouse = self.mouse;
    const chars = self.char_buf.items;

    self.input_dirty = false;
    self.scroll = .{};
    self.mouse.pressed = 0;
    self.mouse.released = 0;
    self.mouse.pressed_pos = .{ null, null };
    self.mouse.released_pos = .{ null, null };

    self.char_buf.clearRetainingCapacity();
    self.key_events.clearRetainingCapacity();
    return .{
        .pos = mouse.pos,
        .mouse_left_down_now = mouse.isDown(.left),
        .mouse_left_pressed = mouse.wasPressed(.left),
        .mouse_left_released = mouse.wasReleased(.left),
        .mouse_left_pressed_pos = mouse.pressed_pos[Mouse.index(.left)],
        .mouse_left_released_pos = mouse.released_pos[Mouse.index(.left)],
        .mouse_right_down_now = mouse.isDown(.right),
        .mouse_right_pressed = mouse.wasPressed(.right),
        .mouse_right_released = mouse.wasReleased(.right),
        .mouse_right_pressed_pos = mouse.pressed_pos[Mouse.index(.right)],
        .mouse_right_released_pos = mouse.released_pos[Mouse.index(.right)],
        .scroll = scroll,
        .chars = chars,
        .keys = self.key_buf.items,
        .shift_held = shift_held,
        .ctrl_held = ctrl_held,
        .super_held = super_held,
    };
}

pub fn consumeResize(self: *Window) ?ResizeEvent {
    const ev = self.backend.consumeResize(self) orelse return null;
    self.content_scale = ev.content_scale;
    return ev;
}

pub fn consumeDrops(self: *Window, allocator: std.mem.Allocator) ![][]const u8 {
    const n = self.pending_drop_count;
    self.pending_drop_count = 0;
    if (n == 0) return &[_][]const u8{};
    return self.backend.consumeDrops(self, allocator, n);
}

pub fn getClipboardText(self: *Window, allocator: std.mem.Allocator) !?[]u8 {
    return self.backend.getClipboardText(allocator);
}

pub fn setClipboardText(self: *Window, allocator: std.mem.Allocator, text: []const u8) !bool {
    return self.backend.setClipboardText(allocator, text);
}

pub fn pushChar(self: *Window, codepoint: u21) void {
    self.char_buf.append(self.allocator, codepoint) catch |err| {
        self.input_error = err;
        self.markInputChanged();
        return;
    };
    self.markInputChanged();
}

pub fn pushKey(self: *Window, key: i32, action: KeyAction, mods: Mods) void {
    self.key_events.append(self.allocator, .{ .key = key, .action = action, .mods = mods }) catch |err| {
        self.input_error = err;
        self.markInputChanged();
        return;
    };
    self.markInputChanged();
}

pub fn addScroll(self: *Window, scroll: ScrollInput) void {
    self.scroll.add(scroll);
    if (!scroll.isZero()) self.markInputChanged();
}

pub fn addScrollPixels(self: *Window, dx: f64, dy: f64) void {
    self.addScroll(.{ .pixel = .{ @floatCast(dx), @floatCast(dy) } });
}

pub fn addScrollLines(self: *Window, dx: f64, dy: f64) void {
    self.addScroll(.{ .line = .{ @floatCast(dx), @floatCast(dy) } });
}

pub fn addScrollPages(self: *Window, dx: f64, dy: f64) void {
    self.addScroll(.{ .page = .{ @floatCast(dx), @floatCast(dy) } });
}

pub fn setCursorPos(self: *Window, pos: [2]f64) void {
    if (self.mouse.pos[0] == pos[0] and self.mouse.pos[1] == pos[1]) return;
    self.mouse.pos = pos;
    self.markInputChanged();
}

pub fn setMouseButton(self: *Window, button: MouseButton, down: bool, pos: [2]f64) void {
    const b = Mouse.bit(button);
    const i = Mouse.index(button);
    if (down == ((self.mouse.down & b) != 0)) return;

    self.setCursorPos(pos);

    if (down) {
        self.mouse.down |= b;
        self.mouse.pressed |= b;
        self.mouse.pressed_pos[i] = pos;
    } else {
        self.mouse.down &= ~b;
        self.mouse.released |= b;
        self.mouse.released_pos[i] = pos;
    }
    self.markInputChanged();
}

pub fn setMouseLeftDown(self: *Window, down: bool) void {
    self.setMouseButton(.left, down, self.mouse.pos);
}

pub fn setMouseRightDown(self: *Window, down: bool) void {
    self.setMouseButton(.right, down, self.mouse.pos);
}

pub fn anyMouseButtonDown(self: *const Window) bool {
    return self.mouse.down != 0;
}

pub fn markResized(self: *Window) void {
    self.resized = true;
}

pub fn markClosed(self: *Window) void {
    self.should_close = true;
}

pub fn markDropped(self: *Window, count: usize) void {
    self.pending_drop_count = @intCast(@min(count, std.math.maxInt(u8)));
    if (count > 0) self.markInputChanged();
}

fn markInputChanged(self: *Window) void {
    if (self.input_dirty) return;
    self.input_dirty = true;
    self.requestFrame();
}
