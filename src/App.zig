const std = @import("std");
const builtin = @import("builtin");

const render = @import("render");
const Window = @import("window").Window;
const UI = @import("ui").UI;
const Input = @import("ui").Input;
const CompletionQueue = @import("CompletionQueue.zig");
const Timer = @import("Timer.zig");
const ReturnType = @import("util.zig").ReturnType;

const is_emscripten = builtin.target.os.tag == .emscripten;

pub const Signal = enum {
    redraw,
    exit,
};

pub const Callback = *const fn (*App) anyerror!void;

pub const Config = struct {
    window: Window.Config,
    renderer: render.Renderer.Config = .{},
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
    max_completions_recv: usize = 64,
    timer_clock: std.Io.Clock = .real,
    signals_buffer_size: usize = 256,
    onResize: ?*const fn (app: *App, width: u32, height: u32) anyerror!void = null,
    onDrop: ?*const fn (app: *App, paths: []const []const u8) anyerror!void = null,
    onReconfigure: ?*const fn (app: *App) anyerror!void = null,
};

io: std.Io,
allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
signals: std.ArrayList(Signal),
completion_queue: CompletionQueue,
renderer: render.Renderer,
draw_list: render.DrawList,
window: Window,
ui: UI,
timer: Timer,
cfg: Config,
pending_renderer_cfg: ?render.Renderer.Config = null,

const App = @This();

/// The `io` parameter will be the underlying `Io` implementation used when calling `dispatch`.
/// The `allocator` parameter will be used as the backing allocator to the per-frame arena.
pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !App {
    const window = try Window.init(cfg.window);
    errdefer window.deinit();

    var signals = try std.ArrayList(Signal).initCapacity(allocator, cfg.signals_buffer_size);
    errdefer signals.deinit(allocator);

    var completion_queue = try CompletionQueue.init(allocator, cfg.max_completions_recv);
    errdefer completion_queue.deinit(allocator, io);

    var ui = try UI.init(allocator, cfg.ui);
    errdefer ui.deinit();

    var renderer: render.Renderer = try .init(allocator, window, cfg.renderer);
    errdefer renderer.deinit();

    return .{
        .io = io,
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .signals = signals,
        .completion_queue = completion_queue,
        .renderer = renderer,
        .draw_list = .init(allocator),
        .timer = .init(cfg.timer_clock),
        .window = window,
        .ui = ui,
        .cfg = cfg,
    };
}

pub fn reconfigureRenderer(self: *App, new_cfg: render.Renderer.Config) void {
    self.pending_renderer_cfg = new_cfg;
    self.signal(.redraw);
}

pub fn deinit(self: *App) void {
    self.frame_arena.deinit();
    self.completion_queue.deinit(self.allocator, self.io);
    self.signals.deinit(self.allocator);
    self.ui.deinit();
    self.draw_list.deinit();
    self.renderer.deinit();
    self.window.deinit();
}

/// Start a frame-loop that runs until the window is closed.
pub fn start(self: *App, frameCb: Callback) !void {
    self.window.startCapture();
    if (self.cfg.onDrop) |_| {
        self.window.setDropCallback(@ptrCast(self), dropCallback);
    }
    self.timer.start(self.io);
    self.window.pollEvents();

    switch (builtin.os.tag) {
        inline .emscripten => {
            const ctx = try self.allocator.create(EmscriptenContext);
            ctx.* = .{
                .app = self,
                .frameCb = frameCb,
            };
            std.os.emscripten.emscripten_set_main_loop_arg(emscriptenMain, @ptrCast(ctx), 0, 0);
        },
        inline else => while (self.window.isOpen()) try self.tickFrame(frameCb),
    }
}

fn tickFrame(self: *App, frameCb: Callback) !void {
    if (is_emscripten)
        self.window.pollEvents();

    defer {
        self.draw_list.reset();
        _ = self.frame_arena.reset(self.cfg.arena_reset_mode);
    }

    self.timer.tick(self.io);

    if (self.window.consumeResize()) |ev| {
        if (ev.physical.width == 0 or ev.physical.height == 0) return;
        try self.renderer.resize(ev.physical.width, ev.physical.height);
        if (self.cfg.onResize) |cb| try @call(.auto, cb, .{ self, ev.logical.width, ev.logical.height });
    }
    try self.handleRendererReconfigure();

    self.ui.beginFrame(&self.window);
    try self.ui.collectInput(self.window.collectInput(), self.timer.ms());
    self.ui.reset();

    try self.completion_queue.consume(self, self.io);

    try @call(.auto, frameCb, .{self});

    if (self.ui.anim_active) self.signal(.redraw);

    while (self.signals.pop()) |s| switch (s) {
        .redraw => self.window.postEmptyEvent(),
        .exit => {
            @branchHint(.cold);
            self.window.close();
            return;
        },
    };

    try self.ui.resolve();
    try self.ui.tessellate(self.frame_arena.allocator(), &self.draw_list);
    self.ui.resolveHit();
    try self.renderer.draw(&self.draw_list, self.ui.font.atlas, self.ui.content_scale);

    if (!is_emscripten)
        self.window.waitEvents();
}

const EmscriptenContext = struct {
    app: *App,
    frameCb: Callback,
};

fn emscriptenMain(ud: ?*anyopaque) callconv(.c) void {
    const ctx: *EmscriptenContext = @ptrCast(@alignCast(ud orelse return));
    ctx.app.tickFrame(ctx.frameCb) catch {};
}

/// Queue a frame signal, `.redraw` or `.exit`.
/// The max queued signals can be configured with `signals_buffer_size`.
pub inline fn signal(self: *App, s: Signal) void {
    self.signals.appendBounded(s) catch {};
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
        _ = try tree.open(&self.ui);
        try tree.close(&self.ui);
    } else switch (@typeInfo(T)) {
        inline .@"fn" => try @call(.always_inline, tree, .{self}),
        inline .@"struct" => |s| if (comptime isRenderable(T))
            try tree.render(self)
        else {
            comptime var i: usize = 0;
            inline while (i < s.fields.len) : (i += 1) {
                const val = @field(tree, s.fields[i].name);
                if (comptime isComponent(@TypeOf(val)) and i + 1 < s.fields.len and isChildren(s.fields[i + 1].type)) {
                    _ = try val.open(&self.ui);
                    try self.e(@field(tree, s.fields[i + 1].name));
                    try val.close(&self.ui);
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

fn handleRendererReconfigure(self: *App) !void {
    const new_cfg = self.pending_renderer_cfg orelse return;
    self.pending_renderer_cfg = null;

    try self.renderer.reconfigure(new_cfg);

    self.ui.font.atlas.dirty_min_y = 0;
    self.ui.font.atlas.dirty_max_y_excl = self.ui.font.atlas.height;
    if (self.cfg.onReconfigure) |cb| try cb(self);
}

fn dropCallback(ctx: *anyopaque, paths: []const []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.cfg.onDrop) |cb| try cb(self, paths);
}
