const std = @import("std");
const gpu = @import("gpu");
const js = @import("js-bridge");
const window = @import("window");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    selector: [:0]const u8,
    canvas: js.Value,
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
    pending_animation_frame: bool = false,
    frame_request: ?u32 = null,
    capture: ?Capture = null,
    clipboard_text: std.ArrayList(u8) = .empty,
    clipboard_valid: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.cancelFrame();
        self.stopCapture();
        self.canvas.release();
        self.clipboard_text.deinit(self.allocator);
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        if (self.capture != null) return;
        self.owner_addr = @intFromPtr(owner);
        self.capture = Capture.init(self) catch |err| {
            self.owner_addr = 0;
            logError("failed to initialize browser event capture", err);
            return;
        };
    }

    pub fn preparePaste(self: *Self) void {
        const capture = if (self.capture) |*value| value else return;
        const host = webHost() catch return;
        defer host.release();
        host.callVoid("preparePaste", &.{js.Arg.value(capture.catcher)}) catch {};
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {}
    pub fn waitEvents(_: *const Self, _: std.Io) void {}
    pub fn postEmptyEvent(_: *Self) void {}

    pub fn requestFrame(self: *Self, owner: *window.Window) void {
        if (self.pending_animation_frame or self.owner_addr == 0) return;
        if (!owner.isOpen()) return;
        const capture = if (self.capture) |*value| value else return;
        const win = js.global("window") catch return;
        defer win.release();
        const frame = win.call("requestAnimationFrame", &.{js.Arg.value(capture.frame.function)}) catch return;
        defer frame.release();
        self.frame_request = frame.tryU32() catch return;
        self.pending_animation_frame = true;
    }

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn close(self: *Self) void {
        self.cancelFrame();
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

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .web = .{ .selector = self.selector } };
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
        const css = if (!self.cursor_visible) "none" else switch (self.cursor_shape) {
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
        const style = self.canvas.get("style") catch return;
        defer style.release();
        style.set("cursor", js.Arg.string(css)) catch {};
    }

    pub fn setTitle(_: *Self, title: []const u8) !void {
        const document = try js.global("document");
        defer document.release();
        try document.set("title", js.Arg.string(title));
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        self.desired_display_mode = mode;
        return self.reconcileDisplayMode();
    }

    fn reconcileDisplayMode(self: *Self) bool {
        if (self.desired_display_mode == self.getDisplayMode()) {
            self.display_mode_transition = false;
            if (self.desired_display_mode == .windowed) {
                const host = webHost() catch return true;
                defer host.release();
                host.callVoid("cancelFullscreen", &.{js.Arg.value(self.canvas)}) catch {};
            }
            return true;
        }
        if (self.display_mode_transition) return true;
        const result = switch (self.desired_display_mode) {
            .windowed => self.exitFullscreen(),
            .fullscreen => self.requestFullscreen(),
        };
        if (!result) return false;
        self.display_mode_transition = true;
        return true;
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return if (self.is_fullscreen) .fullscreen else .windowed;
    }

    pub fn refreshCanvas(self: *Self) void {
        const ev = readCanvasSize(self.canvas, self.logical_size.width, self.logical_size.height) catch return;
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
        const host = try webHost();
        defer host.release();
        const result = try host.call("copy", &.{js.Arg.string(text)});
        defer result.release();
        return try result.tryBool();
    }

    fn stopCapture(self: *Self) void {
        if (self.capture) |*capture| {
            capture.deinit(self);
            self.capture = null;
        }
    }

    fn cancelFrame(self: *Self) void {
        const id = self.frame_request orelse {
            self.pending_animation_frame = false;
            return;
        };
        const win = js.global("window") catch {
            self.frame_request = null;
            self.pending_animation_frame = false;
            return;
        };
        defer win.release();
        win.callVoid("cancelAnimationFrame", &.{js.Arg.u32(id)}) catch {};
        self.frame_request = null;
        self.pending_animation_frame = false;
    }

    fn requestFullscreen(self: *Self) bool {
        const host = webHost() catch return false;
        defer host.release();
        const result = host.call("requestFullscreen", &.{js.Arg.value(self.canvas)}) catch return false;
        defer result.release();
        return result.tryBool() catch false;
    }

    fn exitFullscreen(_: *Self) bool {
        const host = webHost() catch return false;
        defer host.release();
        const result = host.call("exitFullscreen", &.{}) catch return false;
        defer result.release();
        return result.tryBool() catch false;
    }
};

