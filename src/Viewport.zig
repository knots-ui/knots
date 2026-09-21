const std = @import("std");

const render = @import("renderer");
const UI = @import("ui").UI;
const Frame = @import("ui").Frame;
const Context = @import("ui").Context;

const Window = @import("window").Window;
const WindowConfig = @import("window").Config;

const App = @import("App.zig");
const Timer = @import("Timer.zig");
const NativeAccessibility = if (@import("platform.zig").is_browser_wasm) void else @import("native_accessibility");

const Viewport = @This();

pub const Id = enum(u32) {
    main = 0,
    _,
};

pub const Config = struct {
    ui: UI.Config,
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode,
    timer_clock: std.Io.Clock,
    accessibility: bool = true,
};

app: ?*App = null,

id: Id,
window: Window,
ui_ctx: Context,
renderer: *render.Renderer,
overlay_painter: *render.Painter,
timer: Timer,
ui_cfg: UI.Config,

frame_cb: ?App.RenderFn = null,
active_frame: ?*Frame = null,

pending_renderer_cfg: ?render.Renderer.Config = null,
pending_reconfigure: bool = false,
renderer_reconfigure_error: ?render.Renderer.ReconfigureError = null,

frame_active: bool = false,
frame_pending: bool = false,
contribution_painters: std.AutoHashMapUnmanaged(u64, *render.Painter) = .empty,
accessibility: ?*NativeAccessibility = null,

fn init(self: *Viewport, allocator: std.mem.Allocator, id: Id, window_value: Window, renderer_value: *render.Renderer, cfg: Config) !void {
    var ui_ctx = try Context.init(allocator, .{ .ui = cfg.ui, .arena_reset_mode = cfg.arena_reset_mode });
    errdefer ui_ctx.deinit();

    const overlay_painter = try renderer_value.createLayerPainter();
    errdefer overlay_painter.destroyAfterWait();

    self.* = .{
        .id = id,
        .window = window_value,
        .ui_ctx = ui_ctx,
        .renderer = renderer_value,
        .overlay_painter = overlay_painter,
        .timer = .init(cfg.timer_clock),
        .ui_cfg = cfg.ui,
    };
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    id: Id,
    window_value: Window,
    renderer_value: *render.Renderer,
    cfg: Config,
) !*Viewport {
    const self = try allocator.create(Viewport);
    errdefer allocator.destroy(self);

    try self.init(allocator, id, window_value, renderer_value, cfg);
    errdefer {
        self.overlay_painter.destroyAfterWait();
        self.ui_ctx.deinit();
    }
    if (!@import("platform.zig").is_browser_wasm) {
        if (cfg.accessibility) {
            self.accessibility = try NativeAccessibility.create(allocator, io, self.window.getWindowHandle(), &self.window, wakeAccessibility);
            self.window.accessibility = self.accessibility;
        }
    }

    return self;
}

pub fn createSecondary(
    allocator: std.mem.Allocator,
    io: std.Io,
    render_context: *render.Context,
    main_window: *Window,
    id: Id,
    window_cfg: WindowConfig,
    renderer_cfg: render.Renderer.Config,
    cfg: Config,
) !*Viewport {
    var window_value = try Window.initSecondary(main_window, io, allocator, window_cfg);

    var window_owned = true;
    errdefer if (window_owned)
        window_value.deinit();

    const framebuffer = window_value.getFramebufferSize();

    const renderer_value = try render.Renderer.create(
        allocator,
        render_context,
        window_value.getWindowHandle(),
        framebuffer.width,
        framebuffer.height,
        renderer_cfg,
    );

    var renderer_owned = true;
    errdefer if (renderer_owned)
        renderer_value.destroy();

    const self = try create(allocator, io, id, window_value, renderer_value, cfg);

    window_owned = false;
    renderer_owned = false;

    return self;
}

pub fn destroy(self: *Viewport, allocator: std.mem.Allocator) void {
    self.window.clearFrameHandler();
    if (!@import("platform.zig").is_browser_wasm) {
        self.window.accessibility = null;
        if (self.accessibility) |adapter| adapter.destroy();
    }
    self.ui_ctx.deinit();
    self.renderer.context.device.waitIdle() catch |err| std.log.warn("Layer shutdown: {s}", .{@errorName(err)});
    var painters = self.contribution_painters.valueIterator();
    while (painters.next()) |painter| painter.*.destroyAfterWait();
    self.contribution_painters.deinit(allocator);
    self.overlay_painter.destroyAfterWait();
    self.renderer.destroy();
    self.window.deinit();
    allocator.destroy(self);
}

fn wakeAccessibility(context: *anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(context));
    window.postEmptyEvent();
}

/// Queue a renderer configuration change for the next frame.
///
/// Applying it at the frame boundary avoids mutating renderer state while a
/// frame is being produced.
pub fn reconfigureRenderer(self: *Viewport, cfg: render.Renderer.Config) void {
    self.pending_renderer_cfg = cfg;
    self.window.requestFrame();
}

/// Consume the successful-reconfiguration edge.
pub fn takeRendererReconfigured(self: *Viewport) bool {
    const value = self.pending_reconfigure;
    self.pending_reconfigure = false;

    return value;
}

/// Called by the application host at the start of a frame.
pub fn applyRendererReconfigure(self: *Viewport) void {
    const cfg = self.pending_renderer_cfg orelse
        return;

    self.pending_renderer_cfg = null;

    self.renderer.reconfigure(cfg) catch |err| {
        self.renderer_reconfigure_error = err;
        return;
    };

    self.renderer_reconfigure_error = null;
    self.pending_reconfigure = true;
}
