const std = @import("std");
const wasmtime = @import("wasmtime");
const wire = @import("wire");
const abi = @import("abi");
const Instance = @import("Instance.zig");
const Windows = @import("Windows.zig");
const Gpu = @import("Gpu.zig");
const Reply = @import("Reply.zig");
const Workers = @import("Workers.zig");
const module = @import("module.zig");
const imports = @import("imports.zig");
const app_nap = @import("app_nap.zig");

const Host = @This();
const log = std.log.scoped(.dev_host);

gpa: std.mem.Allocator,
io: std.Io,
/// Winch compiles about 4x faster than Cranelift. The guest's frames are
/// slower, but a reload is the cost that matters while editing.
single: Instance.Runtime,
threaded: ?Instance.Runtime = null,
guest: ?Instance = null,
app: ?[]u8 = null,
app_rendered: bool = false,
/// The last other build that drew a frame, to fall back to.
working: ?[]u8 = null,
windows: Windows,
gpu: Gpu,
inbox: struct {
    mutex: std.Io.Mutex = .init,
    app: ?[]u8 = null,
    diagnostics: Diagnostics = .unchanged,
} = .{},
published: std.atomic.Value(bool) = .init(false),
tasks_finished: std.atomic.Value(bool) = .init(false),
build_error: ?[]u8 = null,
crash: ?[]u8 = null,
restart_pending: bool = false,
restarted: bool = false,
seed: std.atomic.Value(u64),

const Diagnostics = union(enum) { unchanged, cleared, failed: []u8 };

/// The host stays at its address: its windows and its imports point to it.
pub fn init(self: *Host, gpa: std.mem.Allocator, io: std.Io) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .single = try runtime(.{ .consume_fuel = true, .compiler = .winch }),
        .windows = .{ .gpa = gpa, .io = io, .on_frame = .{ .context = self, .run = frame } },
        .gpu = .{ .gpa = gpa },
        .seed = .init(@truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)))),
    };
    errdefer self.single.deinit();
    try imports.define(&self.single.linker, self);
    // Reloads would slow down while the window is in the background.
    app_nap.disable();
}

pub fn deinit(self: *Host) void {
    if (self.guest) |*guest| {
        self.gpu.releaseGuest();
        guest.deinit();
    }
    self.windows.deinit(&self.gpu);
    self.gpu.deinit();
    self.setDiagnostics(.unchanged);
    for ([_]?[]u8{ self.app, self.working, self.build_error, self.crash, self.inbox.app }) |bytes| if (bytes) |value| self.gpa.free(value);
    if (self.threaded) |*threaded| threaded.deinit();
    self.single.deinit();
}

fn runtime(options: wasmtime.Engine.Options) !Instance.Runtime {
    var engine = try wasmtime.Engine.init(options);
    errdefer engine.deinit();
    return .{ .engine = engine, .linker = try wasmtime.Linker.init(engine) };
}

pub fn run(self: *Host) !void {
    self.published.store(false, .release);
    self.takePublished();
    while (self.windows.main()) |main| {
        if (!main.window.isOpen()) return;
        main.window.waitEvents(self.io);
        if (self.published.swap(false, .acq_rel)) self.takePublished();
        if (self.tasks_finished.swap(false, .acq_rel)) self.releaseTasks();
        if (self.restart_pending) self.restart();
    }
    return error.GuestOpenedNoWindow;
}

pub fn publishApp(self: *Host, bytes: []const u8) void {
    self.inbox.mutex.lockUncancelable(self.io);
    replace(self.gpa, &self.inbox.app, bytes);
    self.setDiagnostics(.cleared);
    self.inbox.mutex.unlock(self.io);
    self.published.store(true, .release);
    self.wake();
}

pub fn publishFailure(self: *Host, diagnostics: []const u8) void {
    self.inbox.mutex.lockUncancelable(self.io);
    self.setDiagnostics(failed(self.gpa, diagnostics));
    self.inbox.mutex.unlock(self.io);
    self.published.store(true, .release);
    self.wake();
}