const Capture = struct {
    catcher: js.Value,
    keydown: js.Callback,
    keyup: js.Callback,
    mousedown: js.Callback,
    mouseup: js.Callback,
    mousemove: js.Callback,
    wheel: js.Callback,
    resize: js.Callback,
    focus: js.Callback,
    blur: js.Callback,
    fullscreen: js.Callback,
    fullscreen_failed: js.Callback,
    paste: js.Callback,
    contextmenu: js.Callback,
    frame: js.Callback,

    fn init(backend: *Backend) !Capture {
        var capture: Capture = blk: {
            var keydown = try js.Callback.init(backend, onKeyDown);
            errdefer keydown.deinit();
            var keyup = try js.Callback.init(backend, onKeyUp);
            errdefer keyup.deinit();
            var mousedown = try js.Callback.init(backend, onMouseDown);
            errdefer mousedown.deinit();
            var mouseup = try js.Callback.init(backend, onMouseUp);
            errdefer mouseup.deinit();
            var mousemove = try js.Callback.init(backend, onMouseMove);
            errdefer mousemove.deinit();
            var wheel = try js.Callback.init(backend, onWheel);
            errdefer wheel.deinit();
            var resize = try js.Callback.init(backend, onResize);
            errdefer resize.deinit();
            var focus = try js.Callback.init(backend, onFocus);
            errdefer focus.deinit();
            var blur = try js.Callback.init(backend, onBlur);
            errdefer blur.deinit();
            var fullscreen = try js.Callback.init(backend, onFullscreen);
            errdefer fullscreen.deinit();
            var fullscreen_failed = try js.Callback.init(backend, onFullscreenFailed);
            errdefer fullscreen_failed.deinit();
            var paste = try js.Callback.init(backend, onPaste);
            errdefer paste.deinit();
            var contextmenu = try js.Callback.init(backend, onContextMenu);
            errdefer contextmenu.deinit();
            var frame = try js.Callback.init(backend, onAnimationFrame);
            errdefer frame.deinit();

            const host = try webHost();
            defer host.release();
            const catcher = try host.call("createPasteCatcher", &.{});
            errdefer catcher.release();

            break :blk .{
                .catcher = catcher,
                .keydown = keydown,
                .keyup = keyup,
                .mousedown = mousedown,
                .mouseup = mouseup,
                .mousemove = mousemove,
                .wheel = wheel,
                .resize = resize,
                .focus = focus,
                .blur = blur,
                .fullscreen = fullscreen,
                .fullscreen_failed = fullscreen_failed,
                .paste = paste,
                .contextmenu = contextmenu,
                .frame = frame,
            };
        };
        errdefer capture.deinit(backend);

        const win = try js.global("window");
        defer win.release();
        const document = try js.global("document");
        defer document.release();

        try addListener(win, "keydown", capture.keydown, true);
        try addListener(win, "keyup", capture.keyup, true);
        try addListener(win, "resize", capture.resize, false);
        try addListener(win, "focus", capture.focus, false);
        try addListener(win, "blur", capture.blur, false);
        try addListener(document, "fullscreenchange", capture.fullscreen, false);
        try addListener(document, "knotsfullscreenfailed", capture.fullscreen_failed, false);
        try addListener(document, "paste", capture.paste, true);
        try addListener(document, "mouseup", capture.mouseup, false);
        try addListener(backend.canvas, "mousedown", capture.mousedown, false);
        try addListener(backend.canvas, "mouseup", capture.mouseup, false);
        try addListener(backend.canvas, "mousemove", capture.mousemove, false);
        try addWheelListener(backend.canvas, capture.wheel);
        try addListener(backend.canvas, "contextmenu", capture.contextmenu, false);

        return capture;
    }

    fn deinit(self: *Capture, backend: *Backend) void {
        const win: ?js.Value = js.global("window") catch null;
        defer {
            if (win) |value| value.release();
        }
        const document: ?js.Value = js.global("document") catch null;
        defer {
            if (document) |value| value.release();
        }

        if (win) |value| {
            removeListener(value, "keydown", self.keydown, true);
            removeListener(value, "keyup", self.keyup, true);
            removeListener(value, "resize", self.resize, false);
            removeListener(value, "focus", self.focus, false);
            removeListener(value, "blur", self.blur, false);
        }
        if (document) |value| {
            removeListener(value, "fullscreenchange", self.fullscreen, false);
            removeListener(value, "knotsfullscreenfailed", self.fullscreen_failed, false);
            removeListener(value, "paste", self.paste, true);
            removeListener(value, "mouseup", self.mouseup, false);
        }
        removeListener(backend.canvas, "mousedown", self.mousedown, false);
        removeListener(backend.canvas, "mouseup", self.mouseup, false);
        removeListener(backend.canvas, "mousemove", self.mousemove, false);
        removeListener(backend.canvas, "wheel", self.wheel, false);
        removeListener(backend.canvas, "contextmenu", self.contextmenu, false);
        endMouseCapture(backend);
        self.catcher.callVoid("remove", &.{}) catch {};
        self.catcher.release();

        self.keydown.deinit();
        self.keyup.deinit();
        self.mousedown.deinit();
        self.mouseup.deinit();
        self.mousemove.deinit();
        self.wheel.deinit();
        self.resize.deinit();
        self.focus.deinit();
        self.blur.deinit();
        self.fullscreen.deinit();
        self.fullscreen_failed.deinit();
        self.paste.deinit();
        self.contextmenu.deinit();
        self.frame.deinit();
    }
};

