const std = @import("std");
const browser_exports = @import("browser_exports");

const render = @import("render");
const window = @import("window");
const Window = window.Window;
const WindowConfig = window.Config;
const UI = @import("ui").UI;

const CompletionQueue = @import("CompletionQueue.zig");
const ReturnType = @import("util.zig").ReturnType;
const Viewport = @import("Viewport.zig");
const platform = @import("platform.zig");

pub const Callback = *const fn (*App) anyerror!void;

pub const Config = struct {
    window: WindowConfig,
    renderer: render.Renderer.Config = .{},
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
    max_completions_recv: usize = 64,
    timer_clock: std.Io.Clock = .real,
};

pub const OpenWindowConfig = struct {
    window: WindowConfig,
    renderer: ?render.Renderer.Config = null,
    ui: ?UI.Config = null,
};

io: std.Io,
allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
renderer_group: *render.RendererGroup,
main_viewport: *Viewport,
viewport: *Viewport,
secondary_viewports: std.ArrayList(*Viewport),
next_viewport_id: u32 = 1,
completion_queue: CompletionQueue,
cfg: Config,
running: bool = false,
frame_event_error: ?anyerror = null,

const App = @This();

/// The `io` parameter will be the underlying `Io` implementation used when calling `dispatch`.
/// The `allocator` parameter will be used as the backing allocator to the per-frame arena.
pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !App {
    var main_window = try Window.init(io, allocator, cfg.window);
    var main_window_owned = true;
    errdefer if (main_window_owned) main_window.deinit();

    const renderer_group = try allocator.create(render.RendererGroup);
    errdefer allocator.destroy(renderer_group);
    renderer_group.* = try render.RendererGroup.init(allocator, &main_window);
    errdefer renderer_group.deinit();

    var completion_queue: CompletionQueue = try .init(allocator, cfg.max_completions_recv);
    errdefer completion_queue.deinit(allocator, io);

    var main_renderer: render.Renderer = try .init(allocator, renderer_group, &main_window, cfg.renderer);
    var main_renderer_owned = true;
    errdefer if (main_renderer_owned) main_renderer.deinit();

    const main_viewport = try createViewport(allocator, .main, main_window, main_renderer, .{
        .ui = cfg.ui,
        .timer_clock = cfg.timer_clock,
    });
    main_window_owned = false;
    main_renderer_owned = false;
    errdefer {
        main_viewport.deinit();
        allocator.destroy(main_viewport);
    }

    return .{
        .io = io,
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .renderer_group = renderer_group,
        .main_viewport = main_viewport,
        .viewport = main_viewport,
        .secondary_viewports = .empty,
        .completion_queue = completion_queue,
        .cfg = cfg,
    };
}

fn createViewport(allocator: std.mem.Allocator, id: Viewport.Id, window_value: Window, renderer: render.Renderer, cfg: Viewport.Config) !*Viewport {
    const viewport = try allocator.create(Viewport);
    errdefer allocator.destroy(viewport);
    viewport.* = try .init(allocator, id, window_value, renderer, cfg);
    return viewport;
}

fn destroyViewport(self: *App, viewport: *Viewport) void {
    viewport.deinit();
    self.allocator.destroy(viewport);
}

fn allocateViewportId(self: *App) !Viewport.Id {
    if (self.next_viewport_id == 0) return error.TooManyViewports;
    const id = self.next_viewport_id;
    self.next_viewport_id +%= 1;
    return @enumFromInt(id);
}

fn viewportForId(self: *App, id: Viewport.Id) ?*Viewport {
    if (id == .main) return self.main_viewport;
    for (self.secondary_viewports.items) |viewport| {
        if (viewport.id == id) return viewport;
    }
    return null;
}

pub fn reconfigureRenderer(self: *App, new_cfg: render.Renderer.Config) void {
    self.viewport.pending_renderer_cfg = new_cfg;
    self.requestFrame();
}

pub fn deinit(self: *App) void {
    self.running = false;
    self.completion_queue.deinit(self.allocator, self.io);
    self.destroySecondaryViewports();
    self.secondary_viewports.deinit(self.allocator);
    self.frame_arena.deinit();
    self.destroyViewport(self.main_viewport);
    self.renderer_group.deinit();
    self.allocator.destroy(self.renderer_group);
}

/// Start a frame-loop that runs until the main window is closed.
pub fn start(self: *App, frame_cb: Callback) !void {
    if (self.running) return error.AppAlreadyStarted;
    self.running = true;
    self.main_viewport.app = self;
    self.main_viewport.frame_cb = frame_cb;
    self.main_viewport.window.startCapture();
    self.main_viewport.window.setFrameHandler(.{
        .ctx = self.main_viewport,
        .step = stepFrameHook,
    });
    self.main_viewport.timer.start(self.io);
    self.main_viewport.window.requestFrame();
    self.main_viewport.window.pollEvents(self.io);

    if (!platform.is_browser_wasm) {
        defer {
            self.running = false;
            self.viewport = self.main_viewport;
            self.destroySecondaryViewports();
            self.main_viewport.window.clearFrameHandler();
        }
        try self.takeFrameEventError();
        try self.renderer_group.sweepSharedCaches();
        self.sweepClosedViewports();
        while (self.main_viewport.window.isOpen()) {
            self.main_viewport.window.waitEvents(self.io);
            try self.takeFrameEventError();
            try self.renderer_group.sweepSharedCaches();
            self.sweepClosedViewports();
        }
    }
}

