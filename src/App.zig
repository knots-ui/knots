//! Batteries-included desktop owner for windows, rendering, scheduling, and dispatch.

const input_types = @import("input");
const std = @import("std");
const browser_exports = @import("browser_exports");

const renderer = @import("renderer");
const gpu = @import("gpu");
const window = @import("window");
const Window = window.Window;
const WindowConfig = window.Config;
const UI = @import("ui").UI;
const Frame = @import("Frame.zig");

const CompletionQueue = @import("CompletionQueue.zig");
const ReturnType = @import("util.zig").ReturnType;
const Viewport = @import("Viewport.zig");
const View = @import("View.zig");
const platform = @import("platform.zig");

pub const RenderFn = *const fn (*App, *Frame) anyerror!void;

pub const Config = struct {
    window: WindowConfig,
    depth_buffer: bool = false,
    renderer: renderer.Renderer.Config = .{},
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
    max_completions_recv: usize = 64,
    timer_clock: std.Io.Clock = .real,
};

pub const OpenWindowConfig = struct {
    window: WindowConfig,
    renderer: ?renderer.Renderer.Config = null,
    ui: ?UI.Config = null,
};

_impl: *Impl,

const App = @This();

const Impl = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    render_context: *renderer.Context,
    main_viewport: *Viewport,
    viewport: *Viewport,
    secondary_viewports: std.ArrayList(*Viewport),
    next_viewport_id: u32 = 1,
    completion_queue: CompletionQueue,
    cfg: Config,
    running: bool = false,
    frame_event_error: ?anyerror = null,
};

/// `io` is the implementation used by `dispatch`.
/// `allocator` backs each viewport's per-frame arena and persistent state.
pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !App {
    var main_window = try Window.init(io, allocator, cfg.window);
    var main_window_owned = true;
    errdefer if (main_window_owned) main_window.deinit();

    const render_context = try renderer.Context.create(
        allocator,
        main_window.getWindowHandle(),
        cfg.depth_buffer,
    );
    errdefer render_context.destroy();

    var completion_queue: CompletionQueue = try .init(allocator, cfg.max_completions_recv);
    errdefer completion_queue.deinit(allocator, io);

    const main_fb = main_window.getFramebufferSize();
    const main_renderer = try renderer.Renderer.create(
        allocator,
        render_context,
        main_window.getWindowHandle(),
        main_fb.width,
        main_fb.height,
        cfg.renderer,
    );
    var main_renderer_owned = true;
    errdefer if (main_renderer_owned) main_renderer.destroy();

    const main_viewport = try createViewport(allocator, .main, main_window, main_renderer, .{
        .ui = cfg.ui,
        .arena_reset_mode = cfg.arena_reset_mode,
        .timer_clock = cfg.timer_clock,
    });
    main_window_owned = false;
    main_renderer_owned = false;
    errdefer {
        main_viewport.deinit();
        allocator.destroy(main_viewport);
    }

    const impl = try allocator.create(Impl);
    impl.* = .{
        .io = io,
        .allocator = allocator,
        .render_context = render_context,
        .main_viewport = main_viewport,
        .viewport = main_viewport,
        .secondary_viewports = .empty,
        .completion_queue = completion_queue,
        .cfg = cfg,
    };
    return .{ ._impl = impl };
}

fn createViewport(
    allocator: std.mem.Allocator,
    id: Viewport.Id,
    window_value: Window,
    renderer_value: *renderer.Renderer,
    cfg: Viewport.Config,
) !*Viewport {
    const viewport = try allocator.create(Viewport);
    errdefer allocator.destroy(viewport);
    try viewport.init(allocator, id, window_value, renderer_value, cfg);
    return viewport;
}

fn destroyViewport(self: *App, viewport: *Viewport) void {
    viewport.deinit();
    self.implPtr().allocator.destroy(viewport);
}

