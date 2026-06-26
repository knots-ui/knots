const std = @import("std");
const gpu = @import("gpu");
const window = @import("window");
const events = @import("events.zig");
const em = @import("bindings.zig");

pub const EmscriptenUiEvent = em.EmscriptenUiEvent;

pub const EmscriptenKeyboardEvent = extern struct {
    timestamp: f64,
    location: c_uint,
    ctrlKey: bool,
    shiftKey: bool,
    altKey: bool,
    metaKey: bool,
    repeat: bool,
    charCode: c_uint,
    keyCode: c_uint,
    which: c_uint,
    key: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
    code: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
    charValue: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
    locale: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
};

pub const EmscriptenMouseEvent = extern struct {
    timestamp: f64,
    screenX: c_int,
    screenY: c_int,
    clientX: c_int,
    clientY: c_int,
    ctrlKey: bool,
    shiftKey: bool,
    altKey: bool,
    metaKey: bool,
    button: c_ushort,
    buttons: c_ushort,
    movementX: c_int,
    movementY: c_int,
    targetX: c_int,
    targetY: c_int,
    canvasX: c_int,
    canvasY: c_int,
    padding: c_int,
};

pub const EmscriptenWheelEvent = extern struct {
    mouse: EmscriptenMouseEvent,
    deltaX: f64,
    deltaY: f64,
    deltaZ: f64,
    deltaMode: c_uint,
};

pub const EmscriptenFocusEvent = extern struct {
    nodeName: [EM_HTML5_LONG_STRING_LEN_BYTES]u8,
    id: [EM_HTML5_LONG_STRING_LEN_BYTES]u8,
};

const EM_HTML5_SHORT_STRING_LEN_BYTES = 32;
const EM_HTML5_LONG_STRING_LEN_BYTES = 128;

const KeyCallback = *const fn (event_type: c_int, ev: *const EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool;
const MouseCallback = *const fn (event_type: c_int, ev: *const EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool;
const WheelCallback = *const fn (event_type: c_int, ev: *const EmscriptenWheelEvent, user_data: ?*anyopaque) callconv(.c) bool;
const FocusCallback = *const fn (event_type: c_int, ev: *const EmscriptenFocusEvent, user_data: ?*anyopaque) callconv(.c) bool;
const PasteCallback = *const fn (owner: ?*anyopaque, text: [*]const u8, len: u32) callconv(.c) void;
const DisplayModeCallback = *const fn (owner: ?*anyopaque, fullscreen: c_int) callconv(.c) void;
const AnimationFrameCallback = *const fn (timestamp: f64, user_data: ?*anyopaque) callconv(.c) bool;

extern fn emscripten_set_keydown_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?KeyCallback, thread: c_int) c_int;
extern fn emscripten_set_keyup_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?KeyCallback, thread: c_int) c_int;
extern fn emscripten_set_mousedown_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?MouseCallback, thread: c_int) c_int;
extern fn emscripten_set_mouseup_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?MouseCallback, thread: c_int) c_int;
extern fn emscripten_set_mousemove_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?MouseCallback, thread: c_int) c_int;
extern fn emscripten_set_wheel_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?WheelCallback, thread: c_int) c_int;
extern fn emscripten_set_focus_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?FocusCallback, thread: c_int) c_int;
extern fn emscripten_set_blur_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: ?FocusCallback, thread: c_int) c_int;

extern fn emscripten_request_fullscreen(target: [*:0]const u8, defer_until_in_event_handler: bool) c_int;
extern fn emscripten_exit_fullscreen() c_int;
extern fn emscripten_request_animation_frame(cb: AnimationFrameCallback, user_data: ?*anyopaque) c_long;
extern fn emscripten_cancel_animation_frame(request_animation_frame_id: c_long) void;
extern fn knots_emscripten_bridge_link() void;
extern fn knots_emscripten_start_capture(owner: ?*anyopaque, selector: [*:0]const u8, paste_callback: PasteCallback, display_mode_callback: DisplayModeCallback) void;
extern fn knots_emscripten_stop_capture(owner: ?*anyopaque) void;
extern fn knots_emscripten_prepare_paste(owner: ?*anyopaque) void;
extern fn knots_emscripten_set_cursor(selector: [*:0]const u8, cursor: [*:0]const u8) void;
extern fn knots_emscripten_set_title(title: [*]const u8, title_length: usize) void;
extern fn knots_emscripten_copy(text: [*]const u8, text_length: usize) c_int;