pub fn init(_: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    const selector = cfg.canvas_selector orelse "#canvas";
    const host = try webHost();
    defer host.release();
    const canvas = try host.call("resolveCanvas", &.{js.Arg.string(selector)});
    errdefer canvas.release();

    const ev = try readCanvasSize(canvas, cfg.width, cfg.height);
    var backend: Backend = .{
        .allocator = allocator,
        .selector = selector,
        .canvas = canvas,
        .logical_size = ev.logical,
        .physical_size = ev.physical,
        .content_scale = ev.content_scale,
        .pending_resize = ev,
    };
    try backend.setTitle(cfg.title);
    return backend;
}

pub fn initSecondary(_: *const Backend, _: std.Io, _: std.mem.Allocator, _: window.Config) !Backend {
    return error.UnsupportedPlatform;
}

fn readCanvasSize(canvas: js.Value, fallback_w: u32, fallback_h: u32) !window.ResizeEvent {
    const host = try webHost();
    defer host.release();
    const size = try host.call("canvasSize", &.{
        js.Arg.value(canvas),
        js.Arg.u32(fallback_w),
        js.Arg.u32(fallback_h),
    });
    defer size.release();

    return .{
        .logical = .{
            .width = try getU32(size, "logicalW"),
            .height = try getU32(size, "logicalH"),
        },
        .physical = .{
            .width = try getU32(size, "physicalW"),
            .height = try getU32(size, "physicalH"),
        },
        .content_scale = @floatCast(try getF64(size, "contentScale")),
    };
}

fn addListener(target: js.Value, name: []const u8, callback: js.Callback, capture: bool) !void {
    try target.callVoid("addEventListener", &.{
        js.Arg.string(name),
        js.Arg.value(callback.function),
        js.Arg.boolean(capture),
    });
}

fn addWheelListener(target: js.Value, callback: js.Callback) !void {
    var options = try js.ObjectBuilder.init();
    defer options.finish().release();
    try options.set("passive", js.Arg.boolean(false));
    try target.callVoid("addEventListener", &.{
        js.Arg.string("wheel"),
        js.Arg.value(callback.function),
        js.Arg.value(options.value),
    });
}

fn removeListener(target: js.Value, name: []const u8, callback: js.Callback, capture: bool) void {
    target.callVoid("removeEventListener", &.{
        js.Arg.string(name),
        js.Arg.value(callback.function),
        js.Arg.boolean(capture),
    }) catch {};
}

fn webHost() js.Error!js.Value {
    return js.host();
}

fn logError(message: []const u8, err: anyerror) void {
    const host = webHost() catch return;
    defer host.release();
    host.callVoid("log", &.{
        js.Arg.u32(3),
        js.Arg.string(message),
    }) catch {};
    host.callVoid("log", &.{
        js.Arg.u32(3),
        js.Arg.string(@errorName(err)),
    }) catch {};
}

fn getU32(object: js.Value, name: []const u8) !u32 {
    const value = try object.get(name);
    defer value.release();
    return try value.tryU32();
}

fn getF64(object: js.Value, name: []const u8) !f64 {
    const value = try object.get(name);
    defer value.release();
    return try value.tryF64();
}

fn ownerFromAddr(owner_addr: usize) ?*window.Window {
    if (owner_addr == 0) return null;
    return @ptrFromInt(owner_addr);
}

fn ownerFromBackend(backend: *Backend) ?*window.Window {
    return ownerFromAddr(backend.owner_addr);
}

