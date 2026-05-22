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

const EMSCRIPTEN_EVENT_TARGET_WINDOW = em.EMSCRIPTEN_EVENT_TARGET_WINDOW;
const EMSCRIPTEN_EVENT_TARGET_DOCUMENT = em.EMSCRIPTEN_EVENT_TARGET_DOCUMENT;

pub const Backend = struct {
    selector: [:0]const u8,
    logical_size: window.Size,
    physical_size: window.Size,
    content_scale: f32,
    pending_resize: ?window.ResizeEvent,
    cursor_pos: [2]f64 = .{ 0, 0 },
    is_fullscreen: bool = false,
    cursor_visible: bool = true,

    const Self = @This();

    pub fn deinit(_: *const Self) void {}

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        const sel = self.selector.ptr;
        // Keyboard events go on the window target — canvas-scoped keyboard requires
        // the canvas to have tabindex and be focused, which most host pages don't set up.
        _ = emscripten_set_keydown_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyDown, 0);
        _ = emscripten_set_keyup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyUp, 0);
        _ = emscripten_set_mousedown_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseDown, 0);
        // Listen on document so a drag released outside the canvas still fires mouseup.
        _ = emscripten_set_mouseup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_DOCUMENT, @ptrCast(owner), false, events.onMouseUp, 0);
        _ = emscripten_set_mousemove_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseMove, 0);
        _ = emscripten_set_wheel_callback_on_thread(sel, @ptrCast(owner), false, events.onWheel, 0);
        _ = em.emscripten_set_resize_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onResize, 0);
        _ = emscripten_set_blur_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onBlur, 0);
    }

    pub fn pollEvents(_: *const Self) void {}
    pub fn waitEvents(_: *const Self) void {}
    pub fn postEmptyEvent(_: *const Self) void {}

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn close(_: *const Self) void {}

    pub fn getSize(self: *const Self) window.Size {
        return self.logical_size;
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        return self.physical_size;
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return self.content_scale;
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        return self.cursor_pos;
    }

    pub fn getNativeHandle(_: *const Self, canvas_selector: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .emscripten = .{ .selector = canvas_selector orelse @panic("canvas_selector must be set for emscripten windows") } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (self.cursor_visible == visible) return;
        self.cursor_visible = visible;
        var buf: [256]u8 = undefined;
        const script = std.fmt.bufPrintZ(&buf, "document.querySelector({s}{s}{s}).style.cursor='{s}'", .{
            "\"", self.selector, "\"", if (visible) "auto" else "none",
        }) catch return;
        std.os.emscripten.emscripten_run_script(script.ptr);
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) void {
        switch (mode) {
            .windowed => {
                if (self.is_fullscreen) _ = emscripten_exit_fullscreen();
                self.is_fullscreen = false;
            },
            .fullscreen, .fullscreen_windowed => {
                // The browser ignores requested width/height/refresh_rate and always uses monitor resolution.
                // deferUntilInEventHandler=true queues the request for the next user gesture if not already inside one, required by browser policy.
                _ = emscripten_request_fullscreen(self.selector.ptr, true);
                self.is_fullscreen = true;
            },
        }
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
};

pub fn init(_: std.Io, _: std.mem.Allocator, cfg: window.Config) !Backend {
    const selector = cfg.canvas_selector orelse @panic("canvas_selector must be set for emscripten windows");
    const cs = em.applyCanvasSize(selector, cfg.width, cfg.height);
    const ev: window.ResizeEvent = .{
        .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
        .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
        .content_scale = cs.content_scale,
    };
    return .{
        .selector = selector,
        .logical_size = ev.logical,
        .physical_size = ev.physical,
        .content_scale = ev.content_scale,
        .pending_resize = ev,
    };
}
