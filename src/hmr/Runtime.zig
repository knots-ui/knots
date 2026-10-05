//! Runs the application's UI modules. If `reloadable` is false, the modules
//! are compiled into the host. Otherwise they load from the dev server's
//! manifest, and each change replaces them and keeps their state.
//!
//! The host refers to a module by its file: `render(@import("demo.zig"), frame)`.
//! The build found the modules (see graph.zig), so a file that cannot be a
//! module is a compile error that tells why.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const math = @import("math");
const render_api = @import("render");
const hmr = @import("hmr");
const FrameInput = @import("input").FrameInput;
const runtime_options = @import("runtime_options");

const reloadable = runtime_options.reloadable;
const registry = if (reloadable) struct {} else @import("native_registry");
const browser_host = builtin.target.cpu.arch.isWasm();
const Instance = if (!reloadable) void else if (browser_host) @import("Browser.zig") else @import("Wasmtime.zig");
const log = std.log.scoped(.hmr);

const directory_environment_name = "KNOTS_HMR_DIR";
const events_environment_name = "KNOTS_HMR_EVENTS";

pub const Wake = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };

const Failure = struct { operation: []const u8, error_name: []const u8 };

const Module = struct {
    id: []const u8,
    source: []const u8,
    hash: []const u8,
    generation: u64,
    instance: if (reloadable) ?Instance else void = if (reloadable) null else {},
    cleanup: ?*const fn () void = null,
    atlas_id: u32 = 0,
    failure: ?Failure = null,
    error_context: ?*ui.Context = null,
    carried_state: ?[]u8 = null,
};

allocator: std.mem.Allocator,
io: std.Io,
directory: []const u8 = "",
events: ?std.Io.net.IpAddress = null,
modules: std.ArrayList(Module) = .empty,
arena: std.heap.ArenaAllocator,
manifest_hash: ?u64 = null,
build_error: ?[]u8 = null,
next_generation: u64 = 1,
watch_group: std.Io.Group = .init,
watching: bool = false,
wake: ?Wake = null,
compilations: std.ArrayList(*Compilation) = .empty,
dirty: std.atomic.Value(bool) = .init(true),
browser_revision: u32 = 0,

const Runtime = @This();

/// A native module build that compiles on another thread, so a reload does not
/// stop the frames of the running modules. The next frame applies it.
const Compilation = if (reloadable and !browser_host) struct {
    entry: hmr.protocol.Entry,
    future: std.Io.Future(anyerror!Instance),
    done: std.atomic.Value(bool) = .init(false),
} else void;

pub fn create(allocator: std.mem.Allocator, io: std.Io, environment_map: anytype) !*Runtime {
    const self = try allocator.create(Runtime);
    self.* = .{ .allocator = allocator, .io = io, .arena = .init(allocator) };
    errdefer self.destroy();

    if (reloadable and !browser_host) {
        const directory = environment_map.get(directory_environment_name) orelse return error.HmrDirectoryMissing;
        self.directory = try allocator.dupe(u8, directory);
        if (environment_map.get(events_environment_name)) |address|
            self.events = try .parseLiteral(address);
    }

    if (!reloadable) {
        for (registry.entries) |entry| {
            try self.modules.append(allocator, .{
                .id = entry.id,
                .source = entry.source,
                .hash = "",
                .generation = self.nextGeneration(),
            });
        }
    }

    return self;
}

pub fn destroy(self: *Runtime) void {
    self.stopWatching();
    if (comptime reloadable and !browser_host) {
        while (self.compilations.items.len > 0)
            self.cancelCompilation(0);
    }
    self.compilations.deinit(self.allocator);

    for (self.modules.items) |*module|
        self.destroyModule(module);

    self.modules.deinit(self.allocator);
    self.allocator.free(self.directory);
    if (self.build_error) |message|
        self.allocator.free(message);

    self.arena.deinit();
    self.allocator.destroy(self);
}

