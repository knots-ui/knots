const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const gpu = @import("gpu");
const window = @import("window");

const keymap = @import("keymap.zig");
const xkb = @import("xkb.zig");

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const BTN_SIDE: u32 = 0x113;
const BTN_EXTRA: u32 = 0x114;
const TEXT_URI_LIST: [*:0]const u8 = "text/uri-list";
const TEXT_UTF8: [*:0]const u8 = "text/plain;charset=utf-8";
const TEXT_PLAIN: [*:0]const u8 = "text/plain";
const MAX_CLIPBOARD_BYTES: usize = 1024 * 1024;

const OutputState = struct {
    output: *wl.Output,
    scale: i32 = 1,
    entered: bool = false,
};

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    clipboard_source: ?*wl.DataSource = null,
    clipboard_text: []u8 = &.{},
    selection_offer: ?*wl.DataOffer = null,
    selection_mime: ?[*:0]const u8 = null,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_surface: ?*wl.Surface = null,
    cursor: ?*wl.Cursor = null,
    owner: ?*window.Window = null,
    wake_pipe: [2]posix.fd_t = .{ -1, -1 },
    frame_requested: bool = false,
    logical_size: window.Size,
    configured_size: window.Size,
    scale: i32 = 1,
    preferred_scale: i32 = 1,
    configured: bool = false,
    should_close: bool = false,
    display_mode: window.DisplayMode = .windowed,
    desired_display_mode: window.DisplayMode = .windowed,
    display_mode_transition: bool = false,
    cursor_visible: bool = true,
    cursor_shape: window.CursorShape = .default,
    pointer_enter_serial: u32 = 0,
    cursor_pos: [2]f64 = .{ 0, 0 },
    pending_axis: [2]f64 = .{ 0, 0 },
    pending_axis_discrete: [2]?i32 = .{ null, null },
    pending_axis_value120: [2]?i32 = .{ null, null },
    pending_axis_source: ?wl.Pointer.AxisSource = null,
    outputs: [16]OutputState = undefined,
    output_count: usize = 0,
    title_buf: [512:0]u8 = undefined,
    drop_paths_buf: [64][1024]u8 = undefined,
    drop_slices: [64][]const u8 = undefined,
    pending_offer: ?*wl.DataOffer = null,
    pending_offer_has_uri: bool = false,
    pending_offer_mime: ?[*:0]const u8 = null,
    drag_offer: ?*wl.DataOffer = null,
    drag_serial: u32 = 0,
    drag_has_uri: bool = false,
    drag_action_ok: bool = false,
    xkb_context: ?*xkb.Context = null,
    xkb_keymap: ?*xkb.Keymap = null,
    xkb_state: ?*xkb.State = null,
    repeat_rate: i32 = 0,
    repeat_delay_ms: i32 = 600,
    repeat_key: ?u32 = null,
    repeat_window_key: window.Key = @enumFromInt(0),
    repeat_char: ?u21 = null,
    repeat_next_ms: i64 = 0,
    last_keyboard_serial: u32 = 0,

    fn deinit(self: *State) void {
        self.clearRepeat();
        self.deinitXkb();
        self.clearClipboardSource();
        if (self.selection_offer) |offer| offer.destroy();

        if (self.drag_offer) |offer| offer.destroy();
        if (self.data_device) |data_device| releaseDataDevice(data_device);
        if (self.keyboard) |keyboard| releaseKeyboard(keyboard);
        if (self.pointer) |pointer| releasePointer(pointer);
        if (self.seat) |seat| releaseSeat(seat);
        if (self.cursor_theme) |theme| theme.destroy();
        if (self.cursor_surface) |surface| surface.destroy();
        if (self.decoration) |decoration| decoration.destroy();
        if (self.decoration_manager) |manager| manager.destroy();
        for (self.outputs[0..self.output_count]) |entry| releaseOutput(entry.output);
        if (self.shm) |shm| shm.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        if (self.wm_base) |wm_base| wm_base.destroy();
        if (self.compositor) |compositor| compositor.destroy();
        self.registry.destroy();
        self.display.disconnect();
        closeFd(self.wake_pipe[0]);
        closeFd(self.wake_pipe[1]);
        self.allocator.destroy(self);
    }

    fn clearClipboardSource(self: *State) void {
        if (self.clipboard_source) |source| source.destroy();
        self.clipboard_source = null;
        if (self.clipboard_text.len > 0) {
            self.allocator.free(self.clipboard_text);
            self.clipboard_text = &.{};
        }
    }

    fn deinitXkb(self: *State) void {
        if (self.xkb_state) |state| {
            xkb.xkb_state_unref(state);
            self.xkb_state = null;
        }
        if (self.xkb_keymap) |map| {
            xkb.xkb_keymap_unref(map);
            self.xkb_keymap = null;
        }
        if (self.xkb_context) |ctx| {
            xkb.xkb_context_unref(ctx);
            self.xkb_context = null;
        }
    }

    fn currentMods(self: *const State) window.Mods {
        const state = self.xkb_state orelse return .{};
        return .{
            .shift = xkb.xkb_state_mod_name_is_active(state, "Shift", xkb.STATE_MODS_EFFECTIVE) > 0,
            .ctrl = xkb.xkb_state_mod_name_is_active(state, "Control", xkb.STATE_MODS_EFFECTIVE) > 0,
            .alt = xkb.xkb_state_mod_name_is_active(state, "Mod1", xkb.STATE_MODS_EFFECTIVE) > 0,
            .super = xkb.xkb_state_mod_name_is_active(state, "Mod4", xkb.STATE_MODS_EFFECTIVE) > 0,
        };
    }

    fn utf32ForKey(self: *const State, evdev_key: u32) ?u21 {
        const state = self.xkb_state orelse return null;
        const cp = xkb.xkb_state_key_get_utf32(state, evdev_key + 8);
        if (cp < 0x20 or cp == 0x7F or cp > std.math.maxInt(u21)) return null;
        const mods = self.currentMods();
        if ((mods.ctrl and !mods.alt) or mods.super) return null;
        return @intCast(cp);
    }

    fn clearRepeat(self: *State) void {
        self.repeat_key = null;
        self.repeat_char = null;
        self.repeat_next_ms = 0;
    }

    fn startRepeat(self: *State, evdev_key: u32, translated: window.Key, cp: ?u21) void {
        if (self.repeat_rate <= 0) {
            self.clearRepeat();
            return;
        }
        const time_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.repeat_key = evdev_key;
        self.repeat_window_key = translated;
        self.repeat_char = cp;
        self.repeat_next_ms = time_ms + @as(i64, self.repeat_delay_ms);
    }

    fn repeatTimeoutMs(self: *const State, io: std.Io) i32 {
        if (self.repeat_key == null) return -1;
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (self.repeat_next_ms <= now) return 0;
        const delta = self.repeat_next_ms - now;
        return @intCast(@min(delta, std.math.maxInt(i32)));
    }

    fn processRepeat(self: *State, io: std.Io) void {
        const owner = self.owner orelse return;
        if (self.repeat_key == null or self.repeat_rate <= 0) return;

        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (now < self.repeat_next_ms) return;

        const interval = @max(@as(i64, 1), @divTrunc(1000, @as(i64, self.repeat_rate)));
        var emitted: usize = 0;
        while (now >= self.repeat_next_ms and emitted < 8) : (emitted += 1) {
            owner.pushKey(@intFromEnum(self.repeat_window_key), .repeat, self.currentMods());
            if (self.repeat_char) |cp| owner.pushChar(cp);
            self.repeat_next_ms += interval;
        }
    }

    fn recomputeScale(self: *State) void {
        var next = @max(self.preferred_scale, 1);
        for (self.outputs[0..self.output_count]) |entry| {
            if (entry.entered) next = @max(next, entry.scale);
        }
        if (next == self.scale) return;
        self.scale = next;
        self.surface.setBufferScale(next);
        self.surface.commit();
        if (self.owner) |owner| {
            owner.markResized();
            owner.requestFrame();
        }
    }

    fn findOutput(self: *State, output: *wl.Output) ?*OutputState {
        for (self.outputs[0..self.output_count]) |*entry| {
            if (entry.output == output) return entry;
        }
        return null;
    }

    fn setupDataDevice(self: *State) void {
        if (self.data_device != null) return;
        const manager = self.data_device_manager orelse return;
        const seat = self.seat orelse return;
        const data_device = manager.getDataDevice(seat) catch return;
        data_device.setListener(*State, dataDeviceListener, self);
        self.data_device = data_device;
    }

    fn offerMime(self: *State, data_offer: *wl.DataOffer, mime: [*:0]const u8) void {
        if (self.pending_offer != data_offer) return;
        if (std.mem.orderZ(u8, mime, TEXT_URI_LIST) == .eq) {
            self.pending_offer_has_uri = true;
        } else if (std.mem.orderZ(u8, mime, TEXT_UTF8) == .eq) {
            self.pending_offer_mime = TEXT_UTF8;
        } else if (self.pending_offer_mime == null and std.mem.orderZ(u8, mime, TEXT_PLAIN) == .eq) {
            self.pending_offer_mime = TEXT_PLAIN;
        }
    }

    fn applyCursor(self: *State) void {
        const pointer = self.pointer orelse return;
        if (!self.cursor_visible) {
            pointer.setCursor(self.pointer_enter_serial, null, 0, 0);
            _ = self.display.flush();
            return;
        }

        const cursor = self.cursor orelse return;
        if (cursor.image_count == 0) return;
        const image = cursor.images[0];
        const buffer = image.getBuffer() catch return;
        const surface = self.cursor_surface orelse return;
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, @intCast(image.width), @intCast(image.height));
        surface.commit();
        pointer.setCursor(
            self.pointer_enter_serial,
            surface,
            @intCast(image.hotspot_x),
            @intCast(image.hotspot_y),
        );
        _ = self.display.flush();
    }

    fn reconcileDisplayMode(self: *State) void {
        if (self.display_mode_transition or self.display_mode == self.desired_display_mode) return;
        switch (self.desired_display_mode) {
            .windowed => self.toplevel.unsetFullscreen(),
            .fullscreen => self.toplevel.setFullscreen(null),
        }
        self.surface.commit();
        _ = self.display.flush();
        self.display_mode_transition = true;
    }

    fn handleKeymap(state: *State, format: wl.Keyboard.KeymapFormat, fd: i32, size: u32) !void {
        defer closeFd(fd);
        if (format != .xkb_v1 or size == 0) return;

        const mapped = try posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        defer posix.munmap(mapped);

        const context = state.xkb_context orelse blk: {
            const ctx = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
            state.xkb_context = ctx;
            break :blk ctx;
        };
        const new_keymap = xkb.xkb_keymap_new_from_buffer(
            context,
            mapped.ptr,
            mapped.len,
            xkb.KEYMAP_FORMAT_TEXT_V1,
            xkb.KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapFailed;
        errdefer xkb.xkb_keymap_unref(new_keymap);

        const new_state = xkb.xkb_state_new(new_keymap) orelse return error.XkbStateFailed;
        errdefer xkb.xkb_state_unref(new_state);

        if (state.xkb_state) |old| xkb.xkb_state_unref(old);
        if (state.xkb_keymap) |old| xkb.xkb_keymap_unref(old);
        state.xkb_keymap = new_keymap;
        state.xkb_state = new_state;
    }
};

