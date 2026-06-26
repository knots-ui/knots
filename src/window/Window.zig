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
const MouseButton = @import("root.zig").MouseButton;
const mouse_button_count = @import("root.zig").mouse_button_count;
const MouseButtonState = @import("root.zig").MouseButtonState;
const key_count = @import("root.zig").key_count;
const CursorShape = @import("root.zig").CursorShape;

backend: impl.Backend,
allocator: std.mem.Allocator,
should_close: bool = false,
mouse: Mouse = .{},
scroll: ScrollInput = .{},
char_buf: std.ArrayList(u21) = .empty,
key_events: std.ArrayList(KeyEvent) = .empty,
key_down: [key_count]bool = @splat(false),
input_error: ?std.mem.Allocator.Error = null,
mods: Mods = .{},
focused: bool = true,
resized: bool = false,
pending_drop_count: u8 = 0,
canvas_selector: ?[:0]const u8,
content_scale: f32 = 1.0,
cursor_shape: CursorShape = .default,
frame_handler: ?FrameHandler = null,
input_dirty: bool = false,

const Window = @This();

const Mouse = struct {
    pos: [2]f64 = .{ 0, 0 },
    buttons: [mouse_button_count]MouseButtonState = @splat(.{}),
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !Window {
    _ = std.unicode.Utf8View.init(cfg.title) catch return error.InvalidTitle;
    if (cfg.min_size) |min_size| {
        if (cfg.max_size) |max_size| {
            if (min_size.width > max_size.width or min_size.height > max_size.height)
                return error.InvalidSizeConstraints;
        }
    }
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
    self.backend.deinit();
    self.char_buf.deinit(self.allocator);
    self.key_events.deinit(self.allocator);
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

pub inline fn postEmptyEvent(self: *Window) void {
    self.backend.postEmptyEvent();
}

pub inline fn setFrameHandler(self: *Window, handler: FrameHandler) void {
    self.frame_handler = handler;
}

pub inline fn clearFrameHandler(self: *Window) void {
    self.frame_handler = null;
}

pub fn requestFrame(self: *Window) void {
    if (self.frame_handler == null) return;
    self.backend.requestFrame(self);
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
    self.backend.postEmptyEvent();
}

pub inline fn getSize(self: *const Window) Size {
    return self.backend.getSize();
}

pub inline fn getFramebufferSize(self: *const Window) Size {
    return self.backend.getFramebufferSize();
}

pub inline fn getContentScale(self: *const Window) f32 {
    return self.content_scale;
}

pub inline fn getWindowHandle(self: *const Window) gpu.Context.WindowHandle {
    return self.backend.getNativeHandle(self.canvas_selector);
}

pub fn setDisplayMode(self: *Window, mode: DisplayMode) bool {
    return self.backend.setDisplayMode(mode);
}

pub inline fn getDisplayMode(self: *const Window) DisplayMode {
    return self.backend.getDisplayMode();
}

pub inline fn isFocused(self: *const Window) bool {
    return self.focused;
}

pub fn setTitle(self: *Window, title: []const u8) !void {
    _ = std.unicode.Utf8View.init(title) catch return error.InvalidTitle;
    try self.backend.setTitle(title);
}

pub inline fn setCursorVisible(self: *Window, visible: bool) void {
    self.backend.setCursorVisible(visible);
}

pub fn setCursorShape(self: *Window, shape: CursorShape) void {
    if (self.cursor_shape == shape) return;
    self.cursor_shape = shape;
    self.backend.setCursorShape(shape);
}

pub fn collectInput(self: *Window) !Input {
    if (self.input_error) |err| {
        self.input_error = null;
        return err;
    }

    const scroll = self.scroll;
    const mouse = self.mouse;
    const chars = self.char_buf.items;
    const key_events = self.key_events.items;
    self.input_dirty = false;
    self.scroll = .{};
    for (&self.mouse.buttons) |*button| {
        button.pressed = false;
        button.released = false;
        button.pressed_pos = null;
        button.released_pos = null;
    }

    return .{
        .focused = self.focused,
        .pos = mouse.pos,
        .mouse = mouse.buttons,
        .scroll = scroll,
        .chars = chars,
        .key_events = key_events,
        .key_down = &self.key_down,
        .shift_held = self.mods.shift,
        .ctrl_held = self.mods.ctrl,
        .alt_held = self.mods.alt,
        .super_held = self.mods.super,
    };
}

pub fn finishInputFrame(self: *Window) void {
    self.char_buf.clearRetainingCapacity();
    self.key_events.clearRetainingCapacity();
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
    self.mods = mods;
    const translated = std.enums.fromInt(Key, key) orelse return;
    const index = @intFromEnum(translated);
    if (index >= 0 and index < key_count) self.key_down[@intCast(index)] = action != .release;
    self.key_events.append(self.allocator, .{ .key = translated, .action = action, .mods = mods }) catch |err| {
        self.input_error = err;
        self.markInputChanged();
        return;
    };
    self.markInputChanged();
}

pub fn setMods(self: *Window, mods: Mods) void {
    if (self.mods == mods) return;
    self.mods = mods;
    self.markInputChanged();
}

pub fn setFocused(self: *Window, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    if (!focused) {
        self.char_buf.clearRetainingCapacity();
        self.key_events.clearRetainingCapacity();
        self.mods = .{};
        self.key_down = @splat(false);
        self.cancelPointerInput();
    }
    self.markInputChanged();
}

pub fn cancelPointerInput(self: *Window) void {
    var changed = false;
    for (&self.mouse.buttons) |*button| {
        changed = changed or button.down or button.pressed or button.released;
        button.* = .{};
    }
    if (!changed) return;
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
    const state = &self.mouse.buttons[@intFromEnum(button)];
    if (down == state.down) return;

    self.setCursorPos(pos);

    if (down) {
        state.down = true;
        state.pressed = true;
        state.pressed_pos = pos;
    } else {
        state.down = false;
        state.released = true;
        state.released_pos = pos;
    }
    self.markInputChanged();
}

pub fn anyMouseButtonDown(self: *const Window) bool {
    for (self.mouse.buttons) |button| if (button.down) return true;
    return false;
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
