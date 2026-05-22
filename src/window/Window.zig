const std = @import("std");
const gpu = @import("gpu");
const impl = @import("window_impl");

const Key = @import("root.zig").Key;
const Config = @import("root.zig").Config;
const Input = @import("root.zig").Input;
const KeyAction = @import("root.zig").KeyAction;
const Mods = @import("root.zig").Mods;
const KeyEvent = @import("root.zig").KeyEvent;
const Size = @import("root.zig").Size;
const ResizeEvent = @import("root.zig").ResizeEvent;
const DisplayMode = @import("root.zig").DisplayMode;
const FrameHandler = @import("root.zig").FrameHandler;

const SCROLL_SPEED: comptime_float = 10;

backend: impl.Backend,
should_close: bool = false,
mouse_button_pressed: bool = false,
scroll: [2]f64 = .{ 0, 0 },
char_buf: [32]u21 = @splat(0),
char_count: u8 = 0,
key_events: [16]KeyEvent = undefined,
key_buf: [16]Key = undefined,
key_count: u8 = 0,
resized: bool = false,
pending_drop_count: u8 = 0,
canvas_selector: ?[:0]const u8,
content_scale: f32 = 1.0,
display_mode: DisplayMode = .windowed,
frame_handler: ?FrameHandler = null,

const Window = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !Window {
    var be: impl.Backend = try impl.init(io, allocator, cfg);
    return Window{
        .backend = be,
        .canvas_selector = cfg.canvas_selector,
        .content_scale = be.computeContentScale(),
    };
}

pub inline fn deinit(self: *const Window) void {
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

pub fn collectInput(self: *Window) Input {
    const pos = self.backend.getCursorPos();
    const mouse_down_now = self.mouse_button_pressed;
    const scroll_delta: [2]f32 = .{
        @floatCast(self.scroll[0] * SCROLL_SPEED),
        @floatCast(-self.scroll[1] * SCROLL_SPEED),
    };
    self.scroll = @splat(0);

    var translated_count: u8 = 0;
    var shift_held = false;
    var ctrl_held = false;
    var super_held = false;

    for (self.key_events[0..self.key_count]) |ev| {
        if (ev.mods.shift) shift_held = true;
        if (ev.mods.ctrl) ctrl_held = true;
        if (ev.mods.super) super_held = true;
        if (ev.action != .press and ev.action != .repeat) continue;
        if (translated_count >= self.key_buf.len) break;

        const key = std.enums.fromInt(Key, ev.key) orelse continue;
        self.key_buf[translated_count] = key;
        translated_count += 1;
    }

    const chars = self.char_buf[0..self.char_count];
    self.char_count = 0;
    self.key_count = 0;
    return .{
        .pos = pos,
        .mouse_down_now = mouse_down_now,
        .scroll_delta = scroll_delta,
        .chars = chars,
        .keys = self.key_buf[0..translated_count],
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

pub fn pushChar(self: *Window, codepoint: u21) void {
    if (self.char_count < self.char_buf.len) {
        self.char_buf[self.char_count] = codepoint;
        self.char_count += 1;
    }
}

pub fn pushKey(self: *Window, key: i32, action: KeyAction, mods: Mods) void {
    if (self.key_count < self.key_events.len) {
        self.key_events[self.key_count] = .{ .key = key, .action = action, .mods = mods };
        self.key_count += 1;
    }
}

pub fn addScroll(self: *Window, dx: f64, dy: f64) void {
    self.scroll[0] += dx;
    self.scroll[1] += dy;
}

pub fn setMouseDown(self: *Window, down: bool) void {
    self.mouse_button_pressed = down;
}

pub fn markResized(self: *Window) void {
    self.resized = true;
}

pub fn markClosed(self: *Window) void {
    self.should_close = true;
}

pub fn markDropped(self: *Window, count: usize) void {
    self.pending_drop_count = @intCast(@min(count, std.math.maxInt(u8)));
}