/// Wakes the host whenever modules change. `wake` may be called from another task.
pub fn startWatching(self: *Runtime, wake: Wake) !void {
    if (comptime !reloadable)
        return;

    if (self.watching)
        return error.WatchingAlreadyStarted;

    wake.notify(wake.context);

    // The browser host requests a frame when the manifest changes.
    if (comptime browser_host)
        return;

    const events = self.events orelse return error.HmrEventsMissing;
    self.wake = wake;
    try self.watch_group.concurrent(self.io, awaitPublishes, .{ self.io, events, &self.dirty, wake });
    self.watching = true;
}

fn stopWatching(self: *Runtime) void {
    if (!self.watching)
        return;

    self.watch_group.cancel(self.io);
    self.watching = false;
}

/// The server sends one byte after each publish, so a change loads at once.
fn awaitPublishes(io: std.Io, address: std.Io.net.IpAddress, dirty: *std.atomic.Value(bool), wake: Wake) std.Io.Cancelable!void {
    const stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return log.err("event=events_connect_failed error={t} action=no_reloads", .{err}),
    };
    defer stream.close(io);

    var reader = stream.reader(io, &.{});
    while (true) {
        // A publish can come before the connection.
        dirty.store(true, .release);
        wake.notify(wake.context);
        var byte: [1]u8 = undefined;
        reader.interface.readSliceAll(&byte) catch |err| {
            if (reader.err) |cause| {
                if (cause == error.Canceled)
                    return error.Canceled;
            }

            if (err == error.EndOfStream)
                return;

            return log.err("event=events_read_failed error={t}", .{reader.err orelse err});
        };
    }
}

fn destroyModule(self: *Runtime, module: *Module) void {
    destroyInstance(module);
    if (module.error_context) |context| {
        context.deinit();
        self.allocator.destroy(context);
    }

    if (module.carried_state) |bytes|
        self.allocator.free(bytes);

    if (reloadable) {
        self.allocator.free(module.id);
        self.allocator.free(module.source);
        self.allocator.free(module.hash);
    } else if (module.cleanup) |cleanup| {
        cleanup();
    }
}

fn destroyInstance(module: *Module) void {
    if (comptime !reloadable)
        return;

    if (module.instance) |*instance|
        instance.deinit();

    module.instance = null;
}

/// Applies published changes. Call once per frame before `render`, so
/// modules do not change during a frame.
pub fn update(self: *Runtime) !void {
    if (comptime !reloadable)
        return;

    _ = self.arena.reset(.retain_capacity);
    self.applyManifest() catch |err|
        log.warn("event=update_failed error={t} action=keep_current_modules", .{err});

    if (comptime !browser_host)
        try self.finishCompilations();
}

fn isModule(comptime File: type) bool {
    comptime {
        for (runtime_options.module_ids) |module_id| {
            if (std.mem.eql(u8, module_id, @typeName(File)))
                return true;
        }
        return false;
    }
}

fn requireModule(comptime File: type) void {
    if (isModule(File))
        return;

    const name = @typeName(File);
    for (runtime_options.rejected_ids, runtime_options.rejected_reasons) |rejected_id, reason| {
        if (std.mem.eql(u8, rejected_id, name))
            @compileError(std.fmt.comptimePrint("{s} cannot be an HMR module: it {s}", .{ name, reason }));
    }

    @compileError(std.fmt.comptimePrint(
        "{s} is not an HMR module: it must declare `pub fn main(frame: *knots.Frame) !void` and be reachable from the executable",
        .{name},
    ));
}

fn lookup(self: *const Runtime, comptime File: type) ?usize {
    comptime requireModule(File);
    return self.find(@typeName(File));
}

pub fn source(self: *const Runtime, comptime File: type) []const u8 {
    const index = self.lookup(File) orelse return "";
    return self.modules.items[index].source;
}

pub fn generation(self: *const Runtime, comptime File: type) u64 {
    const index = self.lookup(File) orelse return 0;
    return self.modules.items[index].generation;
}

fn applyManifest(self: *Runtime) !void {
    const bytes = try self.readManifest() orelse return;
    try self.apply(bytes);
}