fn allocateViewportId(self: *App) !Viewport.Id {
    const impl = self.implPtr();
    if (impl.next_viewport_id == 0) return error.TooManyViewports;
    const id = impl.next_viewport_id;
    impl.next_viewport_id +%= 1;
    return @enumFromInt(id);
}

fn viewportForId(self: *App, id: Viewport.Id) ?*Viewport {
    const impl = self.implPtr();
    if (id == .main) return impl.main_viewport;
    for (impl.secondary_viewports.items) |viewport| {
        if (viewport.id == id) return viewport;
    }
    return null;
}

pub fn reconfigureRenderer(self: *App, new_cfg: renderer.Renderer.Config) void {
    self.implPtr().viewport.pending_renderer_cfg = new_cfg;
    self.requestFrame();
}

pub fn deinit(self: *App) void {
    const impl = self.implPtr();
    impl.running = false;
    impl.completion_queue.deinit(impl.allocator, impl.io);
    self.destroySecondaryViewports();
    impl.secondary_viewports.deinit(impl.allocator);
    self.destroyViewport(impl.main_viewport);
    impl.render_context.destroy();
    impl.allocator.destroy(impl);
    self.* = undefined;
}

/// Start a frame-loop that runs until the main window is closed.
///
/// The app's address must remain stable until the loop stops. Embedding `App`
/// in application state lets callbacks recover that state with
/// `@fieldParentPtr` while `Frame` remains host-neutral.
pub fn start(self: *App, frame_cb: RenderFn) !void {
    const impl = self.implPtr();
    if (impl.running) return error.AppAlreadyStarted;
    impl.running = true;
    impl.main_viewport.app = self;
    impl.main_viewport.frame_cb = frame_cb;
    impl.main_viewport.window.startCapture();
    impl.main_viewport.window.setFrameHandler(.{
        .ctx = impl.main_viewport,
        .step = stepFrameHook,
    });
    impl.main_viewport.timer.start(impl.io);
    impl.main_viewport.window.requestFrame();
    impl.main_viewport.window.pollEvents(impl.io);

    if (!platform.is_browser_wasm) {
        defer {
            impl.running = false;
            impl.viewport = impl.main_viewport;
            self.destroySecondaryViewports();
            impl.main_viewport.window.clearFrameHandler();
        }
        try self.takeFrameEventError();
        try self.scheduleCompletions();
        self.sweepClosedViewports();
        while (impl.main_viewport.window.isOpen()) {
            impl.main_viewport.window.waitEvents(impl.io);
            try self.takeFrameEventError();
            try self.scheduleCompletions();
            self.sweepClosedViewports();
        }
    }
}

/// Open an independently scheduled native window.
///
/// All native windows share the render context created for the main window.
/// Secondary windows can fail to open if their surface does not support the
/// main window's selected GPU device or surface format.
/// Returns an id that is stable until that viewport closes.
pub fn openWindow(
    self: *App,
    open_cfg: OpenWindowConfig,
    frame_cb: RenderFn,
) !Viewport.Id {
    const impl = self.implPtr();
    if (!impl.running) return error.AppNotStarted;
    if (platform.is_browser_wasm) return error.UnsupportedPlatform;
    try impl.secondary_viewports.ensureUnusedCapacity(impl.allocator, 1);
    const id = try self.allocateViewportId();

    const current = impl.viewport;
    const viewport = blk: {
        var window_value = try Window.initSecondary(
            &impl.main_viewport.window,
            impl.io,
            impl.allocator,
            open_cfg.window,
        );
        var window_owned = true;
        errdefer if (window_owned) window_value.deinit();

        const secondary_fb = window_value.getFramebufferSize();
        const renderer_value = try renderer.Renderer.create(
            impl.allocator,
            impl.render_context,
            window_value.getWindowHandle(),
            secondary_fb.width,
            secondary_fb.height,
            open_cfg.renderer orelse current.renderer.cfg,
        );
        var renderer_owned = true;
        errdefer if (renderer_owned) renderer_value.destroy();

        const viewport = try createViewport(impl.allocator, id, window_value, renderer_value, .{
            .ui = open_cfg.ui orelse current.ui_cfg,
            .arena_reset_mode = impl.cfg.arena_reset_mode,
            .timer_clock = impl.cfg.timer_clock,
        });
        window_owned = false;
        renderer_owned = false;
        break :blk viewport;
    };

    viewport.app = self;
    viewport.frame_cb = frame_cb;
    viewport.window.startCapture();
    viewport.window.setFrameHandler(.{
        .ctx = viewport,
        .step = stepFrameHook,
    });
    viewport.timer.start(impl.io);
    impl.secondary_viewports.appendAssumeCapacity(viewport);
    viewport.window.requestFrame();
    return id;
}