pub const Backend = struct {
    state: *State,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        self.state.deinit();
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        self.state.owner = owner;
    }

    pub fn pollEvents(self: *const Self, io: std.Io) void {
        drainWake(self.state);
        _ = self.state.display.dispatchPending();
        self.state.processRepeat(io);
        drainWake(self.state);
        dispatchFrame(self.state);
    }

    pub fn waitEvents(self: *const Self, io: std.Io) void {
        while (!self.state.display.prepareRead()) {
            _ = self.state.display.dispatchPending();
        }

        _ = self.state.display.flush();

        var fds = [_]posix.pollfd{
            .{
                .fd = self.state.display.getFd(),
                .events = @intCast(posix.POLL.IN),
                .revents = 0,
            },
            .{
                .fd = self.state.wake_pipe[0],
                .events = @intCast(posix.POLL.IN),
                .revents = 0,
            },
        };
        const ready = posix.poll(&fds, self.state.repeatTimeoutMs(io)) catch 0;
        if (ready > 0 and (fds[0].revents & @as(i16, @intCast(posix.POLL.IN))) != 0) {
            _ = self.state.display.readEvents();
        } else {
            self.state.display.cancelRead();
        }
        if (ready > 0 and (fds[1].revents & @as(i16, @intCast(posix.POLL.IN))) != 0) {
            drainWake(self.state);
        }

        _ = self.state.display.dispatchPending();
        self.state.processRepeat(io);
        drainWake(self.state);
        dispatchFrame(self.state);
    }

    pub fn postEmptyEvent(self: *const Self) void {
        const byte: [1]u8 = .{1};
        _ = linux.write(self.state.wake_pipe[1], &byte, 1);
    }

    pub fn requestFrame(self: *const Self, owner: *window.Window) void {
        if (self.state.frame_requested or !owner.isOpen()) return;
        self.state.frame_requested = true;
        self.postEmptyEvent();
    }

    pub fn isOpen(self: *const Self) bool {
        return !self.state.should_close;
    }

    pub fn close(self: *Self) void {
        self.state.should_close = true;
        self.postEmptyEvent();
    }

    pub fn getSize(self: *const Self) window.Size {
        return self.state.logical_size;
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        return .{
            .width = self.state.logical_size.width * @as(u32, @intCast(self.state.scale)),
            .height = self.state.logical_size.height * @as(u32, @intCast(self.state.scale)),
        };
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return @floatFromInt(self.state.scale);
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        return self.state.cursor_pos;
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .linux = .{ .wayland = .{
            .display = @ptrCast(self.state.display),
            .surface = @ptrCast(self.state.surface),
        } } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (self.state.cursor_visible == visible) return;
        self.state.cursor_visible = visible;
        self.state.applyCursor();
    }

    pub fn setCursorShape(self: *Self, shape: window.CursorShape) void {
        if (self.state.cursor_shape == shape) return;
        self.state.cursor_shape = shape;
        if (self.state.cursor_theme) |theme| {
            const name: [*:0]const u8 = switch (shape) {
                .default => "left_ptr",
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
            self.state.cursor = theme.getCursor(name) orelse theme.getCursor("left_ptr");
            self.state.applyCursor();
        }
    }

    pub fn setTitle(self: *Self, title: []const u8) !void {
        if (title.len >= self.state.title_buf.len) return error.TitleTooLong;
        @memcpy(self.state.title_buf[0..title.len], title);
        self.state.title_buf[title.len] = 0;
        self.state.toplevel.setTitle(@ptrCast(&self.state.title_buf));
        self.state.surface.commit();
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        self.state.desired_display_mode = mode;
        self.state.reconcileDisplayMode();
        return true;
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return self.state.display_mode;
    }

    pub fn consumeResize(self: *Self, owner: *window.Window) ?window.ResizeEvent {
        if (!owner.resized) return null;
        owner.resized = false;
        return .{
            .logical = self.getSize(),
            .physical = self.getFramebufferSize(),
            .content_scale = self.computeContentScale(),
        };
    }

    pub fn consumeDrops(self: *Self, _: *window.Window, allocator: std.mem.Allocator, n: usize) ![][]const u8 {
        const out = try allocator.alloc([]const u8, n);
        errdefer allocator.free(out);
        for (0..n) |i| out[i] = try allocator.dupe(u8, self.state.drop_slices[i]);
        return out;
    }

    pub fn getClipboardText(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        if (self.state.selection_offer) |offer| {
            const mime = self.state.selection_mime orelse return null;
            return receiveClipboardText(self.state, allocator, offer, mime) catch null;
        }
        if (self.state.clipboard_text.len > 0) return try allocator.dupe(u8, self.state.clipboard_text);
        return null;
    }

    pub fn setClipboardText(self: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        const manager = self.state.data_device_manager orelse return false;
        const data_device = self.state.data_device orelse return false;
        if (self.state.last_keyboard_serial == 0) return false;

        const source = manager.createDataSource() catch return false;
        errdefer source.destroy();
        const owned_text = try self.state.allocator.dupe(u8, text);
        errdefer self.state.allocator.free(owned_text);

        source.setListener(*State, dataSourceListener, self.state);
        source.offer(TEXT_UTF8);
        source.offer(TEXT_PLAIN);

        self.state.clearClipboardSource();
        self.state.clipboard_source = source;
        self.state.clipboard_text = owned_text;

        data_device.setSelection(source, self.state.last_keyboard_serial);
        _ = self.state.display.flush();
        return true;
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    if (cfg.title.len >= 512) return error.TitleTooLong;
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    errdefer registry.destroy();

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);

    var title_buf: [512:0]u8 = undefined;
    const title_len = cfg.title.len;
    @memcpy(title_buf[0..title_len], cfg.title[0..title_len]);
    title_buf[title_len] = 0;

    state.* = .{
        .io = io,
        .allocator = allocator,
        .display = display,
        .registry = registry,
        .surface = undefined,
        .xdg_surface = undefined,
        .toplevel = undefined,
        .logical_size = .{ .width = cfg.width, .height = cfg.height },
        .configured_size = .{ .width = cfg.width, .height = cfg.height },
        .title_buf = title_buf,
    };

    state.wake_pipe = try createWakePipe();
    errdefer {
        closeFd(state.wake_pipe[0]);
        closeFd(state.wake_pipe[1]);
    }

    registry.setListener(*State, registryListener, state);
    if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;

    const compositor = state.compositor orelse return error.NoWlCompositor;
    const wm_base = state.wm_base orelse return error.NoXdgWmBase;

    state.surface = try compositor.createSurface();
    state.surface.setListener(*State, surfaceListener, state);
    state.xdg_surface = try wm_base.getXdgSurface(state.surface);
    state.xdg_surface.setListener(*State, xdgSurfaceListener, state);
    state.toplevel = try state.xdg_surface.getToplevel();
    state.toplevel.setListener(*State, xdgToplevelListener, state);
    state.toplevel.setTitle(@ptrCast(&state.title_buf));
    state.toplevel.setAppId("knots");

    if (!cfg.resizable) {
        state.toplevel.setMinSize(@intCast(cfg.width), @intCast(cfg.height));
        state.toplevel.setMaxSize(@intCast(cfg.width), @intCast(cfg.height));
    }
    if (cfg.resizable) {
        if (cfg.min_size) |size| state.toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
        if (cfg.max_size) |size| state.toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));
    }

    if (state.decoration_manager) |manager| {
        if (manager.getToplevelDecoration(state.toplevel)) |decoration| {
            decoration.setListener(*State, decorationListener, state);
            decoration.setMode(.server_side);
            state.decoration = decoration;
        } else |_| {}
    }

    if (state.shm) |shm| {
        state.cursor_theme = wl.CursorTheme.load(null, 24, shm) catch null;
        if (state.cursor_theme) |theme| state.cursor = theme.getCursor("left_ptr");
        state.cursor_surface = compositor.createSurface() catch null;
    }

    state.setupDataDevice();
    state.surface.commit();

    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
    }

    return .{ .state = state };
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *State) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                state.compositor = registry.bind(global.name, wl.Compositor, global.version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                state.shm = registry.bind(global.name, wl.Shm, global.version) catch null;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                const seat = registry.bind(global.name, wl.Seat, global.version) catch return;
                seat.setListener(*State, seatListener, state);
                state.seat = seat;
                state.setupDataDevice();
            } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                if (state.output_count >= state.outputs.len) return;
                const output = registry.bind(global.name, wl.Output, global.version) catch return;
                output.setListener(*State, outputListener, state);
                state.outputs[state.output_count] = .{ .output = output };
                state.output_count += 1;
            } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                state.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, global.version) catch null;
                state.setupDataDevice();
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                const wm_base = registry.bind(global.name, xdg.WmBase, global.version) catch return;
                wm_base.setListener(*State, wmBaseListener, state);
                state.wm_base = wm_base;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                state.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, global.version) catch null;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *State) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, state: *State) void {
    switch (event) {
        .enter => |enter| {
            const output = enter.output orelse return;
            if (state.findOutput(output)) |entry| {
                entry.entered = true;
                state.recomputeScale();
            }
        },
        .leave => |leave| {
            const output = leave.output orelse return;
            if (state.findOutput(output)) |entry| {
                entry.entered = false;
                state.recomputeScale();
            }
        },
        .preferred_buffer_scale => |scale| {
            state.preferred_scale = @max(scale.factor, 1);
            state.recomputeScale();
        },
        .preferred_buffer_transform => {},
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, state: *State) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            state.logical_size = state.configured_size;
            state.surface.commit();
            state.configured = true;
            if (state.owner) |owner| {
                owner.markResized();
                owner.requestFrame();
            }
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *State) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0) state.configured_size.width = @intCast(configure.width);
            if (configure.height > 0) state.configured_size.height = @intCast(configure.height);
            var mode: window.DisplayMode = .windowed;
            for (configure.states.*.slice(u32)) |configured_state| {
                if (configured_state == @intFromEnum(xdg.Toplevel.State.fullscreen)) {
                    mode = .fullscreen;
                    break;
                }
            }
            const changed = state.display_mode != mode;
            if (!state.display_mode_transition) state.desired_display_mode = mode;
            state.display_mode = mode;
            state.display_mode_transition = false;
            if (changed) {
                if (state.owner) |owner| owner.requestFrame();
            }
            state.reconcileDisplayMode();
        },
        .close => {
            state.should_close = true;
            if (state.owner) |owner| owner.markClosed();
        },
    }
}