/// Open an independently scheduled native window.
///
/// All native windows share the renderer group created for the main window.
/// Secondary windows can fail to open if their surface does not support the
/// main window's selected GPU device or surface format.
/// Returns an id that is stable until that viewport closes.
pub fn openWindow(self: *App, open_cfg: OpenWindowConfig, frame_cb: Callback) !Viewport.Id {
    if (!self.running) return error.AppNotStarted;
    if (platform.is_browser_wasm) return error.UnsupportedPlatform;
    try self.secondary_viewports.ensureUnusedCapacity(self.allocator, 1);
    const id = try self.allocateViewportId();

    const current = self.viewport;
    const viewport = blk: {
        var window_value = try Window.initSecondary(&self.main_viewport.window, self.io, self.allocator, open_cfg.window);
        var window_owned = true;
        errdefer if (window_owned) window_value.deinit();

        var renderer: render.Renderer = try .init(self.allocator, self.renderer_group, &window_value, open_cfg.renderer orelse current.renderer.cfg);
        var renderer_owned = true;
        errdefer if (renderer_owned) renderer.deinit();

        const viewport = try createViewport(self.allocator, id, window_value, renderer, .{
            .ui = open_cfg.ui orelse current.ui_cfg,
            .timer_clock = self.cfg.timer_clock,
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
    viewport.timer.start(self.io);
    self.secondary_viewports.appendAssumeCapacity(viewport);
    viewport.window.requestFrame();
    return id;
}

/// Close the current viewport's window. Closing the main viewport exits the application.
pub fn closeWindow(self: *App) void {
    if (self.viewport == self.main_viewport)
        self.exitApplication()
    else
        self.viewport.window.close();
}

pub fn currentViewportId(self: *const App) Viewport.Id {
    return self.viewport.id;
}

pub fn requestFrameFor(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse return error.InvalidViewportId;
    viewport.window.requestFrame();
}

pub fn closeWindowById(self: *App, id: Viewport.Id) !void {
    const viewport = self.viewportForId(id) orelse return error.InvalidViewportId;
    if (viewport == self.main_viewport)
        self.exitApplication()
    else
        viewport.window.close();
}

/// Frame ordering, per tick:
///  1. `resolveWindow`: Collects input + routes scroll against the previous frame's tree.
///  2. `reset`: Clears the layout pool / decoration list.
///  3. `frame_cb`: User code.
///  4. `endFrame`: TTL sweep over per-widget state.
///  5. `resolve` |> `tessellate` |> `resolveHit`: compute layout, build draw list, hit-test against the new tree.
fn renderFrame(self: *App, viewport: *Viewport) !void {
    defer _ = self.frame_arena.reset(self.cfg.arena_reset_mode);

    viewport.timer.tick(self.io);

    if (viewport.window.consumeResize()) |ev| {
        if (ev.physical.width == 0 or ev.physical.height == 0) return;
        try viewport.renderer.resize(ev.physical.width, ev.physical.height);
    }
    handleRendererReconfigure(viewport);

    const input = try viewport.window.collectInput();
    defer viewport.window.finishInputFrame();
    try viewport.ui.resolveWindow(input, viewport.timer.ms(), viewport.window.getContentScale());
    viewport.ui.reset();

    try self.consumeGlobalCompletions();

    try @call(.auto, viewport.frame_cb.?, .{self});
    if (!viewport.window.isOpen()) return;

    try viewport.ui.endFrame(&viewport.window);

    try viewport.ui.resolve();
    const draw_list = viewport.renderer.beginFrame();
    try viewport.ui.tessellate(self.frame_arena.allocator(), draw_list);
    const hover_changed = viewport.ui.resolveHit();
    viewport.renderer.endFrame(viewport.ui.font.glyph_builder, viewport.ui.content_scale) catch |err| switch (err) {
        error.SurfaceUnavailable => return,
        else => return err,
    };

    if (hover_changed or viewport.ui.anim_active) viewport.window.requestFrame();
}

fn stepFrame(self: *App, viewport: *Viewport) !void {
    if (viewport.frame_cb == null) return error.AppNotStarted;
    if (viewport.frame_active) {
        viewport.frame_pending = true;
        return;
    }

    const previous = self.viewport;
    self.viewport = viewport;
    defer self.viewport = previous;

    viewport.frame_active = true;
    defer viewport.frame_active = false;

    try self.renderFrame(viewport);
    while (viewport.frame_pending) {
        viewport.frame_pending = false;
        try self.renderFrame(viewport);
    }
}

fn takeFrameEventError(self: *App) !void {
    if (self.frame_event_error) |err| {
        self.frame_event_error = null;
        return err;
    }
}

fn consumeGlobalCompletions(self: *App) !void {
    const previous = self.viewport;
    self.viewport = self.main_viewport;
    defer self.viewport = previous;
    try self.completion_queue.consume(self, self.io);
}

fn exitApplication(self: *App) void {
    self.main_viewport.window.close();
    for (self.secondary_viewports.items) |viewport| viewport.window.close();
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
        self.destroyViewport(viewport);
    }
}

fn destroySecondaryViewports(self: *App) void {
    while (self.secondary_viewports.pop()) |viewport| self.destroyViewport(viewport);
}

fn stepFrameHook(ctx: *anyopaque) void {
    const viewport: *Viewport = @ptrCast(@alignCast(ctx));
    const self = viewport.app orelse return;
    if (self.frame_event_error != null) return;
    self.stepFrame(viewport) catch |err| {
        self.reportFrameHookError(err);
        return;
    };
    if (platform.is_browser_wasm)
        self.renderer_group.sweepSharedCaches() catch |err| self.reportFrameHookError(err);
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

/// Request another frame for the currently rendering viewport.
pub inline fn requestFrame(self: *App) void {
    self.viewport.window.requestFrame();
}

/// Returns an arena allocator that is safe to use during the frame callback.
/// The arena is freed at the end of the frame.
pub inline fn arena(self: *App) std.mem.Allocator {
    return self.frame_arena.allocator();
}

/// Dispatch a function to be executed using the `Io` implementation provided in init.
/// `onComplete` will be called when the function is complete with the return type of `func`.
pub inline fn dispatch(self: *App, func: anytype, args: anytype, onComplete: CompletionQueue.Callback(ReturnType(func))) !void {
    try self.completion_queue.dispatch(self.io, self.allocator, func, args, onComplete);
}

pub fn consumeReconfigure(self: *App) bool {
    const viewport = self.viewport;
    const value = viewport.pending_reconfigure;
    viewport.pending_reconfigure = false;
    return value;
}

pub fn rendererReconfigureError(self: *const App) ?render.Renderer.ReconfigureError {
    return self.viewport.renderer_reconfigure_error;
}

fn handleRendererReconfigure(viewport: *Viewport) void {
    const new_cfg = viewport.pending_renderer_cfg orelse return;
    viewport.pending_renderer_cfg = null;

    viewport.renderer.reconfigure(new_cfg) catch |err| {
        viewport.renderer_reconfigure_error = err;
        return;
    };

    viewport.renderer_reconfigure_error = null;
    viewport.ui.font.glyph_builder.markAllDirty();
    viewport.pending_reconfigure = true;
}

/// Register a component tree to be rendered in the UI.
///
/// - `T` with `eval` method                -> control flow (eval)
/// - `T` or `*const T` with open/close     -> leaf (open + close)
/// - `T` or `*const T` followed by tuple   -> parent + children
/// - bare tuple                            -> fragment (recurse)
/// - function                              -> function component
/// - struct with `render` method           -> bound component
pub fn e(self: *App, tree: anytype) !void {
    const T = @TypeOf(tree);
    if (comptime isControlFlow(T)) {
        try tree.eval(self);
    } else if (comptime isComponent(T)) {
        _ = try tree.open(self);
        try tree.close(self);
    } else switch (@typeInfo(T)) {
        .@"fn" => try @call(.always_inline, tree, .{self}),
        .@"struct" => |s| if (comptime isRenderable(T))
            try tree.render(self)
        else {
            comptime var i: usize = 0;
            inline while (i < s.field_names.len) : (i += 1) {
                const val = @field(tree, s.field_names[i]);
                if (comptime isComponent(@TypeOf(val)) and i + 1 < s.field_names.len and isChildren(s.field_types[i + 1])) {
                    const id = try val.open(self);
                    if (id != UI.INVALID_ID)
                        try self.e(@field(tree, s.field_names[i + 1]));
                    try val.close(self);
                    i += 1;
                } else try self.e(val);
            }
        },
        else => @compileError("unexpected type in component tree: " ++ @typeName(T)),
    }
}

fn isControlFlow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "eval"),
        else => false,
    };
}

fn isComponent(comptime T: type) bool {
    const S = switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |p| p.child,
        else => return false,
    };
    return @hasDecl(S, "open") and @hasDecl(S, "close");
}

fn isRenderable(comptime T: type) bool {
    if (!@hasDecl(T, "render")) return false;
    return @TypeOf(T.render) == fn (*const T, *App) anyerror!void;
}

fn isChildren(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}