/// Close the current viewport's window. Closing the main viewport exits the application.
pub fn closeWindow(self: *App) void {
    self.closeViewport(self.implPtr().viewport);
}

fn closeViewport(self: *App, viewport: *Viewport) void {
    if (viewport == self.implPtr().main_viewport)
        self.exitApplication()
    else
        viewport.window.close();
}

pub fn currentViewportId(self: *const App) Viewport.Id {
    return self.implPtrConst().viewport.id;
}

pub fn currentView(self: *App) *View {
    return &self.implPtr().viewport.view;
}

pub fn mainView(self: *App) *View {
    return &self.implPtr().main_viewport.view;
}

pub fn logicalExtent(self: *const App) input_types.Size {
    return self.implPtrConst().viewport.window.getSize();
}

pub fn physicalExtent(self: *const App) input_types.Size {
    return self.implPtrConst().viewport.window.getFramebufferSize();
}

pub fn presentMode(self: *const App) gpu.Context.PresentMode {
    return self.implPtrConst().viewport.renderer.cfg.present_mode;
}

pub fn rendererConfig(self: *const App) renderer.Renderer.Config {
    return self.implPtrConst().viewport.renderer.cfg;
}

pub fn supportedPresentModes(self: *const App) gpu.Context.PresentModes {
    return self.implPtrConst().viewport.renderer.supportedPresentModes();
}

pub fn requestReadback(self: *App, allocator: std.mem.Allocator) !void {
    try self.implPtr().viewport.renderer.requestReadback(allocator);
}

pub fn takeReadback(self: *App) ?gpu.SurfaceReadback {
    return self.implPtr().viewport.renderer.takeReadback();
}

/// Number of `dispatch` calls that have not yet delivered their completion.
pub fn concurrencyInFlight(self: *const App) usize {
    return self.implPtrConst().completion_queue.inFlight();
}

pub fn backingAllocator(self: *const App) std.mem.Allocator {
    return self.implPtrConst().allocator;
}

pub fn ioImplementation(self: *const App) std.Io {
    return self.implPtrConst().io;
}

pub fn requestFrameFor(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse return error.InvalidViewportId;
    viewport.window.requestFrame();
}

pub fn closeWindowById(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse return error.InvalidViewportId;
    self.closeViewport(viewport);
}

