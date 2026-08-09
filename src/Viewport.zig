const std = @import("std");

const Window = @import("window").Window;
const render = @import("renderer");
const UI = @import("ui").UI;

const App = @import("App.zig");
const Frame = @import("Frame.zig");
const View = @import("View.zig");
const Timer = @import("Timer.zig");

pub const Id = enum(u32) {
    main = 0,
    _,
};

pub const Config = struct {
    ui: UI.Config,
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode,
    timer_clock: std.Io.Clock,
};

const Viewport = @This();

app: ?*App = null,
id: Id,
window: Window,
view: View,
renderer: *render.Renderer,
timer: Timer,
ui_cfg: UI.Config,
frame_cb: ?App.RenderFn = null,
active_frame: ?*Frame = null,
pending_renderer_cfg: ?render.Renderer.Config = null,
pending_reconfigure: bool = false,
renderer_reconfigure_error: ?render.Renderer.ReconfigureError = null,
frame_active: bool = false,
frame_pending: bool = false,

pub fn init(
    self: *Viewport,
    allocator: std.mem.Allocator,
    id: Id,
    window_value: Window,
    renderer: *render.Renderer,
    cfg: Config,
) !void {
    self.* = .{
        .id = id,
        .window = window_value,
        .view = try .init(allocator, .{
            .ui = cfg.ui,
            .arena_reset_mode = cfg.arena_reset_mode,
        }),
        .renderer = renderer,
        .timer = .init(cfg.timer_clock),
        .ui_cfg = cfg.ui,
    };
}

pub fn deinit(self: *Viewport) void {
    self.window.clearFrameHandler();
    self.view.deinit();
    self.renderer.destroy();
    self.window.deinit();
}