fn decorationListener(_: *zxdg.ToplevelDecorationV1, _: zxdg.ToplevelDecorationV1.Event, _: *State) void {}

fn outputListener(output: *wl.Output, event: wl.Output.Event, state: *State) void {
    const entry = state.findOutput(output) orelse return;
    switch (event) {
        .scale => |scale| {
            entry.scale = @max(scale.factor, 1);
            state.recomputeScale();
        },
        .geometry, .mode, .done, .name, .description => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *State) void {
    switch (event) {
        .capabilities => |cap| {
            if (cap.capabilities.pointer and state.pointer == null) {
                const pointer = seat.getPointer() catch return;
                pointer.setListener(*State, pointerListener, state);
                state.pointer = pointer;
            } else if (!cap.capabilities.pointer and state.pointer != null) {
                releasePointer(state.pointer.?);
                state.pointer = null;
                if (state.owner) |owner| owner.cancelPointerInput();
            }

            if (cap.capabilities.keyboard and state.keyboard == null) {
                const keyboard = seat.getKeyboard() catch return;
                keyboard.setListener(*State, keyboardListener, state);
                state.keyboard = keyboard;
            } else if (!cap.capabilities.keyboard and state.keyboard != null) {
                releaseKeyboard(state.keyboard.?);
                state.keyboard = null;
                state.clearRepeat();
                if (state.owner) |owner| owner.setFocused(false);
            }
        },
        .name => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, state: *State) void {
    const owner = state.owner;
    switch (event) {
        .enter => |enter| {
            state.pointer_enter_serial = enter.serial;
            state.cursor_pos = .{ enter.surface_x.toDouble(), enter.surface_y.toDouble() };
            if (owner) |o| o.setCursorPos(state.cursor_pos);
            state.applyCursor();
        },
        .leave => {},
        .motion => |motion| {
            state.cursor_pos = .{ motion.surface_x.toDouble(), motion.surface_y.toDouble() };
            if (owner) |o| o.setCursorPos(state.cursor_pos);
        },
        .button => |button| {
            const translated: ?window.MouseButton = switch (button.button) {
                BTN_LEFT => .left,
                BTN_RIGHT => .right,
                BTN_MIDDLE => .middle,
                BTN_SIDE => .back,
                BTN_EXTRA => .forward,
                else => null,
            };
            if (translated) |mouse_button| if (owner) |o| o.setMouseButton(mouse_button, button.state == .pressed, state.cursor_pos);
        },
        .axis => |axis| {
            const idx: usize = if (axis.axis == .horizontal_scroll) 0 else 1;
            state.pending_axis[idx] += axis.value.toDouble();
        },
        .axis_source => |axis| state.pending_axis_source = axis.axis_source,
        .axis_discrete => |axis| {
            const idx: usize = if (axis.axis == .horizontal_scroll) 0 else 1;
            state.pending_axis_discrete[idx] = axis.discrete;
        },
        .axis_value120 => |axis| {
            const idx: usize = if (axis.axis == .horizontal_scroll) 0 else 1;
            state.pending_axis_value120[idx] = axis.value120;
        },
        .frame => {
            const dx = axisAmount(state.pending_axis[0], state.pending_axis_discrete[0], state.pending_axis_value120[0]);
            const dy = axisAmount(state.pending_axis[1], state.pending_axis_discrete[1], state.pending_axis_value120[1]);
            const x_is_line = state.pending_axis_value120[0] != null or state.pending_axis_discrete[0] != null;
            const y_is_line = state.pending_axis_value120[1] != null or state.pending_axis_discrete[1] != null;
            state.pending_axis = .{ 0, 0 };
            state.pending_axis_discrete = .{ null, null };
            state.pending_axis_value120 = .{ null, null };
            state.pending_axis_source = null;
            if (owner) |o| if (dx != 0 or dy != 0) {
                if ((x_is_line and dx != 0) or (y_is_line and dy != 0))
                    o.addScrollLines(if (x_is_line) dx else 0, if (y_is_line) dy else 0);
                if ((!x_is_line and dx != 0) or (!y_is_line and dy != 0))
                    o.addScrollPixels(if (x_is_line) 0 else dx, if (y_is_line) 0 else dy);
            };
        },
        .axis_stop => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, state: *State) void {
    switch (event) {
        .keymap => |keymap_event| state.handleKeymap(keymap_event.format, keymap_event.fd, keymap_event.size) catch |err| {
            std.log.warn("failed to load Wayland XKB keymap: {s}", .{@errorName(err)});
        },
        .enter => {
            if (state.owner) |owner| owner.setFocused(true);
        },
        .leave => {
            state.clearRepeat();
            if (state.owner) |owner| owner.setFocused(false);
        },
        .key => |key| {
            const owner = state.owner orelse return;
            const translated = keymap.translateEvdev(key.key);
            const mods = state.currentMods();
            state.last_keyboard_serial = key.serial;
            switch (key.state) {
                .pressed => {
                    const cp = state.utf32ForKey(key.key);
                    owner.pushKey(@intFromEnum(translated), .press, mods);
                    if (cp) |ch| owner.pushChar(ch);
                    state.startRepeat(key.key, translated, cp);
                },
                .released => {
                    owner.pushKey(@intFromEnum(translated), .release, mods);
                    if (state.repeat_key != null and state.repeat_key.? == key.key) state.clearRepeat();
                },
                _ => {},
            }
        },
        .modifiers => |mods| {
            if (state.xkb_state) |xkb_state| {
                _ = xkb.xkb_state_update_mask(
                    xkb_state,
                    mods.mods_depressed,
                    mods.mods_latched,
                    mods.mods_locked,
                    0,
                    0,
                    mods.group,
                );
            }
            if (state.owner) |owner| owner.setMods(state.currentMods());
        },
        .repeat_info => |repeat| {
            state.repeat_rate = @max(repeat.rate, 0);
            state.repeat_delay_ms = @max(repeat.delay, 0);
            if (state.repeat_rate == 0) state.clearRepeat();
        },
    }
}

fn dataDeviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, state: *State) void {
    switch (event) {
        .data_offer => |data_offer| {
            state.pending_offer = data_offer.id;
            state.pending_offer_has_uri = false;
            state.pending_offer_mime = null;
            data_offer.id.setListener(*State, dataOfferListener, state);
        },
        .enter => |enter| {
            state.drag_offer = enter.id;
            state.drag_serial = enter.serial;
            state.drag_has_uri = enter.id != null and state.pending_offer == enter.id.? and state.pending_offer_has_uri;
            state.drag_action_ok = false;
            if (enter.id) |offer| {
                if (offer.getVersion() >= 3) {
                    offer.setActions(.{ .copy = true }, .{ .copy = true });
                }
                offer.accept(enter.serial, if (state.drag_has_uri) TEXT_URI_LIST else null);
            }
        },
        .leave => {
            if (state.drag_offer) |offer| offer.destroy();
            state.drag_offer = null;
            state.drag_has_uri = false;
            state.drag_action_ok = false;
        },
        .motion => |motion| {
            state.cursor_pos = .{ motion.x.toDouble(), motion.y.toDouble() };
            if (state.drag_offer) |offer| {
                offer.accept(state.drag_serial, if (state.drag_has_uri) TEXT_URI_LIST else null);
            }
        },
        .drop => {
            const offer = state.drag_offer orelse return;
            defer {
                offer.destroy();
                state.drag_offer = null;
                state.drag_has_uri = false;
                state.drag_action_ok = false;
            }
            if (!state.drag_has_uri) return;
            const count = receiveUriListDrop(state, offer) catch 0;
            if (count > 0) {
                if (state.owner) |owner| owner.markDropped(count);
            }
            if (offer.getVersion() >= 3 and state.drag_action_ok) offer.finish();
        },
        .selection => |selection| {
            if (state.selection_offer) |old| {
                if (selection.id == null or old != selection.id.?) old.destroy();
            }
            state.selection_offer = null;
            state.selection_mime = null;

            const offer = selection.id orelse return;
            if (state.pending_offer == offer) {
                if (state.pending_offer_mime) |mime| {
                    state.selection_offer = offer;
                    state.selection_mime = mime;
                    return;
                }
            }
            offer.destroy();
        },
    }
}

fn dataOfferListener(data_offer: *wl.DataOffer, event: wl.DataOffer.Event, state: *State) void {
    switch (event) {
        .offer => |offer| state.offerMime(data_offer, offer.mime_type),
        .action => |action| {
            if (state.drag_offer == data_offer) {
                state.drag_action_ok = action.dnd_action.copy or action.dnd_action.move;
            }
        },
        .source_actions => {},
    }
}

fn dataSourceListener(data_source: *wl.DataSource, event: wl.DataSource.Event, state: *State) void {
    switch (event) {
        .send => |send| {
            defer closeFd(send.fd);
            if (state.clipboard_source != data_source) return;
            if (std.mem.orderZ(u8, send.mime_type, TEXT_UTF8) != .eq and
                std.mem.orderZ(u8, send.mime_type, TEXT_PLAIN) != .eq)
                return;

            var written: usize = 0;
            while (written < state.clipboard_text.len) {
                const n = linux.write(send.fd, state.clipboard_text[written..].ptr, state.clipboard_text.len - written);
                switch (posix.errno(n)) {
                    .SUCCESS => {
                        const count: usize = @intCast(n);
                        if (count == 0) return;
                        written += count;
                    },
                    else => return,
                }
            }
        },
        .cancelled => {
            if (state.clipboard_source == data_source) state.clearClipboardSource();
        },
        .target, .dnd_drop_performed, .dnd_finished, .action => {},
    }
}

fn receiveClipboardText(state: *State, allocator: std.mem.Allocator, offer: *wl.DataOffer, mime: [*:0]const u8) !?[]u8 {
    var fds: [2]i32 = undefined;
    switch (posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return null,
    }
    defer closeFd(fds[0]);

    offer.receive(mime, fds[1]);
    closeFd(fds[1]);
    _ = state.display.flush();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fds[0], &buf);
        if (n == 0) break;
        if (out.items.len + n > MAX_CLIPBOARD_BYTES) {
            out.deinit(allocator);
            return null;
        }
        try out.appendSlice(allocator, buf[0..n]);
    }

    return try out.toOwnedSlice(allocator);
}