/// Frame ordering, per tick:
///  1. `App.beginFrame`: Collects input + routes scroll against the previous frame's tree.
///  2. `frame_cb`: User code.
///  3. `App.endFrame`: TTL sweep, layout, tessellation, hit-testing.
///  4. `renderer.render`: Consume the resulting draw list.
fn renderFrame(self: *App, viewport: *Viewport) !void {
    const impl = self.implPtr();
    viewport.timer.tick(impl.io);

    if (viewport.window.consumeResize()) |ev| {
        if (ev.physical.width == 0 or ev.physical.height == 0) return;
        try viewport.renderer.resize(ev.physical.width, ev.physical.height);
    }
    handleRendererReconfigure(viewport);

    const input = try viewport.window.collectInput();
    defer viewport.window.finishInputFrame();
    const logical = viewport.window.getSize();
    const physical = viewport.window.getFramebufferSize();
    const dropped_paths = try viewport.window.consumeDrops(impl.allocator);
    defer freeDroppedPaths(impl.allocator, dropped_paths);
    // Shares the chord predicate with `text_edit` so the gate cannot drift from
    // what actually consumes the text.
    const paste_text = if (input_types.pasteRequested(input.key_events))
        try viewport.window.getClipboardText(impl.allocator)
    else
        null;
    defer if (paste_text) |value| impl.allocator.free(value);

    var frame = try viewport.view.beginFrame(.{
        .input = input,
        .now_ms = viewport.timer.ms(),
        .delta_ns = @intCast(@max(0, viewport.timer.delta.nanoseconds)),
        .logical_extent = logical,
        .physical_extent = physical,
        .content_scale = viewport.window.getContentScale(),
        .paste_text = paste_text,
        .dropped_paths = dropped_paths,
    });
    errdefer viewport.view.abortFrame(&frame) catch {};
    viewport.active_frame = &frame;
    defer viewport.active_frame = null;

    try self.consumeCompletions(viewport);

    try @call(.auto, viewport.frame_cb.?, .{ self, &frame });
    if (!viewport.window.isOpen()) {
        try viewport.view.abortFrame(&frame);
        return;
    }

    const output = try viewport.view.endRendererFrame(&frame);
    viewport.window.setCursorShape(output.cursor_shape);
    if (output.clipboard_write) |value| {
        _ = try viewport.window.setClipboardText(impl.allocator, value);
    }
    if (output.close) {
        self.closeViewport(viewport);
        return;
    }

    switch (viewport.renderer.render(output.draw_list, output.glyph_builder, viewport.window.getContentScale())) {
        .success => {},
        .callback_error => |err| return err,
        .renderer_error => |err| switch (err) {
            error.SurfaceUnavailable => return,
            else => return err,
        },
    }

    if (output.redraw) viewport.window.requestFrame();
}

fn stepFrame(self: *App, viewport: *Viewport) !void {
    if (viewport.frame_cb == null) return error.AppNotStarted;
    if (viewport.frame_active) {
        viewport.frame_pending = true;
        return;
    }

    const impl = self.implPtr();
    const previous = impl.viewport;
    impl.viewport = viewport;
    defer impl.viewport = previous;

    viewport.frame_active = true;
    defer viewport.frame_active = false;

    try self.renderFrame(viewport);
    while (viewport.frame_pending) {
        viewport.frame_pending = false;
        try self.renderFrame(viewport);
    }
}

fn takeFrameEventError(self: *App) !void {
    const impl = self.implPtr();
    if (impl.frame_event_error) |err| {
        impl.frame_event_error = null;
        return err;
    }
}

fn consumeCompletions(self: *App, viewport: *Viewport) !void {
    const impl = self.implPtr();
    try impl.completion_queue.consumeFor(self, impl.io, viewport.id, runCompletion);
}

fn scheduleCompletions(self: *App) !void {
    const impl = self.implPtr();
    try impl.completion_queue.receive(impl.io);
    if (impl.completion_queue.hasPendingFor(.main)) {
        impl.main_viewport.window.requestFrame();
    }
    for (impl.secondary_viewports.items) |viewport| {
        if (impl.completion_queue.hasPendingFor(viewport.id)) {
            viewport.window.requestFrame();
        }
    }
}

fn runCompletion(
    self: *App,
    viewport_id: Viewport.Id,
    callback: CompletionQueue.OpaqueCallback,
    context: *anyopaque,
) !void {
    const viewport = self.viewportForId(viewport_id) orelse return;
    if (!viewport.window.isOpen()) return;
    const impl = self.implPtr();
    const previous = impl.viewport;
    impl.viewport = viewport;
    defer impl.viewport = previous;

    const frame = viewport.active_frame orelse return error.FrameNotActive;
    try callback(self, frame, context);
    if (viewport.frame_active) return;
    if (viewport.window.isOpen()) viewport.window.requestFrame();
}