fn readManifest(self: *Runtime) !?[]const u8 {
    if (comptime browser_host)
        return self.readBrowserManifest();

    return self.readManifestFile();
}

fn readBrowserManifest(self: *Runtime) !?[]const u8 {
    const revision = Instance.revision();
    if (revision == self.browser_revision)
        return null;

    self.browser_revision = revision;
    return try Instance.manifest(self.arena.allocator());
}

fn readManifestFile(self: *Runtime) !?[]const u8 {
    if (!self.dirty.swap(false, .acq_rel))
        return null;

    const allocator = self.arena.allocator();
    const path = try std.fs.path.join(allocator, &.{ self.directory, "manifest.json" });
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(hmr.wire.bytes_max)) catch |err| {
        // The server may not have published yet.
        self.dirty.store(true, .release);
        return err;
    };
}

/// Modules match by id, so a change to one module does not touch the
/// instance or state of another.
fn apply(self: *Runtime, bytes: []const u8) !void {
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (self.manifest_hash == hash)
        return;

    self.manifest_hash = hash;
    const manifest = try std.json.parseFromSliceLeaky(
        hmr.protocol.Manifest,
        self.arena.allocator(),
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    if (self.build_error) |message|
        self.allocator.free(message);

    self.build_error = null;
    if (manifest.build_error) |message| {
        self.build_error = try self.allocator.dupe(u8, message);
        log.warn("event=build_failed action=keep_last_working_modules", .{});
    }

    for (manifest.modules) |entry| {
        if (comptime !browser_host) {
            // A compilation of another build of this module is out of date.
            if (self.findCompilation(entry.id)) |index| {
                if (std.mem.eql(u8, self.compilations.items[index].entry.hash, entry.hash))
                    continue;

                self.cancelCompilation(index);
            }
        }

        if (self.find(entry.id)) |index| {
            if (std.mem.eql(u8, self.modules.items[index].hash, entry.hash))
                continue;
        }

        if (comptime browser_host) {
            try self.finish(entry, Instance.init(entry.id, entry.hash));
        } else {
            try self.startCompilation(entry);
        }
    }

    if (comptime !browser_host) {
        var index: usize = 0;
        while (index < self.compilations.items.len) {
            if (listed(manifest, self.compilations.items[index].entry.id)) {
                index += 1;
            } else {
                self.cancelCompilation(index);
            }
        }
    }

    var index: usize = 0;
    while (index < self.modules.items.len) {
        const module = &self.modules.items[index];
        if (listed(manifest, module.id)) {
            index += 1;
            continue;
        }

        log.info("event=module_removed module_id={s}", .{module.id});
        self.destroyModule(module);
        _ = self.modules.orderedRemove(index);
    }
}

fn listed(manifest: hmr.protocol.Manifest, module_id: []const u8) bool {
    for (manifest.modules) |entry| {
        if (std.mem.eql(u8, entry.id, module_id))
            return true;
    }
    return false;
}

fn startCompilation(self: *Runtime, entry: hmr.protocol.Entry) !void {
    try Instance.initEngine();
    try self.compilations.ensureUnusedCapacity(self.allocator, 1);

    const compilation = try self.allocator.create(Compilation);
    errdefer self.allocator.destroy(compilation);

    const name = try self.allocator.dupe(u8, entry.id);
    errdefer self.allocator.free(name);

    const hash = try self.allocator.dupe(u8, entry.hash);
    errdefer self.allocator.free(hash);

    // `compile` frees the path.
    const path = try std.fmt.allocPrint(self.allocator, "{s}/artifacts/{s}.wasm", .{ self.directory, entry.hash });
    compilation.* = .{ .entry = .{ .id = name, .hash = hash }, .future = undefined };
    const arguments = .{ self.io, self.allocator, path, &compilation.done, self.wake };
    compilation.future = self.io.concurrent(compile, arguments) catch .{
        .any_future = null,
        .result = @call(.auto, compile, arguments),
    };

    self.compilations.appendAssumeCapacity(compilation);
}

fn compile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, done: *std.atomic.Value(bool), wake: ?Wake) anyerror!Instance {
    defer {
        allocator.free(path);
        done.store(true, .release);
        if (wake) |value|
            value.notify(value.context);
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(hmr.wire.bytes_max));
    defer allocator.free(bytes);

    return Instance.init(bytes);
}