fn setDiagnostics(self: *Host, next: Diagnostics) void {
    switch (self.inbox.diagnostics) {
        .failed => |previous| self.gpa.free(previous),
        .unchanged, .cleared => {},
    }
    self.inbox.diagnostics = next;
}

fn failed(gpa: std.mem.Allocator, diagnostics: []const u8) Diagnostics {
    const copy = gpa.dupe(u8, diagnostics) catch return .unchanged;
    return .{ .failed = copy };
}

fn replace(gpa: std.mem.Allocator, slot: *?[]u8, bytes: []const u8) void {
    if (slot.*) |previous| gpa.free(previous);
    slot.* = gpa.dupe(u8, bytes) catch null;
}

pub fn wake(self: *Host) void {
    self.windows.wake();
}

pub fn memory(self: *Host, pointer: u32, length: u32) []u8 {
    if (Workers.current) |worker| return worker.memory.range(pointer, length) catch &.{};
    const guest = &(self.guest orelse return &.{});
    return guest.range(pointer, length);
}

pub fn call(self: *Host, request: []const u8, reply: *Reply) !void {
    switch (try wire.decode(abi.Call, reply.arena, request)) {
        .window => |window_call| try self.windows.call(window_call, reply),
        .gpu => |gpu_call| try self.gpu.call(gpu_call, &self.windows, reply),
    }
}

pub fn commands(self: *Host, arena: std.mem.Allocator, bytes: []const u8) !void {
    var reader: wire.Reader = .{ .allocator = arena, .data = bytes };
    while (!reader.done()) switch (try reader.value(abi.Command)) {
        .window => |command| self.windows.command(command, &self.gpu) catch |err|
            log.err("event=command_failed command={t} error={t}", .{ command, err }),
        .gpu => |command| self.gpu.command(command, &self.windows) catch |err|
            log.err("event=command_failed command={t} error={t}", .{ command, err }),
    };
}

fn takePublished(self: *Host) void {
    self.inbox.mutex.lockUncancelable(self.io);
    const app = self.inbox.app;
    const diagnostics = self.inbox.diagnostics;
    self.inbox.app = null;
    self.inbox.diagnostics = .unchanged;
    self.inbox.mutex.unlock(self.io);

    switch (diagnostics) {
        .unchanged => {},
        .cleared => self.setBuildError(null),
        .failed => |message| self.setBuildError(message),
    }
    const bytes = app orelse return self.showProblem();
    if (self.app) |running| {
        if (std.mem.eql(u8, running, bytes)) {
            self.gpa.free(bytes);
            return self.showProblem();
        }
        self.retire(running);
    }
    self.app = bytes;
    self.app_rendered = false;
    if (self.crash) |previous| self.gpa.free(previous);
    self.crash = null;
    self.restarted = false;
    self.load(bytes);
}

fn setBuildError(self: *Host, message: ?[]u8) void {
    if (self.build_error) |previous| self.gpa.free(previous);
    self.build_error = message;
}

fn retire(self: *Host, running: []u8) void {
    if (!self.app_rendered) return self.gpa.free(running);
    if (self.working) |previous| self.gpa.free(previous);
    self.working = running;
}

/// A build that never drew a frame would trap again before showing why,
/// so the last one that did runs instead.
fn restart(self: *Host) void {
    self.restart_pending = false;
    if (!self.app_rendered) if (self.working) |working| {
        log.warn("event=guest_trapped_before_frame action=load_last_working_build", .{});
        if (self.app) |running| self.gpa.free(running);
        self.app = working;
        self.working = null;
        self.app_rendered = true;
        return self.load(working);
    };
    const bytes = self.app orelse return;
    if (self.restarted) return log.warn("event=guest_trapped_again action=wait_for_next_build", .{});
    self.restarted = true;
    self.load(bytes);
}

