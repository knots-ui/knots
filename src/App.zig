const std = @import("std");
const gpu = @import("gpu");

const input_types = @import("input");
const browser_exports = @import("browser_exports");
const renderer = @import("renderer");
const window = @import("window");
const platform = @import("platform.zig");

const Window = window.Window;
const WindowConfig = window.Config;
const UI = @import("ui").UI;
const Frame = @import("ui").Frame;

const CompletionQueue = @import("CompletionQueue.zig");
const ReturnType = @import("util.zig").ReturnType;

const Viewport = @import("Viewport.zig");
const View = @import("View.zig");

const App = @This();

pub const RenderFn = *const fn (*View, *Frame) anyerror!void;

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

io: std.Io,
allocator: std.mem.Allocator,
render_context: *renderer.Context,
main_viewport: *Viewport,
secondary_viewports: std.ArrayList(*Viewport) = .empty,
completion_queue: CompletionQueue,
cfg: Config,

next_viewport_id: u32 = 1,
running: bool = false,
frame_event_error: ?anyerror = null,

/// `io` is used by dispatch and the window backend.
/// `allocator` backs persistent application/viewport state.
pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !App {
    var main_window = try Window.init(
        io,
        allocator,
        cfg.window,
    );
    var main_window_owned = true;
    errdefer if (main_window_owned) main_window.deinit();

    const render_context = try renderer.Context.create(
        allocator,
        main_window.getWindowHandle(),
        cfg.depth_buffer,
    );
    errdefer render_context.destroy();

    var completion_queue: CompletionQueue = try .init(
        allocator,
        cfg.max_completions_recv,
    );
    errdefer completion_queue.deinit(allocator, io);

    const framebuffer = main_window.getFramebufferSize();

    const main_renderer = try renderer.Renderer.create(
        allocator,
        render_context,
        main_window.getWindowHandle(),
        framebuffer.width,
        framebuffer.height,
        cfg.renderer,
    );
    var main_renderer_owned = true;
    errdefer if (main_renderer_owned) main_renderer.destroy();

    const main_viewport = try Viewport.create(
        allocator,
        .main,
        main_window,
        main_renderer,
        .{
            .ui = cfg.ui,
            .arena_reset_mode = cfg.arena_reset_mode,
            .timer_clock = cfg.timer_clock,
        },
    );

    main_window_owned = false;
    main_renderer_owned = false;

    errdefer main_viewport.destroy(allocator);

    return .{
        .io = io,
        .allocator = allocator,
        .render_context = render_context,
        .main_viewport = main_viewport,
        .completion_queue = completion_queue,
        .cfg = cfg,
    };
}

pub fn deinit(self: *App) void {
    self.running = false;

    self.completion_queue.deinit(
        self.allocator,
        self.io,
    );

    self.destroySecondaryViewports();
    self.secondary_viewports.deinit(self.allocator);

    self.main_viewport.destroy(self.allocator);
    self.render_context.destroy();

    self.* = undefined;
}

/// Start the main application frame loop.
///
/// `App` must remain at a stable address until this returns because viewports
/// retain a pointer to it for their frame handlers.
pub fn start(self: *App, frame_cb: RenderFn) !void {
    if (self.running)
        return error.AppAlreadyStarted;

    self.running = true;
    self.startViewport(self.main_viewport, frame_cb);

    self.main_viewport.window.pollEvents(self.io);

    if (platform.is_browser_wasm)
        return;

    defer {
        self.running = false;
        self.destroySecondaryViewports();
        self.main_viewport.window.clearFrameHandler();
    }

    try self.takeFrameEventError();
    try self.scheduleCompletions();
    self.sweepClosedViewports();

    while (self.main_viewport.window.isOpen()) {
        self.main_viewport.window.waitEvents(self.io);

        try self.takeFrameEventError();
        try self.scheduleCompletions();

        self.sweepClosedViewports();
    }
}

/// Open another native window.
///
/// `source_id` controls which viewport's renderer/UI configuration is inherited
/// when an override is not supplied.
pub fn openWindow(self: *App, source_id: Viewport.Id, cfg: OpenWindowConfig, frame_cb: RenderFn) !Viewport.Id {
    if (!self.running)
        return error.AppNotStarted;

    if (platform.is_browser_wasm)
        return error.UnsupportedPlatform;

    const source = self.viewportForId(source_id) orelse
        return error.InvalidViewportId;

    try self.secondary_viewports.ensureUnusedCapacity(
        self.allocator,
        1,
    );

    const id = try self.allocateViewportId();

    const viewport = try Viewport.createSecondary(
        self.allocator,
        self.io,
        self.render_context,
        &self.main_viewport.window,
        id,
        cfg.window,
        cfg.renderer orelse source.renderer.cfg,
        .{
            .ui = cfg.ui orelse source.ui_cfg,
            .arena_reset_mode = self.cfg.arena_reset_mode,
            .timer_clock = self.cfg.timer_clock,
        },
    );

    self.secondary_viewports.appendAssumeCapacity(viewport);
    self.startViewport(viewport, frame_cb);

    return id;
}