fn backendFromContext(context: ?*anyopaque) ?*Backend {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn firstEvent(args: js.Value, args_len: u32) ?js.Value {
    if (args_len == 0) return null;
    return args.getIndex(0) catch null;
}

fn preventDefault(event: js.Value) void {
    event.callVoid("preventDefault", &.{}) catch {};
}

fn shouldHandleEvent(backend: *Backend, event: js.Value) bool {
    const capture = if (backend.capture) |*value| value else return true;
    const host = webHost() catch return true;
    defer host.release();
    const result = host.call("shouldHandleEvent", &.{
        js.Arg.value(event),
        js.Arg.value(capture.catcher),
    }) catch return true;
    defer result.release();
    return result.tryBool() catch true;
}

fn endMouseCapture(backend: *Backend) void {
    const capture = if (backend.capture) |*value| value else return;
    const host = webHost() catch return;
    defer host.release();
    host.callVoid("endMouseCapture", &.{
        js.Arg.value(backend.canvas),
        js.Arg.value(capture.mousemove.function),
    }) catch {};
}

fn modsFromBits(bits: u32) window.Mods {
    return .{
        .shift = bits & 1 != 0,
        .ctrl = bits & 2 != 0,
        .alt = bits & 4 != 0,
        .super = bits & 8 != 0,
    };
}

fn eventMods(event: js.Value) ?window.Mods {
    const host = webHost() catch return null;
    defer host.release();
    const bits = host.call("modsOf", &.{js.Arg.value(event)}) catch return null;
    defer bits.release();
    return modsFromBits(bits.tryU32() catch return null);
}

fn eventPosition(backend: *Backend, event: js.Value) ?[2]f64 {
    const host = webHost() catch return null;
    defer host.release();
    const pos = host.call("eventPos", &.{
        js.Arg.value(backend.canvas),
        js.Arg.value(event),
    }) catch return null;
    defer pos.release();
    return .{
        getF64(pos, "x") catch return null,
        getF64(pos, "y") catch return null,
    };
}

fn eventKeyCode(event: js.Value) ?i32 {
    const code = event.get("code") catch return null;
    defer code.release();
    const host = webHost() catch return null;
    defer host.release();
    const key = host.call("keyCode", &.{js.Arg.value(code)}) catch return null;
    defer key.release();
    return key.tryI32() catch return null;
}

fn eventTextCodepoint(event: js.Value) ?u32 {
    const host = webHost() catch return null;
    defer host.release();
    const codepoint = host.call("textCodepoint", &.{js.Arg.value(event)}) catch return null;
    defer codepoint.release();
    const value = codepoint.tryU32() catch return null;
    return if (value == 0) null else value;
}

fn eventBool(event: js.Value, name: []const u8) bool {
    const value = event.get(name) catch return false;
    defer value.release();
    return value.tryBool() catch false;
}

fn onAnimationFrame(context: ?*anyopaque, _: js.Value, _: u32) void {
    const backend = backendFromContext(context) orelse return;
    backend.pending_animation_frame = false;
    backend.frame_request = null;
    const owner = ownerFromBackend(backend) orelse return;
    if (owner.isOpen()) owner.stepFrame();
}

fn onResize(context: ?*anyopaque, _: js.Value, _: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    backend.refreshCanvas();
    owner.markResized();
    owner.requestFrame();
}

fn onFocus(context: ?*anyopaque, _: js.Value, _: u32) void {
    const owner = ownerFromContext(context) orelse return;
    owner.setFocused(true);
}

fn onBlur(context: ?*anyopaque, _: js.Value, _: u32) void {
    const owner = ownerFromContext(context) orelse return;
    owner.setFocused(false);
}

fn onMouseMove(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    const pos = eventPosition(backend, event) orelse return;
    owner.setCursorPos(pos);
}

fn onMouseDown(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    onMouseButton(context, args, args_len, true);
}

fn onMouseUp(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    onMouseButton(context, args, args_len, false);
}

fn onMouseButton(context: ?*anyopaque, args: js.Value, args_len: u32, down: bool) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    const button_value = event.get("button") catch return;
    defer button_value.release();
    const b: window.MouseButton = switch (button_value.tryU32() catch return) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .back,
        4 => .forward,
        else => return,
    };
    const pos = eventPosition(backend, event) orelse return;
    owner.setMouseButton(b, down, pos);
    if (down) {
        if (backend.capture) |*capture| {
            const maybe_host: ?js.Value = webHost() catch null;
            if (maybe_host) |host| {
                defer host.release();
                host.callVoid("beginMouseCapture", &.{
                    js.Arg.value(backend.canvas),
                    js.Arg.value(capture.mousemove.function),
                }) catch {};
            }
        }
        preventDefault(event);
    } else if (!owner.anyMouseButtonDown()) {
        endMouseCapture(backend);
    }
}