fn exitApplication(self: *App) void {
    const impl = self.implPtr();
    impl.main_viewport.window.close();
    for (impl.secondary_viewports.items) |viewport| viewport.window.close();
}

fn sweepClosedViewports(self: *App) void {
    const impl = self.implPtr();
    var i: usize = 0;
    while (i < impl.secondary_viewports.items.len) {
        const viewport = impl.secondary_viewports.items[i];
        if (viewport.window.isOpen()) {
            i += 1;
            continue;
        }
        _ = impl.secondary_viewports.swapRemove(i);
        impl.completion_queue.dropPendingFor(viewport.id);
        self.destroyViewport(viewport);
    }
}

fn destroySecondaryViewports(self: *App) void {
    const impl = self.implPtr();
    while (impl.secondary_viewports.pop()) |viewport| self.destroyViewport(viewport);
}

fn stepFrameHook(ctx: *anyopaque) void {
    const viewport: *Viewport = @ptrCast(@alignCast(ctx));
    const self = viewport.app orelse return;
    if (self.implPtr().frame_event_error != null) return;
    self.stepFrame(viewport) catch |err| {
        self.reportFrameHookError(err);
        return;
    };
}

fn reportFrameHookError(self: *App, err: anyerror) void {
    const impl = self.implPtr();
    impl.frame_event_error = err;
    if (platform.is_browser_wasm) {
        impl.main_viewport.window.clearFrameHandler();
        browser_exports.reportFatalError(err);
        return;
    }
    impl.main_viewport.window.postEmptyEvent();
}

/// Schedule the current viewport from code that runs outside its frame callback.
/// Inside a callback, use `Frame.requestRedraw` so the request is part of output.
pub fn requestFrame(self: *App) void {
    self.implPtr().viewport.window.requestFrame();
}

/// Returns the backend-neutral GPU context shared by all viewports.
pub fn gpuContext(self: *App) renderer.gpu.Context {
    return .{ .inner = self.implPtr().render_context };
}

/// Dispatch a function using the `Io` implementation provided in `init`.
///
/// `onComplete` runs on the main thread with the viewport that called
/// `dispatch` active. The callback is discarded if that viewport closes.
pub fn dispatch(
    self: *App,
    func: anytype,
    args: anytype,
    onComplete: CompletionQueue.Callback(App, ReturnType(func)),
) !void {
    const impl = self.implPtr();
    try impl.completion_queue.dispatch(
        App,
        impl.io,
        impl.allocator,
        func,
        args,
        onComplete,
        impl.viewport.id,
        .{ .context = &impl.main_viewport.window, .notify = wakeCompletion },
    );
}

fn wakeCompletion(context: *anyopaque) void {
    const main_window: *Window = @ptrCast(@alignCast(context));
    main_window.postEmptyEvent();
}

pub fn consumeReconfigure(self: *App) bool {
    const viewport = self.implPtr().viewport;
    const value = viewport.pending_reconfigure;
    viewport.pending_reconfigure = false;
    return value;
}

pub fn rendererReconfigureError(self: *const App) ?renderer.Renderer.ReconfigureError {
    return self.implPtrConst().viewport.renderer_reconfigure_error;
}

fn implPtr(self: *App) *Impl {
    return self._impl;
}

fn implPtrConst(self: *const App) *const Impl {
    return self._impl;
}

fn handleRendererReconfigure(viewport: *Viewport) void {
    const new_cfg = viewport.pending_renderer_cfg orelse return;
    viewport.pending_renderer_cfg = null;

    viewport.renderer.reconfigure(new_cfg) catch |err| {
        viewport.renderer_reconfigure_error = err;
        return;
    };

    viewport.renderer_reconfigure_error = null;
    viewport.view.markGlyphsDirty();
    viewport.pending_reconfigure = true;
}

fn freeDroppedPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    if (paths.len == 0) return;
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}