/// Close a viewport.
///
/// Closing the main viewport terminates the application and closes every
/// secondary viewport.
pub fn closeWindow(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse
        return error.InvalidViewportId;

    self.closeViewport(viewport);
}

/// Schedule a viewport from code running outside its frame callback.
///
/// During a frame callback, prefer `Frame.requestRedraw()`.
pub fn requestFrame(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse
        return error.InvalidViewportId;

    viewport.window.requestFrame();
}

/// Queue a renderer change for the next frame of a viewport.
pub fn reconfigureRenderer(self: *App, id: Viewport.Id, cfg: renderer.Renderer.Config) !void {
    const viewport = self.viewportForId(id) orelse
        return error.InvalidViewportId;

    viewport.reconfigureRenderer(cfg);
}

/// Request a surface readback for the next rendered frame of a viewport.
pub fn requestReadback(self: *App, id: Viewport.Id, allocator: std.mem.Allocator) !void {
    const viewport = self.viewportForId(id) orelse
        return error.InvalidViewportId;

    try viewport.renderer.requestReadback(allocator);
}

/// Take ownership of a completed readback, if one is available.
pub fn takeReadback(self: *App, id: Viewport.Id) !?gpu.SurfaceReadback {
    const viewport = self.viewportForId(id) orelse
        return error.InvalidViewportId;

    return viewport.renderer.takeReadback();
}

/// Dispatch asynchronous work associated with a specific viewport.
///
/// The completion executes on the main thread while that viewport has an
/// active UI frame. If the viewport has been destroyed, the completion is
/// discarded.
pub fn dispatch(
    self: *App,
    viewport_id: Viewport.Id,
    func: anytype,
    args: anytype,
    onComplete: CompletionQueue.Callback(View, ReturnType(func)),
) !void {
    const viewport = self.viewportForId(viewport_id) orelse
        return error.InvalidViewportId;

    try self.completion_queue.dispatch(
        View,
        self.io,
        self.allocator,
        func,
        args,
        onComplete,
        viewport.id,
        .{
            .context = &self.main_viewport.window,
            .notify = wakeCompletion,
        },
    );
}

/// Number of dispatched operations whose completion has not yet been delivered.
pub fn concurrencyInFlight(self: *const App) usize {
    return self.completion_queue.inFlight();
}

/// Backend-neutral GPU context shared by every viewport.
pub fn gpuContext(self: *App) renderer.gpu.Context {
    return .{
        .inner = self.render_context,
    };
}

fn viewForViewport(self: *App, viewport: *Viewport) View {
    std.debug.assert(viewport.app == self);
    return .{
        .app = self,
        .id = viewport.id,
        .renderer = .{
            .config = viewport.renderer.cfg,
            .supported_present_modes = viewport.renderer.supportedPresentModes(),
            .reconfigure_error = viewport.renderer_reconfigure_error,
        },
    };
}

fn startViewport(self: *App, viewport: *Viewport, frame_cb: RenderFn) void {
    viewport.app = self;
    viewport.frame_cb = frame_cb;

    viewport.window.startCapture();

    viewport.window.setFrameHandler(.{
        .ctx = viewport,
        .step = stepFrameHook,
    });

    viewport.timer.start(self.io);
    viewport.window.requestFrame();
}

fn renderFrame(
    self: *App,
    viewport: *Viewport,
) !void {
    viewport.timer.tick(self.io);

    if (viewport.window.consumeResize()) |event| {
        if (event.physical.width == 0 or
            event.physical.height == 0)
        {
            return;
        }

        try viewport.renderer.resize(
            event.physical.width,
            event.physical.height,
        );
    }

    viewport.applyRendererReconfigure();

    const input = try viewport.window.collectInput();
    defer viewport.window.finishInputFrame();

    const dropped_paths = try viewport.window.consumeDrops(
        self.allocator,
    );
    defer freeDroppedPaths(
        self.allocator,
        dropped_paths,
    );

    const paste_text = if (input_types.pasteRequested(input.key_events))
        try viewport.window.getClipboardText(self.allocator)
    else
        null;
    defer if (paste_text) |text| self.allocator.free(text);

    var frame = try viewport.ui_ctx.beginFrame(.{
        .input = input,
        .now_ms = viewport.timer.ms(),
        .delta_ns = @intCast(
            @max(
                0,
                viewport.timer.delta.nanoseconds,
            ),
        ),
        .logical_extent = viewport.window.getSize(),
        .physical_extent = viewport.window.getFramebufferSize(),
        .content_scale = viewport.window.getContentScale(),
        .paste_text = paste_text,
        .dropped_paths = dropped_paths,
    });
    defer frame.deinit();

    viewport.active_frame = &frame;
    defer viewport.active_frame = null;

    try self.consumeCompletions(viewport);

    var view = self.viewForViewport(viewport);

    try viewport.frame_cb.?(
        &view,
        &frame,
    );

    if (!viewport.window.isOpen()) {
        try viewport.ui_ctx.abortFrame(&frame);
        return;
    }

    const output = try viewport.ui_ctx.endFrame(&frame);

    viewport.window.setCursorShape(
        output.cursor_shape,
    );

    if (output.clipboard_write) |text| {
        _ = try viewport.window.setClipboardText(
            self.allocator,
            text,
        );
    }

    if (output.close) {
        self.closeViewport(viewport);
        return;
    }

    switch (viewport.renderer.render(
        &output.packet,
        viewport.window.getContentScale(),
    )) {
        .success => {},

        .callback_error => |err| return err,

        .renderer_error => |err| switch (err) {
            error.SurfaceUnavailable => return,
            else => return err,
        },
    }

    if (output.redraw)
        viewport.window.requestFrame();
}