fn receiveUriListDrop(state: *State, offer: *wl.DataOffer) !usize {
    var fds: [2]i32 = undefined;
    switch (posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.PipeFailed,
    }
    defer closeFd(fds[0]);

    offer.receive(TEXT_URI_LIST, fds[1]);
    closeFd(fds[1]);
    _ = state.display.flush();

    var data: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < data.len) {
        const n = try posix.read(fds[0], data[len..]);
        if (n == 0) break;
        len += n;
    }

    return parseUriListIntoBuffers(data[0..len], &state.drop_paths_buf, &state.drop_slices);
}

fn decodeFileUriToBuffer(text: []const u8, out: []u8) ?[]const u8 {
    const parsed = std.Uri.parse(text) catch return null;
    if (!std.mem.eql(u8, parsed.scheme, "file")) return null;

    if (parsed.host) |host_component| {
        var host_buf: [256]u8 = undefined;
        const host = host_component.toRaw(&host_buf) catch return null;
        if (!std.mem.eql(u8, host, "localhost")) return null;
    }

    const raw = parsed.path.toRaw(out) catch return null;
    return ensureBuffered(raw, out);
}

fn ensureBuffered(raw: []const u8, out: []u8) ?[]const u8 {
    if (raw.len == 0) return out[0..0];

    const out_start = @intFromPtr(out.ptr);
    const out_end = out_start + out.len;
    const raw_start = @intFromPtr(raw.ptr);
    const raw_end = raw_start + raw.len;
    if (raw_start >= out_start and raw_end <= out_end) return raw;

    if (raw.len > out.len) return null;
    @memcpy(out[0..raw.len], raw);
    return out[0..raw.len];
}