const EMSCRIPTEN_EVENT_TARGET_WINDOW = em.EMSCRIPTEN_EVENT_TARGET_WINDOW;
const EMSCRIPTEN_EVENT_TARGET_DOCUMENT = em.EMSCRIPTEN_EVENT_TARGET_DOCUMENT;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    selector: [:0]const u8,
    logical_size: window.Size,
    physical_size: window.Size,
    content_scale: f32,
    pending_resize: ?window.ResizeEvent,
    is_fullscreen: bool = false,
    desired_display_mode: window.DisplayMode = .windowed,
    display_mode_transition: bool = false,
    cursor_visible: bool = true,
    cursor_shape: window.CursorShape = .default,
    owner_addr: usize = 0,
    pending_animation_frame: ?c_long = null,
    clipboard_text: std.ArrayList(u8) = .empty,
    clipboard_valid: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.pending_animation_frame) |id| {
            emscripten_cancel_animation_frame(id);
            self.pending_animation_frame = null;
        }
        if (self.owner_addr != 0) knots_emscripten_stop_capture(@ptrFromInt(self.owner_addr));
        self.clipboard_text.deinit(self.allocator);
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        const sel = self.selector.ptr;
        self.owner_addr = @intFromPtr(owner);
        // Keyboard events go on the window target — canvas-scoped keyboard requires
        // the canvas to have tabindex and be focused, which most host pages don't set up.
        _ = emscripten_set_keydown_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyDown, 0);
        _ = emscripten_set_keyup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyUp, 0);
        _ = emscripten_set_mousedown_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseDown, 0);
        _ = emscripten_set_mouseup_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseUp, 0);
        // Listen on document so a drag released outside the canvas still fires mouseup.
        _ = emscripten_set_mouseup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_DOCUMENT, @ptrCast(owner), false, events.onMouseUp, 0);
        _ = emscripten_set_mousemove_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseMove, 0);
        _ = emscripten_set_wheel_callback_on_thread(sel, @ptrCast(owner), false, events.onWheel, 0);
        _ = em.emscripten_set_resize_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onResize, 0);
        _ = emscripten_set_focus_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onFocus, 0);
        _ = emscripten_set_blur_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onBlur, 0);
        knots_emscripten_start_capture(owner, sel, pasteCallback, displayModeCallback);
    }

    pub fn preparePaste(self: *Self) void {
        if (self.owner_addr == 0) return;
        knots_emscripten_prepare_paste(@ptrFromInt(self.owner_addr));
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {}
    pub fn waitEvents(_: *const Self, _: std.Io) void {}
    pub fn postEmptyEvent(_: *Self) void {}

    pub fn requestFrame(self: *Self, owner: *window.Window) void {
        if (self.pending_animation_frame != null or self.owner_addr == 0) return;
        if (!owner.isOpen()) return;
        self.pending_animation_frame = emscripten_request_animation_frame(animationFrameCallback, owner);
    }

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn close(self: *Self) void {
        if (self.pending_animation_frame) |id| {
            emscripten_cancel_animation_frame(id);
            self.pending_animation_frame = null;
        }
    }

    pub fn getSize(self: *const Self) window.Size {
        return self.logical_size;
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        return self.physical_size;
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return self.content_scale;
    }

    pub fn getCursorPos(_: *const Self) [2]f64 {
        return .{ 0, 0 };
    }

    pub fn getNativeHandle(_: *const Self, canvas_selector: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .emscripten = .{ .selector = canvas_selector orelse @panic("canvas_selector must be set for emscripten windows") } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (self.cursor_visible == visible) return;
        self.cursor_visible = visible;
        self.applyCursor();
    }

    pub fn setCursorShape(self: *Self, shape: window.CursorShape) void {
        if (self.cursor_shape == shape) return;
        self.cursor_shape = shape;
        self.applyCursor();
    }

    fn applyCursor(self: *Self) void {
        const css: [*:0]const u8 = if (!self.cursor_visible) "none" else switch (self.cursor_shape) {
            .default => "default",
            .text => "text",
            .pointer => "pointer",
            .crosshair => "crosshair",
            .move => "move",
            .resize_horizontal => "ew-resize",
            .resize_vertical => "ns-resize",
            .resize_diagonal_nw_se => "nwse-resize",
            .resize_diagonal_ne_sw => "nesw-resize",
            .not_allowed => "not-allowed",
        };
        knots_emscripten_set_cursor(self.selector.ptr, css);
    }

    pub fn setTitle(_: *Self, title: []const u8) !void {
        knots_emscripten_set_title(title.ptr, title.len);
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        self.desired_display_mode = mode;
        return self.reconcileDisplayMode();
    }

    fn reconcileDisplayMode(self: *Self) bool {
        if (self.display_mode_transition or self.desired_display_mode == self.getDisplayMode()) return true;
        // Browser policy requires fullscreen to originate from a user gesture;
        // defer_until_in_event_handler queues it for the next one when necessary.
        const result = switch (self.desired_display_mode) {
            .windowed => emscripten_exit_fullscreen(),
            .fullscreen => emscripten_request_fullscreen(self.selector.ptr, true),
        };
        if (result < 0) return false;
        self.display_mode_transition = true;
        return true;
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return if (self.is_fullscreen) .fullscreen else .windowed;
    }

    pub fn refreshCanvas(self: *Self) void {
        const cs = em.applyCanvasSize(self.selector, self.logical_size.width, self.logical_size.height);
        const ev: window.ResizeEvent = .{
            .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
            .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
            .content_scale = cs.content_scale,
        };
        self.logical_size = ev.logical;
        self.physical_size = ev.physical;
        self.content_scale = ev.content_scale;
        self.pending_resize = ev;
    }

    pub fn consumeResize(self: *Self, _: *window.Window) ?window.ResizeEvent {
        const ev = self.pending_resize orelse return null;
        self.pending_resize = null;
        return ev;
    }

    pub fn consumeDrops(_: *Self, _: *window.Window, _: std.mem.Allocator, _: usize) ![][]const u8 {
        return &[_][]const u8{};
    }

    pub fn getClipboardText(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.clipboard_valid) return null;
        self.clipboard_valid = false;
        defer self.clipboard_text.clearRetainingCapacity();
        return try allocator.dupe(u8, self.clipboard_text.items);
    }

    pub fn setClipboardText(_: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        return knots_emscripten_copy(text.ptr, text.len) != 0;
    }
};

