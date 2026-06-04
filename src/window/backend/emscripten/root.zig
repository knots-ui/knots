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
    allocator: std.mem.Allocator,
    selector: [:0]const u8,
    logical_size: window.Size,
    physical_size: window.Size,
    content_scale: f32,
    pending_resize: ?window.ResizeEvent,
    is_fullscreen: bool = false,
    cursor_visible: bool = true,
    owner_addr: usize = 0,
    clipboard_text: std.ArrayList(u8) = .empty,
    clipboard_valid: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.owner_addr != 0) {
            var buf: [512]u8 = undefined;
            const script = std.fmt.bufPrintSentinel(
                &buf,
                "(() => {{ const key='__knotsPaste_{d}'; const cb=globalThis[key]; if (cb) {{ document.removeEventListener('paste', cb, true); delete globalThis[key]; }} const el=globalThis[key + 'Catcher']; if (el) {{ el.remove(); delete globalThis[key + 'Catcher']; }} }})()",
                .{self.owner_addr},
                0x00,
            ) catch null;
            if (script) |s| std.os.emscripten.emscripten_run_script(s.ptr);
        }
        self.clipboard_text.deinit(self.allocator);
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        const sel = self.selector.ptr;
        self.owner_addr = @intFromPtr(owner);
        const paste_cb_addr = @intFromPtr(&pasteCallback);
        // Keyboard events go on the window target — canvas-scoped keyboard requires
        // the canvas to have tabindex and be focused, which most host pages don't set up.
        _ = emscripten_set_keydown_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyDown, 0);
        _ = emscripten_set_keyup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), true, events.onKeyUp, 0);
        _ = emscripten_set_mousedown_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseDown, 0);
        _ = emscripten_set_mouseup_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseUp, 0);
        // Listen on document so a drag released outside the canvas still fires mouseup.
        _ = emscripten_set_mouseup_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_DOCUMENT, @ptrCast(owner), false, events.onMouseUp, 0);
        _ = emscripten_set_mousemove_callback_on_thread(sel, @ptrCast(owner), false, events.onMouseMove, 0);
        suppressNativeContextMenu(self.selector);
        _ = emscripten_set_wheel_callback_on_thread(sel, @ptrCast(owner), false, events.onWheel, 0);
        _ = em.emscripten_set_resize_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onResize, 0);
        _ = emscripten_set_blur_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, events.onBlur, 0);
        var buf: [4096]u8 = undefined;
        const script = std.fmt.bufPrintSentinel(
            &buf,
            \\(() => {{
            \\  const key='__knotsPaste_{d}';
            \\  if (globalThis[key]) return;
            \\  const catcher = document.createElement('textarea');
            \\  catcher.setAttribute('readonly', '');
            \\  catcher.setAttribute('aria-hidden', 'true');
            \\  catcher.style.position = 'fixed';
            \\  catcher.style.left = '-10000px';
            \\  catcher.style.top = '0';
            \\  catcher.style.width = '1px';
            \\  catcher.style.height = '1px';
            \\  catcher.style.opacity = '0';
            \\  document.body.appendChild(catcher);
            \\  globalThis[key + 'Catcher'] = catcher;
            \\  globalThis[key] = (e) => {{
            \\    const target = e.target;
            \\    if (target && (target.isContentEditable || target.tagName === 'INPUT' || (target.tagName === 'TEXTAREA' && target !== catcher))) return;
            \\    const data = e.clipboardData && e.clipboardData.getData('text/plain');
            \\    if (data == null) return;
            \\    const len = lengthBytesUTF8(data);
            \\    const ptr = _malloc(len + 1);
            \\    if (!ptr) return;
            \\    stringToUTF8Array(data, HEAPU8, ptr, len + 1);
            \\    if (typeof dynCall_vjjj !== 'undefined') {{
            \\      dynCall_vjjj({d}, BigInt({d}), BigInt(ptr), BigInt(len));
            \\    }} else {{
            \\      dynCall_viii({d}, {d}, ptr, len);
            \\    }}
            \\    _free(ptr);
            \\    e.preventDefault();
            \\    if (document.activeElement === catcher) catcher.blur();
            \\  }};
            \\  document.addEventListener('paste', globalThis[key], true);
            \\}})()
        ,
            .{ self.owner_addr, paste_cb_addr, self.owner_addr, paste_cb_addr, self.owner_addr },
            0x00,
        ) catch return;
        std.os.emscripten.emscripten_run_script(script.ptr);
    }

    pub fn preparePaste(self: *Self) void {
        if (self.owner_addr == 0) return;
        var buf: [512]u8 = undefined;
        const script = std.fmt.bufPrintSentinel(
            &buf,
            "(() => {{ const el=globalThis['__knotsPaste_{d}Catcher']; if (!el) return; el.value=''; el.removeAttribute('readonly'); el.focus(); el.select(); setTimeout(() => {{ el.setAttribute('readonly', ''); if (document.activeElement === el) el.blur(); }}, 1000); }})()",
            .{self.owner_addr},
            0x00,
        ) catch return;
        std.os.emscripten.emscripten_run_script(script.ptr);
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {}
    pub fn waitEvents(_: *const Self, _: std.Io) void {}
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

    pub fn getCursorPos(_: *const Self) [2]f64 {
        return .{ 0, 0 };
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

    pub fn getClipboardText(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.clipboard_valid) return null;
        self.clipboard_valid = false;
        defer self.clipboard_text.clearRetainingCapacity();
        return try allocator.dupe(u8, self.clipboard_text.items);
    }

    pub fn setClipboardText(_: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        var buf: [1536]u8 = undefined;
        const script = std.fmt.bufPrintSentinel(
            &buf,
            \\(() => {{
            \\  const text = UTF8ToString({d}, {d});
            \\  const ta = document.createElement('textarea');
            \\  ta.value = text;
            \\  ta.setAttribute('readonly', '');
            \\  ta.style.position = 'fixed';
            \\  ta.style.left = '-10000px';
            \\  ta.style.top = '0';
            \\  document.body.appendChild(ta);
            \\  ta.focus();
            \\  ta.select();
            \\  let ok = false;
            \\  try {{ ok = document.execCommand('copy'); }}
            \\  catch (_) {{ ok = false; }}
            \\  document.body.removeChild(ta);
            \\  return ok ? 1 : 0;
            \\}})()
        ,
            .{ @intFromPtr(text.ptr), text.len },
            0x00,
        ) catch return false;
        return std.os.emscripten.emscripten_run_script_int(script.ptr) != 0;
    }
};