fn onWheel(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    const pos = eventPosition(backend, event) orelse return;
    owner.setCursorPos(pos);

    const dx = getF64(event, "deltaX") catch return;
    const dy = getF64(event, "deltaY") catch return;
    const mode = getU32(event, "deltaMode") catch 0;
    switch (mode) {
        0 => owner.addScrollPixels(dx, dy),
        1 => owner.addScrollLines(dx, dy),
        2 => owner.addScrollPages(dx, dy),
        else => owner.addScrollPixels(dx, dy),
    }
    preventDefault(event);
}

fn onKeyDown(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    if (!shouldHandleEvent(backend, event)) return;
    if (eventKeyCode(event)) |key| {
        if (key >= 0) {
            const key_action: window.KeyAction = if (eventBool(event, "repeat")) .repeat else .press;
            const mods = eventMods(event) orelse window.Mods{};
            if (((mods.ctrl and !mods.alt) or mods.super) and key == @intFromEnum(window.Key.v) and key_action == .press) {
                backend.preparePaste();
                return;
            }
            owner.pushKey(key, key_action, mods);
            const maybe_host: ?js.Value = webHost() catch null;
            if (maybe_host) |host| {
                defer host.release();
                const should_prevent: ?js.Value = host.call("shouldPreventKeyDefault", &.{
                    js.Arg.value(event),
                    js.Arg.i32(key),
                }) catch null;
                if (should_prevent) |value| {
                    defer value.release();
                    if (value.tryBool() catch false) preventDefault(event);
                }
            }
        }
    }
    if (eventTextCodepoint(event)) |codepoint| {
        if (codepoint >= 0x20 and codepoint != 0x7F and codepoint <= std.math.maxInt(u21)) {
            owner.pushChar(@intCast(codepoint));
            preventDefault(event);
        }
    }
}

fn onKeyUp(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    if (!shouldHandleEvent(backend, event)) return;
    const key = eventKeyCode(event) orelse return;
    if (key < 0) return;
    owner.pushKey(key, .release, eventMods(event) orelse window.Mods{});
}

fn onPaste(context: ?*anyopaque, args: js.Value, args_len: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    if (!shouldHandleEvent(backend, event)) return;

    const clipboard = event.get("clipboardData") catch return;
    defer clipboard.release();
    if (clipboard.isNullish()) return;
    const text_value = clipboard.call("getData", &.{js.Arg.string("text/plain")}) catch return;
    defer text_value.release();
    const text = text_value.toOwnedString(backend.allocator) catch return;
    defer backend.allocator.free(text);

    backend.clipboard_text.clearRetainingCapacity();
    backend.clipboard_text.appendSlice(backend.allocator, text) catch {
        backend.clipboard_valid = false;
        return;
    };
    backend.clipboard_valid = true;
    owner.pushKey(@intFromEnum(window.Key.v), .press, .{ .ctrl = true });
    owner.pushKey(@intFromEnum(window.Key.v), .release, .{ .ctrl = true });
    preventDefault(event);
}

fn onFullscreen(context: ?*anyopaque, _: js.Value, _: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    const host = webHost() catch return;
    defer host.release();
    const result = host.call("isFullscreen", &.{js.Arg.value(backend.canvas)}) catch return;
    defer result.release();

    const fullscreen = result.tryBool() catch return;
    const mode: window.DisplayMode = if (fullscreen) .fullscreen else .windowed;
    backend.is_fullscreen = fullscreen;
    if (!backend.display_mode_transition) backend.desired_display_mode = mode;
    backend.display_mode_transition = false;
    owner.requestFrame();
}

fn onFullscreenFailed(context: ?*anyopaque, _: js.Value, _: u32) void {
    const backend = backendFromContext(context) orelse return;
    const owner = ownerFromBackend(backend) orelse return;
    backend.display_mode_transition = false;
    owner.requestFrame();
}

fn onContextMenu(_: ?*anyopaque, args: js.Value, args_len: u32) void {
    const event = firstEvent(args, args_len) orelse return;
    defer event.release();
    preventDefault(event);
}

fn ownerFromContext(context: ?*anyopaque) ?*window.Window {
    const backend = backendFromContext(context) orelse return null;
    return ownerFromBackend(backend);
}