fn finishCompilations(self: *Runtime) !void {
    var index: usize = 0;
    while (index < self.compilations.items.len) {
        const compilation = self.compilations.items[index];
        if (!compilation.done.load(.acquire)) {
            index += 1;
            continue;
        }

        _ = self.compilations.orderedRemove(index);
        defer self.freeCompilation(compilation);

        try self.finish(compilation.entry, compilation.future.await(self.io));
    }
}

fn cancelCompilation(self: *Runtime, index: usize) void {
    const compilation = self.compilations.orderedRemove(index);
    defer self.freeCompilation(compilation);

    var result = compilation.future.cancel(self.io);
    if (result) |*instance| {
        instance.deinit();
    } else |_| {}
}

fn freeCompilation(self: *Runtime, compilation: *Compilation) void {
    self.allocator.free(compilation.entry.id);
    self.allocator.free(compilation.entry.hash);
    self.allocator.destroy(compilation);
}

fn findCompilation(self: *const Runtime, name: []const u8) ?usize {
    for (self.compilations.items, 0..) |compilation, index| {
        if (std.mem.eql(u8, compilation.entry.id, name))
            return index;
    }
    return null;
}

/// Replaces the module `entry` names with `result`. If the build did not load,
/// an error panel replaces the module until its next build.
fn finish(self: *Runtime, entry: hmr.protocol.Entry, result: anyerror!Instance) !void {
    const existing = self.find(entry.id);
    var replacement = self.prepare(entry, result) catch |err| {
        log.warn("event=module_load_failed module_id={s} error={t}", .{ entry.id, err });
        const failure: Failure = .{ .operation = "load", .error_name = @errorName(err) };
        if (existing) |index| {
            const active = &self.modules.items[index];
            self.captureState(active);
            destroyInstance(active);
            const hash = try self.allocator.dupe(u8, entry.hash);
            self.allocator.free(active.hash);
            active.hash = hash;
            active.failure = failure;
        } else {
            var module = try self.newModule(entry, "");
            module.failure = failure;
            try self.modules.append(self.allocator, module);
        }
        return;
    };

    if (existing) |index| {
        const active = &self.modules.items[index];
        self.transferState(active, &replacement);
        self.destroyModule(active);
        active.* = replacement;
        log.info("event=module_reloaded module_id={s}", .{entry.id});
    } else {
        errdefer self.destroyModule(&replacement);
        try self.modules.append(self.allocator, replacement);
    }
}

fn prepare(self: *Runtime, entry: hmr.protocol.Entry, result: anyerror!Instance) !Module {
    var instance = try result;
    errdefer instance.deinit();

    const text = try instance.source(self.allocator);
    errdefer self.allocator.free(text);

    var module = try self.newModule(entry, text);
    module.instance = instance;
    return module;
}

fn newModule(self: *Runtime, entry: hmr.protocol.Entry, text: []const u8) !Module {
    const name = try self.allocator.dupe(u8, entry.id);
    errdefer self.allocator.free(name);

    const hash = try self.allocator.dupe(u8, entry.hash);
    return .{
        .id = name,
        .source = text,
        .hash = hash,
        .generation = self.nextGeneration(),
        .atlas_id = render_api.GlyphAtlas.allocateId(),
    };
}

fn nextGeneration(self: *Runtime) u64 {
    defer self.next_generation += 1;
    return self.next_generation;
}

fn find(self: *const Runtime, name: []const u8) ?usize {
    for (self.modules.items, 0..) |module, index| {
        if (std.mem.eql(u8, module.id, name))
            return index;
    }
    return null;
}