fn pasteCallback(owner_addr: usize, ptr: [*]const u8, len: usize) callconv(.c) void {
    const owner: *window.Window = @ptrFromInt(owner_addr);
    owner.backend.clipboard_text.clearRetainingCapacity();
    owner.backend.clipboard_text.appendSlice(owner.backend.allocator, ptr[0..len]) catch {
        owner.backend.clipboard_valid = false;
        return;
    };
    owner.backend.clipboard_valid = true;
    owner.pushKey(@intFromEnum(window.Key.v), .press, .{ .ctrl = true });
}

// Not good.
fn suppressNativeContextMenu(selector: [:0]const u8) void {
    var buf: [512]u8 = undefined;
    const script = std.fmt.bufPrintSentinel(
        &buf,
        "(() => {{ const el = document.querySelector(\"{s}\"); if (el) el.oncontextmenu = (e) => e.preventDefault(); }})()",
        .{selector},
        0x00,
    ) catch return;
    std.os.emscripten.emscripten_run_script(script.ptr);
}

pub fn init(_: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    const selector = cfg.canvas_selector orelse @panic("canvas_selector must be set for emscripten windows");
    const cs = em.applyCanvasSize(selector, cfg.width, cfg.height);
    const ev: window.ResizeEvent = .{
        .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
        .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
        .content_scale = cs.content_scale,
    };
    return .{
        .allocator = allocator,
        .selector = selector,
        .logical_size = ev.logical,
        .physical_size = ev.physical,
        .content_scale = ev.content_scale,
        .pending_resize = ev,
    };
}