fn parseUriListIntoBuffers(
    list: []const u8,
    buffers: []align(1) [1024]u8,
    slices: [][]const u8,
) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw_line| {
        if (count >= buffers.len or count >= slices.len) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (decodeFileUriToBuffer(line, &buffers[count])) |path| {
            slices[count] = path;
            count += 1;
        }
    }
    return count;
}

fn axisAmount(value: f64, discrete: ?i32, value120: ?i32) f64 {
    if (value120) |v| return @as(f64, @floatFromInt(v)) / 120.0;
    if (discrete) |steps| return @floatFromInt(steps);
    return value;
}

fn createWakePipe() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    switch (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }))) {
        .SUCCESS => return fds,
        .MFILE, .NFILE => return error.SystemResources,
        else => return error.PipeFailed,
    }
}

fn drainWake(state: *State) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = posix.read(state.wake_pipe[0], &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (n == 0 or n < buf.len) return;
    }
}

fn dispatchFrame(state: *State) void {
    if (!state.frame_requested) return;
    state.frame_requested = false;
    const owner = state.owner orelse return;
    if (owner.isOpen()) owner.stepFrame();
}

fn closeFd(fd: i32) void {
    if (fd >= 0) _ = linux.close(fd);
}

fn releasePointer(pointer: *wl.Pointer) void {
    if (pointer.getVersion() >= 3) pointer.release() else pointer.destroy();
}

fn releaseKeyboard(keyboard: *wl.Keyboard) void {
    if (keyboard.getVersion() >= 3) keyboard.release() else keyboard.destroy();
}

fn releaseSeat(seat: *wl.Seat) void {
    if (seat.getVersion() >= 5) seat.release() else seat.destroy();
}

fn releaseOutput(output: *wl.Output) void {
    if (output.getVersion() >= 3) output.release() else output.destroy();
}

fn releaseDataDevice(data_device: *wl.DataDevice) void {
    if (data_device.getVersion() >= 2) data_device.release() else data_device.destroy();
}
