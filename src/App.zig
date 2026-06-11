const std = @import("std");
const builtin = @import("builtin");

const render = @import("render");
const WindowConfig = @import("window").Config;
const Window = @import("window").Window;
const UI = @import("ui").UI;
const Input = @import("ui").Input;
const CompletionQueue = @import("CompletionQueue.zig");
const Timer = @import("Timer.zig");
const ReturnType = @import("util.zig").ReturnType;

pub const Signal = enum {
    redraw,
    exit,
};

pub const Callback = *const fn (*App) anyerror!void;

pub const Config = struct {
    window: WindowConfig,
    renderer: render.Renderer.Config = .{},
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
    max_completions_recv: usize = 64,
    timer_clock: std.Io.Clock = .real,
};

io: std.Io,
allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
signals: std.ArrayList(Signal),
completion_queue: CompletionQueue,
renderer: render.Renderer,
window: Window,
ui: UI,
timer: Timer,
cfg: Config,
pending_renderer_cfg: ?render.Renderer.Config = null,
pending_reconfigure: bool = false,
frame_cb: Callback = undefined,
frame_active: bool = false,
frame_pending: bool = false,
frame_event_error: ?anyerror = null,

const App = @This();

/// The `io` parameter will be the underlying `Io` implementation used when calling `dispatch`.
/// The `allocator` parameter will be used as the backing allocator to the per-frame arena.
pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !App {
    var window: Window = try .init(io, allocator, cfg.window);
    errdefer window.deinit();

    var completion_queue: CompletionQueue = try .init(allocator, cfg.max_completions_recv);
    errdefer completion_queue.deinit(allocator, io);

    var ui: UI = try .init(allocator, cfg.ui);
    errdefer ui.deinit();

    var renderer: render.Renderer = try .init(allocator, window, cfg.renderer);
    errdefer renderer.deinit();

    return .{
        .io = io,
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .signals = .empty,
        .completion_queue = completion_queue,
        .renderer = renderer,
        .timer = .init(cfg.timer_clock),
        .window = window,
        .ui = ui,
        .cfg = cfg,
    };
}

pub fn reconfigureRenderer(self: *App, new_cfg: render.Renderer.Config) !void {
    self.pending_renderer_cfg = new_cfg;
    try self.signal(.redraw);
}

pub fn deinit(self: *App) void {
    self.frame_arena.deinit();
    self.completion_queue.deinit(self.allocator, self.io);
    self.signals.deinit(self.allocator);
    self.ui.deinit();
    self.renderer.deinit();
    self.window.deinit();
}

/// Start a frame-loop that runs until the window is closed.
pub fn start(self: *App, frameCb: Callback) !void {
    self.window.startCapture();
    self.frame_cb = frameCb;
    self.window.setFrameHandler(.{
        .ctx = self,
        .request = requestFrameHook,
        .step = stepFrameHook,
    });
    self.timer.start(self.io);
    self.window.pollEvents(self.io);

    switch (builtin.os.tag) {
        inline .emscripten => std.os.emscripten.emscripten_set_main_loop_arg(emscriptenMain, @ptrCast(self), 0, 0),
        inline else => {
            defer self.window.clearFrameHandler();
            while (self.window.isOpen()) {
                try self.stepFrame();
                self.window.waitEvents(self.io);
                try self.takeFrameEventError();
            }
        },
    }
}