/// A trapped instance can still be read, so this also works after a frame
/// failure.
fn captureState(self: *Runtime, module: *Module) void {
    const instance = if (module.instance) |*value| value else return;
    const bytes = instance.snapshotState(self.allocator) catch |err| {
        log.warn("event=state_capture_failed module_id={s} error={t}", .{ module.id, err });
        return;
    };

    if (module.carried_state) |previous|
        self.allocator.free(previous);

    module.carried_state = bytes;
}

/// Call before the first frame of `replacement`. A failure loses the state
/// but does not stop the reload.
fn transferState(self: *Runtime, previous: *Module, replacement: *Module) void {
    const target = if (replacement.instance) |*value| value else return;
    const allocator = self.arena.allocator();
    const bytes = previousState(previous, allocator) catch |err| {
        log.warn("event=state_transfer_failed module_id={s} phase=snapshot error={t}", .{ previous.id, err });
        return;
    } orelse return;

    const report = target.restoreState(allocator, bytes) catch |err| {
        log.warn("event=state_transfer_failed module_id={s} phase=restore error={t}", .{ previous.id, err });
        return;
    };

    log.info("event=state_transferred module_id={s} {s} snapshot_bytes={d}", .{ previous.id, report, bytes.len });
}

fn previousState(module: *Module, allocator: std.mem.Allocator) !?[]const u8 {
    if (module.instance) |*instance|
        return try instance.snapshotState(allocator);

    return module.carried_state;
}

/// Compiled-in modules run in the host frame. Reloadable modules run isolated
/// and contribute a region that the host composes.
pub fn render(self: *Runtime, comptime File: type, frame: *ui.Frame) !void {
    const index = self.lookup(File) orelse return renderWaiting(@typeName(File), frame);
    const module = &self.modules.items[index];
    if (comptime !reloadable) {
        if (comptime @hasDecl(File, "deinit"))
            module.cleanup = &File.deinit;

        return File.main(frame);
    }

    const invocation = try frame.arena().create(Invocation);
    invocation.* = .{ .runtime = self, .index = @intCast(index) };
    const name = try std.fmt.allocPrint(frame.arena(), "knots.module:{s}", .{module.id});
    const key = ui.Key.str(name).indexed(@intCast(module.generation));
    const identity = std.hash.Wyhash.hash(module.generation, module.id);
    try frame.contribute(key, identity, invocation, Invocation.draw);
}

fn renderWaiting(id: []const u8, frame: *ui.Frame) !void {
    try frame.e(ui.component.Text{
        .content = try std.fmt.allocPrint(frame.arena(), "Waiting for module {s}...", .{id}),
        .style = &.{ .foreground = .dimmed },
        .selectable = false,
        .key = .str("hmr.waiting"),
    });
}

const Invocation = struct {
    runtime: *Runtime,
    index: u32,

    fn draw(
        pointer: *anyopaque,
        input: *const FrameInput,
        theme: *const ui.Theme,
        rectangle: math.Rect,
        allocator: std.mem.Allocator,
    ) !ui.Frame.ModuleOutput {
        const invocation: *Invocation = @ptrCast(@alignCast(pointer));
        return invocation.runtime.renderFrame(invocation.index, input, theme, rectangle, allocator);
    }
};

fn renderFrame(
    self: *Runtime,
    index: u32,
    input: *const FrameInput,
    theme: *const ui.Theme,
    rectangle: math.Rect,
    allocator: std.mem.Allocator,
) !ui.Frame.ModuleOutput {
    const module = &self.modules.items[index];
    if (module.failure == null) {
        if (frameOutput(module, input, theme, rectangle, allocator)) |output| {
            return output;
        } else |err| {
            log.warn("event=module_frame_failed module_id={s} error={t}", .{ module.id, err });
            self.captureState(module);
            destroyInstance(module);
            module.failure = .{ .operation = "render", .error_name = @errorName(err) };
        }
    }

    return self.renderFailure(module, input, rectangle, allocator);
}