fn stepFrame(self: *App, viewport: *Viewport) !void {
    if (viewport.frame_cb == null)
        return error.AppNotStarted;

    if (viewport.frame_active) {
        viewport.frame_pending = true;
        return;
    }

    viewport.frame_active = true;
    defer viewport.frame_active = false;

    try self.renderFrame(viewport);

    while (viewport.frame_pending) {
        viewport.frame_pending = false;
        try self.renderFrame(viewport);
    }
}

fn consumeCompletions(self: *App, viewport: *Viewport) !void {
    try self.completion_queue.consumeFor(
        self,
        self.io,
        viewport.id,
        runCompletion,
    );
}

fn scheduleCompletions(self: *App) !void {
    try self.completion_queue.receive(self.io);

    if (self.completion_queue.hasPendingFor(.main))
        self.main_viewport.window.requestFrame();

    for (self.secondary_viewports.items) |viewport| {
        if (self.completion_queue.hasPendingFor(viewport.id))
            viewport.window.requestFrame();
    }
}

fn runCompletion(
    self: *App,
    viewport_id: Viewport.Id,
    callback: CompletionQueue.OpaqueCallback,
    context: *anyopaque,
) !void {
    const viewport = self.viewportForId(viewport_id) orelse
        return;

    if (!viewport.window.isOpen())
        return;

    const frame = viewport.active_frame orelse
        return error.FrameNotActive;

    var view = self.viewForViewport(viewport);

    try callback(
        &view,
        frame,
        context,
    );

    if (!viewport.frame_active and
        viewport.window.isOpen())
    {
        viewport.window.requestFrame();
    }
}

fn allocateViewportId(self: *App) !Viewport.Id {
    if (self.next_viewport_id == 0)
        return error.TooManyViewports;

    const id = self.next_viewport_id;
    self.next_viewport_id +%= 1;

    return @fromBackingInt(@intCast(id));
}

fn viewportForId(self: *const App, id: Viewport.Id) ?*Viewport {
    if (id == .main)
        return self.main_viewport;

    for (self.secondary_viewports.items) |viewport| {
        if (viewport.id == id)
            return viewport;
    }

    return null;
}

fn closeViewport(self: *App, viewport: *Viewport) void {
    if (viewport == self.main_viewport) {
        self.exitApplication();
        return;
    }

    viewport.window.close();
}

fn exitApplication(self: *App) void {
    self.main_viewport.window.close();

    for (self.secondary_viewports.items) |viewport|
        viewport.window.close();
}

fn sweepClosedViewports(self: *App) void {
    var i: usize = 0;

    while (i < self.secondary_viewports.items.len) {
        const viewport = self.secondary_viewports.items[i];

        if (viewport.window.isOpen()) {
            i += 1;
            continue;
        }

        _ = self.secondary_viewports.swapRemove(i);

        self.completion_queue.dropPendingFor(
            viewport.id,
        );

        viewport.destroy(self.allocator);
    }
}

fn destroySecondaryViewports(self: *App) void {
    while (self.secondary_viewports.pop()) |viewport|
        viewport.destroy(self.allocator);
}

fn takeFrameEventError(self: *App) !void {
    if (self.frame_event_error) |err| {
        self.frame_event_error = null;
        return err;
    }
}

fn stepFrameHook(context: *anyopaque) void {
    const viewport: *Viewport = @ptrCast(
        @alignCast(context),
    );

    const self = viewport.app orelse
        return;

    if (self.frame_event_error != null)
        return;

    self.stepFrame(viewport) catch |err| {
        self.reportFrameHookError(err);
    };
}

fn reportFrameHookError(self: *App, err: anyerror) void {
    self.frame_event_error = err;

    if (platform.is_browser_wasm) {
        self.main_viewport.window.clearFrameHandler();
        browser_exports.reportFatalError(err);
        return;
    }

    self.main_viewport.window.postEmptyEvent();
}

fn wakeCompletion(context: *anyopaque) void {
    const main_window: *Window = @ptrCast(
        @alignCast(context),
    );

    main_window.postEmptyEvent();
}

fn freeDroppedPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path|
        allocator.free(path);

    allocator.free(paths);
}