/// Frame ordering, per tick:
///  1. `resolveWindow`: Collects input + routes scroll against the previous frame's tree.
///  2. `reset`: Clears the layout pool / decoration list.
///  3. `frameCb`: User code.
///  4. `endFrame`: TTL sweep over per-widget state.
///  5. `resolve` |> `tessellate` |> `resolveHit`: compute layout, build draw list, hit-test against the new tree.
fn renderFrame(self: *App, frameCb: Callback) !void {
    defer _ = self.frame_arena.reset(self.cfg.arena_reset_mode);

    self.timer.tick(self.io);

    if (self.window.consumeResize()) |ev| {
        if (ev.physical.width == 0 or ev.physical.height == 0) return;
        try self.renderer.resize(ev.physical.width, ev.physical.height);
    }
    try self.handleRendererReconfigure();

    try self.ui.resolveWindow(self.window.collectInput(), self.timer.ms(), self.window.getContentScale());
    self.ui.reset();

    try self.completion_queue.consume(self, self.io);

    try @call(.auto, frameCb, .{self});

    try self.ui.endFrame();
    if (self.drainSignals()) return;

    try self.ui.resolve();
    const draw_list = self.renderer.beginFrame();
    try self.ui.tessellate(self.frame_arena.allocator(), draw_list);
    const hover_changed = self.ui.resolveHit();
    try self.renderer.endFrame(self.ui.font.glyph_builder, self.ui.content_scale);

    if (hover_changed or self.ui.anim_active) try self.signal(.redraw);
    _ = self.drainSignals();
}

fn emscriptenMain(ud: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    self.stepFrame() catch |err| {
        std.os.emscripten.emscripten_log(std.os.emscripten.LOG.ERROR, "error in presenting frame: %s", (@errorName(err)).ptr);
    };
}

fn stepFrame(self: *App) !void {
    if (self.frame_active) {
        self.frame_pending = true;
        return;
    }
    self.frame_active = true;
    defer self.frame_active = false;

    try self.renderFrame(self.frame_cb);
    while (self.frame_pending) {
        self.frame_pending = false;
        try self.renderFrame(self.frame_cb);
    }
}

fn takeFrameEventError(self: *App) !void {
    if (self.frame_event_error) |err| {
        self.frame_event_error = null;
        return err;
    }
}

fn drainSignals(self: *App) bool {
    var should_exit = false;
    while (self.signals.pop()) |s| switch (s) {
        .redraw => self.window.requestFrame(),
        .exit => {
            @branchHint(.cold);
            self.window.close();
            should_exit = true;
        },
    };
    return should_exit;
}

fn requestFrameHook(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.window.postEmptyEvent();
}

fn stepFrameHook(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.frame_event_error != null) return;
    self.stepFrame() catch |err| {
        self.frame_event_error = err;
    };
}

/// Queue a frame signal, `.redraw` or `.exit`. May allocate.
pub inline fn signal(self: *App, s: Signal) !void {
    try self.signals.append(self.allocator, s);
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
    const v = self.pending_reconfigure;
    self.pending_reconfigure = false;
    return v;
}

fn handleRendererReconfigure(self: *App) !void {
    const new_cfg = self.pending_renderer_cfg orelse return;
    self.pending_renderer_cfg = null;

    try self.renderer.reconfigure(new_cfg);

    self.ui.font.glyph_builder.markAllDirty();
    self.pending_reconfigure = true;
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
        inline .@"fn" => try @call(.always_inline, tree, .{self}),
        inline .@"struct" => |s| if (comptime isRenderable(T))
            try tree.render(self)
        else {
            comptime var i: usize = 0;
            inline while (i < s.field_names.len) : (i += 1) {
                const val = @field(tree, s.field_names[i]);
                if (comptime isComponent(@TypeOf(val)) and i + 1 < s.field_types.len and isChildren(s.field_types[i + 1])) {
                    const id = try val.open(self);
                    if (id != UI.INVALID_ID)
                        try self.e(@field(tree, s.field_names[i + 1]));
                    try val.close(self);
                    i += 1;
                } else try self.e(val);
            }
        },
        inline else => @compileError("unexpected type in component tree: " ++ @typeName(T)),
    }
}

fn isControlFlow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        inline .@"struct" => @hasDecl(T, "eval"),
        inline else => false,
    };
}

fn isComponent(comptime T: type) bool {
    const S = switch (@typeInfo(T)) {
        inline .@"struct" => T,
        inline .pointer => |p| p.child,
        inline else => return false,
    };
    return @hasDecl(S, "open") and @hasDecl(S, "close");
}

fn isRenderable(comptime T: type) bool {
    if (!@hasDecl(T, "render")) return false;
    return @TypeOf(T.render) == fn (*const T, *App) anyerror!void;
}

fn isChildren(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        inline .@"struct" => |s| s.is_tuple,
        inline else => false,
    };
}