fn frameOutput(
    module: *Module,
    input: *const FrameInput,
    theme: *const ui.Theme,
    rectangle: math.Rect,
    allocator: std.mem.Allocator,
) !ui.Frame.ModuleOutput {
    const instance = if (module.instance) |*value| value else return error.ModuleUnavailable;
    var request: std.ArrayList(u8) = .empty;
    try hmr.wire.encode(allocator, &request, hmr.Request{ .frame = input.*, .theme = theme.* });

    const response_bytes = try instance.frame(allocator, request.items);
    const response = try hmr.wire.decode(hmr.DecodedResponse, allocator, response_bytes);
    const effects = response.effects;

    return .{
        .packet = try hmr.panels.place(response.packet, module.atlas_id, rectangle),
        .cursor_shape = effects.cursor_shape,
        .capture_pointer = effects.capture_pointer,
        .capture_keyboard = effects.capture_keyboard,
        .text_input = effects.text_input,
        .redraw = effects.redraw,
        .close = effects.close,
        .clipboard_write = effects.clipboard_write,
        .theme = effects.theme,
    };
}

/// After a failed build, the last working modules run below this overlay.
/// Call once per frame, after the host's own UI.
pub fn renderOverlay(self: *Runtime, frame: *ui.Frame) !void {
    if (comptime !reloadable)
        return;

    const message = self.build_error orelse return;

    var open = true;
    const dialog: ui.component.Dialog = .{
        .is_open = &open,
        .key = .str("hmr.error.overlay"),
        .close_on_escape = false,
        .close_on_backdrop_press = false,
        .style = &.{
            .width = .{ .kind = .fit, .min = 640, .max = 960 },
            .height = .{ .kind = .fit, .max = 720 },
            .radius = .lg,
            .border_color = .@"error",
            .border_width = .all(2),
        },
        .parts = .{
            .backdrop = &.{
                .layer = .{ .z = ui.Frame.host_overlay_layer_min },
                .background = .{ .color = .{ .value = .{ 0, 0, 0, 0.62 } } },
            },
        },
    };

    _ = try dialog.open(frame);
    try frame.e(ui.component.Text{
        .content = "HMR build failed",
        .style = &.{ .font_size = .lg, .foreground = .@"error" },
        .selectable = false,
        .key = .str("hmr.error.overlay.title"),
    });
    try frame.e(ui.component.Text{
        .content = "The last working version is still running. Fix the error and save to retry.",
        .style = &.{ .width = .grow(), .wrap = true },
        .selectable = false,
        .key = .str("hmr.error.overlay.reason"),
    });
    try frame.e(ui.component.Text{
        .content = message,
        .style = &.{ .width = .grow(), .wrap = true, .font_size = .xs },
        .selectable = false,
        .key = .str("hmr.error.overlay.details"),
    });
    try dialog.close(frame);
}

fn renderFailure(
    self: *Runtime,
    module: *Module,
    input: *const FrameInput,
    rectangle: math.Rect,
    allocator: std.mem.Allocator,
) !ui.Frame.ModuleOutput {
    const failure = module.failure.?;
    const context = module.error_context orelse context: {
        const context = try self.allocator.create(ui.Context);
        errdefer self.allocator.destroy(context);
        context.* = try ui.Context.init(self.allocator, .{});
        module.error_context = context;
        break :context context;
    };

    var frame = try context.beginFrame(input.*);
    defer frame.deinit();

    const panel: ui.component.Rect = .{
        .style = &.{
            .width = .fixed(@floatFromInt(input.logical_extent.width)),
            .height = .fixed(@floatFromInt(input.logical_extent.height)),
            .padding = .all(16),
            .direction = .column,
            .gap = 8,
            .background = .elevated,
            .radius = .lg,
            .border_width = .all(1),
            .border_color = .@"error",
        },
        .key = .str("hmr.error.panel"),
    };

    _ = try panel.open(&frame);
    try frame.e(ui.component.Text{
        .content = try std.fmt.allocPrint(frame.arena(), "HMR module failed: {s}", .{module.id}),
        .style = &.{ .font_size = .lg, .foreground = .@"error" },
        .selectable = false,
        .key = .str("hmr.error.title"),
    });
    try frame.e(ui.component.Text{
        .content = try std.fmt.allocPrint(frame.arena(), "Could not {s} the module: {s}", .{ failure.operation, failure.error_name }),
        .style = &.{ .width = .grow(), .wrap = true },
        .selectable = false,
        .key = .str("hmr.error.reason"),
    });
    try frame.e(ui.component.Text{
        .content = failureAction(failure),
        .style = &.{ .width = .grow(), .foreground = .dimmed },
        .selectable = false,
        .key = .str("hmr.error.action"),
    });
    try panel.close(&frame);

    const output = try context.endFrame(&frame);
    const parts = try hmr.panels.copy(allocator, &output.packet);
    return .{ .packet = try hmr.panels.place(parts, module.atlas_id, rectangle) };
}