fn load(self: *Host, bytes: []const u8) void {
    const started = std.Io.Clock.awake.now(self.io);
    const guest = self.instantiate(bytes) catch |err| return log.err("event=load_failed error={t}", .{err});
    const compiled = std.Io.Clock.awake.now(self.io);

    // The old guest goes first: the new one opens its windows again.
    var state: ?[]u8 = null;
    defer if (state) |value| self.gpa.free(value);
    if (self.guest) |*old| {
        // A guest that trapped can still be read.
        state = old.saveState() catch null;
        self.gpu.releaseGuest();
        old.deinit();
    }
    self.guest = guest;

    const current = &self.guest.?;
    self.windows.opened = 0;
    // The windows stay open to show why after the restart.
    const status = current.call("main", &.{}, u32) catch |err| return self.trapped(err);
    self.windows.closeUnopened(&self.gpu);
    if (state) |value| current.loadState(value) catch |err| self.trapped(err);
    self.showProblem();
    log.info("event=guest_loaded status={d} compile_ms={d} start_ms={d} widget_state_bytes={d}", .{
        status,
        started.durationTo(compiled).toMilliseconds(),
        compiled.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds(),
        if (state) |value| value.len else 0,
    });
}

fn instantiate(self: *Host, bytes: []const u8) !Instance {
    const prepared = try module.prepare(self.gpa, bytes);
    defer self.gpa.free(prepared.bytes);
    return Instance.init(self.gpa, if (prepared.shared) try self.threadedRuntime() else &self.single, prepared);
}

fn threadedRuntime(self: *Host) !*Instance.Runtime {
    if (self.threaded == null) {
        // Without optimizations, Cranelift compiles about 20% faster.
        var threaded = try runtime(.{ .consume_fuel = true, .compiler = .cranelift, .threads = true, .optimize = false });
        errdefer threaded.deinit();
        self.threaded = threaded;
        // The imports point to the runtime's linker at its address in `self`.
        errdefer self.threaded = null;
        try imports.define(&self.threaded.?.linker, self);
    }
    return &self.threaded.?;
}

fn trapped(self: *Host, err: Instance.Error) void {
    if (err != error.Trapped) return log.err("event=guest_call_failed error={t}", .{err});
    if (self.guest.?.trap) |trap| replace(self.gpa, &self.crash, trap);
    self.restart_pending = true;
    self.wake();
}

fn frame(context: *anyopaque, entry: *Windows.Entry) void {
    const self: *Host = @ptrCast(@alignCast(context));
    const guest = &(self.guest orelse return);
    if (guest.trap != null) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resized = entry.window.consumeResize() != null;
    const frame_input = entry.window.collectInput() catch return;
    defer entry.window.finishInputFrame();
    const paste = entry.window.takePaste();
    defer if (paste) |text| entry.window.allocator.free(text);
    var bytes: std.ArrayList(u8) = .empty;
    wire.encode(allocator, &bytes, abi.Input{
        .metrics = entry.metrics(),
        .resized = resized,
        .closed = !entry.window.isOpen(),
        .input = frame_input,
        .paste = paste,
        .drops = entry.window.consumeDrops(allocator) catch &.{},
    }) catch return;
    guest.frame(entry.handle, bytes.items) catch |err| return self.trapped(err);
    self.app_rendered = true;
}

fn releaseTasks(self: *Host) void {
    const guest = &(self.guest orelse return);
    const count = guest.releaseTasks() catch |err| return self.trapped(err);
    if (count == 0) return;
    for (self.windows.entries.items) |slot| if (slot) |entry| entry.window.requestFrame();
}

fn showProblem(self: *Host) void {
    const guest = &(self.guest orelse return);
    if (self.crash) |crash| return guest.showProblem(.crashed, crash) catch {};
    if (self.build_error) |diagnostics| return guest.showProblem(.build_failed, diagnostics) catch {};
    guest.showProblem(.none, "") catch {};
}

pub fn taskFinished(context: *anyopaque) void {
    const self: *Host = @ptrCast(@alignCast(context));
    self.tasks_finished.store(true, .release);
    self.wake();
}