fn animationFrameCallback(_: f64, ctx: ?*anyopaque) callconv(.c) bool {
    const owner: *window.Window = @ptrCast(@alignCast(ctx orelse return false));
    owner.backend.pending_animation_frame = null;
    if (owner.isOpen()) owner.stepFrame();
    return false;
}

fn pasteCallback(ctx: ?*anyopaque, ptr: [*]const u8, len: u32) callconv(.c) void {
    const owner: *window.Window = @ptrCast(@alignCast(ctx orelse return));
    owner.backend.clipboard_text.clearRetainingCapacity();
    owner.backend.clipboard_text.appendSlice(owner.backend.allocator, ptr[0..@intCast(len)]) catch {
        owner.backend.clipboard_valid = false;
        return;
    };
    owner.backend.clipboard_valid = true;
    owner.pushKey(@intFromEnum(window.Key.v), .press, .{ .ctrl = true });
    owner.pushKey(@intFromEnum(window.Key.v), .release, .{ .ctrl = true });
}

fn displayModeCallback(ctx: ?*anyopaque, fullscreen: c_int) callconv(.c) void {
    const owner: *window.Window = @ptrCast(@alignCast(ctx orelse return));
    const mode: window.DisplayMode = if (fullscreen != 0) .fullscreen else .windowed;
    owner.backend.is_fullscreen = fullscreen != 0;
    if (!owner.backend.display_mode_transition) owner.backend.desired_display_mode = mode;
    owner.backend.display_mode_transition = false;
    owner.requestFrame();
    _ = owner.backend.reconcileDisplayMode();
}

pub fn init(_: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    knots_emscripten_bridge_link();
    const selector = cfg.canvas_selector orelse @panic("canvas_selector must be set for emscripten windows");
    const cs = em.applyCanvasSize(selector, cfg.width, cfg.height);
    const ev: window.ResizeEvent = .{
        .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
        .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
        .content_scale = cs.content_scale,
    };
    var backend: Backend = .{
        .allocator = allocator,
        .selector = selector,
        .logical_size = ev.logical,
        .physical_size = ev.physical,
        .content_scale = ev.content_scale,
        .pending_resize = ev,
    };
    try backend.setTitle(cfg.title);
    return backend;
}