fn failureAction(failure: Failure) []const u8 {
    if (std.mem.eql(u8, failure.error_name, "HostOutdated"))
        return "Knots itself changed since the host was built. Restart `zig build dev`.";

    return "Fix the module and save to retry.";
}

const test_input: FrameInput = .{
    .input = .{ .pos = .{ -1, -1 } },
    .now_ms = 0,
    .delta_ns = 0,
    .logical_extent = .{ .width = 100, .height = 100 },
    .physical_extent = .{ .width = 100, .height = 100 },
    .content_scale = 1,
};

fn testFrame(instance: *Instance, allocator: std.mem.Allocator) !hmr.Response {
    var request: std.ArrayList(u8) = .empty;
    try hmr.wire.encode(allocator, &request, hmr.Request{ .frame = test_input, .theme = ui.Theme.dark });
    return hmr.wire.decode(hmr.Response, allocator, try instance.frame(allocator, request.items));
}

fn expectInstanceWidth(packet: anytype, expected: f32) !void {
    for (packet.instances()) |instance| {
        if (instance.size[0] == expected)
            return;
    }
    return error.ExpectedInstanceWidthNotFound;
}

test "modules run in isolated stores and inherit state across replacement" {
    if (browser_host)
        return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    try Instance.initEngine();
    try std.testing.expectError(error.WasmtimeFailure, Instance.init("invalid wasm"));

    var left = try Instance.init(@embedFile("fixture_wasm"));
    defer left.deinit();

    var right = try Instance.init(@embedFile("fixture_wasm"));
    defer right.deinit();

    try expectInstanceWidth(&(try testFrame(&left, allocator)).packet, 1);
    try expectInstanceWidth(&(try testFrame(&left, allocator)).packet, 2);
    try expectInstanceWidth(&(try testFrame(&right, allocator)).packet, 1);

    var replacement = try Instance.init(@embedFile("fixture_wasm"));
    defer replacement.deinit();

    const report = try replacement.restoreState(allocator, try left.snapshotState(allocator));
    try std.testing.expectEqualStrings("restored=2 reset=[]", report);
    try expectInstanceWidth(&(try testFrame(&replacement, allocator)).packet, 3);
}

const TestServer = struct {
    directory: std.testing.TmpDir,
    path: []const u8,
    allocator: std.mem.Allocator,

    fn artifact(self: *TestServer, bytes: []const u8) ![]const u8 {
        const hash = try self.allocator.dupe(u8, &hmr.protocol.contentHash(bytes));
        const path = try std.fmt.allocPrint(self.allocator, "artifacts/{s}.wasm", .{hash});
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes, .flags = .{} });
        return hash;
    }

    fn publish(self: *TestServer, runtime: *Runtime, modules: []const hmr.protocol.Entry, build_error: ?[]const u8) !void {
        const manifest: hmr.protocol.Manifest = .{ .modules = modules, .build_error = build_error };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, manifest, .{});
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = bytes, .flags = .{} });
        runtime.dirty.store(true, .release);
        try runtime.update();

        while (runtime.compilations.items.len > 0) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            try runtime.update();
        }
    }
};

fn moduleIndex(runtime: *const Runtime, module_id: []const u8) !u32 {
    const index = runtime.find(module_id) orelse return error.ModuleNotFound;
    return @intCast(index);
}

test "failed modules show an error panel and recover, with state, after a fix" {
    if (browser_host)
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const storage = arena.allocator();
    var server: TestServer = .{ .directory = std.testing.tmpDir(.{}), .path = undefined, .allocator = storage };
    defer server.directory.cleanup();

    try server.directory.dir.createDirPath(std.testing.io, "artifacts");
    server.path = try server.directory.dir.realPathFileAlloc(std.testing.io, ".", storage);

    var environment_map = std.process.Environ.Map.init(allocator);
    defer environment_map.deinit();

    try environment_map.put(directory_environment_name, server.path);
    const runtime = try Runtime.create(allocator, std.testing.io, &environment_map);
    defer runtime.destroy();

    const original = @embedFile("fixture_wasm");
    const hash = try server.artifact(original);
    var entries = [_]hmr.protocol.Entry{ .{ .id = "test/left", .hash = hash }, .{ .id = "test/right", .hash = hash } };
    try server.publish(runtime, &entries, null);
    try std.testing.expectEqual(@as(usize, 2), runtime.modules.items.len);

    // Modules join in the order their compilations finish.
    const left = try moduleIndex(runtime, "test/left");
    const right = try moduleIndex(runtime, "test/right");
    const generation_left = runtime.modules.items[left].generation;
    const generation_right = runtime.modules.items[right].generation;
    var input = test_input;
    const rectangle = math.Rect.init(0, 0, 100, 100);
    try expectInstanceWidth(&(try runtime.renderFrame(left, &input, &ui.Theme.dark, rectangle, storage)).packet, 1);
    try expectInstanceWidth(&(try runtime.renderFrame(right, &input, &ui.Theme.dark, rectangle, storage)).packet, 1);

    try server.publish(runtime, &entries, "error: expected expression");
    try std.testing.expectEqualStrings("error: expected expression", runtime.build_error.?);
    try expectInstanceWidth(&(try runtime.renderFrame(right, &input, &ui.Theme.dark, rectangle, storage)).packet, 2);

    try server.publish(runtime, &entries, null);
    try std.testing.expect(runtime.build_error == null);

    entries[0].hash = try server.artifact("not a wasm module");
    try server.publish(runtime, &entries, null);
    const load_failure = try runtime.renderFrame(left, &input, &ui.Theme.dark, rectangle, storage);
    try std.testing.expect(load_failure.packet.textInstances().len > 0);
    try std.testing.expectEqual(generation_left, runtime.modules.items[left].generation);

    entries[0].hash = try server.artifact(original ++ "\x00\x04\x03alt");
    try server.publish(runtime, &entries, null);
    try std.testing.expect(runtime.modules.items[left].generation != generation_left);
    try std.testing.expectEqual(generation_right, runtime.modules.items[right].generation);

    input.logical_extent.width = 7;
    const frame_failure = try runtime.renderFrame(left, &input, &ui.Theme.dark, .init(0, 0, 7, 100), storage);
    try std.testing.expect(frame_failure.packet.textInstances().len > 0);

    input.logical_extent.width = 13;
    try expectInstanceWidth(&(try runtime.renderFrame(right, &input, &ui.Theme.dark, .init(0, 0, 13, 100), storage)).packet, 3);

    entries[0].hash = hash;
    try server.publish(runtime, &entries, null);
    input.logical_extent.width = 100;
    try expectInstanceWidth(&(try runtime.renderFrame(left, &input, &ui.Theme.dark, rectangle, storage)).packet, 2);

    try server.publish(runtime, entries[1..], null);
    try std.testing.expectEqual(@as(usize, 1), runtime.modules.items.len);
    try std.testing.expectEqual(generation_right, runtime.modules.items[try moduleIndex(runtime, "test/right")].generation);
}
