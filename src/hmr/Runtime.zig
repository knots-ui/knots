const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const math = @import("math");
const Protocol = @import("hmr").Protocol;
const reloadable = @import("runtime_options").reloadable;
const FrameInput = @import("input").FrameInput;
const registry = if (reloadable) struct {} else @import("native_registry");
const browser_host = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding;
const Instance = if (!reloadable) void else if (browser_host) @import("Browser.zig") else @import("Wasmtime.zig");
const support = @import("hmr");
const Status = @import("hmr").Status;
const Log = @import("Log.zig");
const Watch = if (reloadable and !browser_host) @import("watch") else void;

const manifest_environment_name = "KNOTS_HMR_MANIFEST";
const status_environment_name = "KNOTS_HMR_STATUS";
const watch_wait_ms: u64 = 1_000;

comptime {
    std.debug.assert(watch_wait_ms > 0);
    std.debug.assert(watch_wait_ms <= 1_000);
}

const Native = if (reloadable)
    void
else
    *const fn (*ui.Frame) anyerror!void;

const Failure = struct {
    operation: []const u8,
    error_name: []const u8,
};

const HmrErrorKind = enum { compile, update };

const Module = struct {
    id: []const u8,
    source: []const u8,
    hash: []const u8,
    instance: if (reloadable) ?Instance else void = if (reloadable) null else {},
    generation: u64,
    native: Native,
    resources: support.Panels.Resources,
    failure: ?Failure = null,
    error_context: ?*ui.Context = null,
    cleanup: ?*const fn () void = null,
};

allocator: std.mem.Allocator,
io: std.Io,
manifest_path: []const u8,
status_path: []const u8,
modules: std.ArrayList(Module) = .empty,
arena: std.heap.ArenaAllocator,
manifest_hash: u64 = 0,
manifest_loaded: bool = false,
status_hash: u64 = 0,
status_loaded: bool = false,
hmr_error: ?[]u8 = null,
hmr_error_kind: HmrErrorKind = .compile,
error_overlay_active: bool = false,
error_overlay_generation: u64 = 0,
next_generation: u64 = 1,
watch_group: std.Io.Group = .init,
watching: bool = false,
manifest_dirty: std.atomic.Value(bool) = .init(false),
browser_revision: u32 = 0,

const Runtime = @This();

pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque) void,
};

/// Create the runtime using the server-provided manifest location.
pub fn create(allocator: std.mem.Allocator, io: std.Io, environment_map: anytype) !*Runtime {
    const self = try allocator.create(Runtime);
    self.* = .{ .allocator = allocator, .io = io, .arena = .init(allocator), .manifest_path = "", .status_path = "" };
    errdefer self.destroy();

    if (reloadable and !browser_host) {
        self.manifest_path = try manifestPath(self.allocator, environment_map);
        self.status_path = try statusPath(self.allocator, environment_map);
    }

    if (!reloadable) {
        for (registry.entries, 0..) |entry, index| {
            const name = try allocator.dupe(u8, entry.id);
            errdefer allocator.free(name);
            const source_text = try allocator.dupe(u8, entry.source);
            errdefer allocator.free(source_text);
            const hash = try allocator.dupe(u8, "native");
            errdefer allocator.free(hash);
            try self.modules.append(allocator, .{ .id = name, .source = source_text, .hash = hash, .instance = {}, .generation = index + 1, .native = entry.main, .cleanup = entry.cleanup, .resources = .init() });
        }
        self.next_generation = registry.entries.len + 1;
    }
    return self;
}

fn manifestPath(allocator: std.mem.Allocator, environment_map: anytype) ![]const u8 {
    std.debug.assert(@intFromPtr(environment_map) != 0);
    const value = environment_map.get(manifest_environment_name) orelse return error.HmrManifestMissing;
    std.debug.assert(value.len > 0);
    const result = try allocator.dupe(u8, value);
    std.debug.assert(result.len == value.len);
    return result;
}

fn statusPath(allocator: std.mem.Allocator, environment_map: anytype) ![]const u8 {
    std.debug.assert(@intFromPtr(environment_map) != 0);
    const value = environment_map.get(status_environment_name) orelse return error.HmrStatusMissing;
    std.debug.assert(value.len > 0);
    const result = try allocator.dupe(u8, value);
    std.debug.assert(result.len == value.len);
    return result;
}

pub fn destroy(self: *Runtime) void {
    self.stopWatching();
    for (self.modules.items) |*module| {
        self.destroyModule(module);
    }
    self.modules.deinit(self.allocator);
    if (reloadable and !browser_host) {
        if (self.manifest_path.len > 0) {
            self.allocator.free(self.manifest_path);
        } else {
            std.debug.assert(self.manifest_path.len == 0);
        }
        if (self.status_path.len > 0) {
            self.allocator.free(self.status_path);
        } else {
            std.debug.assert(self.status_path.len == 0);
        }
    } else {
        std.debug.assert(self.manifest_path.len == 0);
        std.debug.assert(self.status_path.len == 0);
        if (!reloadable) std.debug.assert(self.hmr_error == null);
    }
    if (self.hmr_error) |message| self.allocator.free(message);
    self.arena.deinit();
    self.allocator.destroy(self);
}

/// Wake the host when the reloadable manifest changes. The callback must be
/// safe to invoke from the runtime's I/O task.
pub fn startWatching(self: *Runtime, wake: Wake) !void {
    std.debug.assert(@intFromPtr(wake.context) > 0);
    std.debug.assert(@intFromPtr(wake.notify) > 0);
    if (comptime !reloadable) return;
    if (self.watching) return error.WatchingAlreadyStarted;

    self.watching = true;
    if (comptime browser_host) {
        self.browser_revision = 0;
        wake.notify(wake.context);
        return;
    }
    self.watch_group.concurrent(self.io, watchTask, .{
        self.io,
        self.allocator,
        self.manifest_path,
        self.status_path,
        &self.manifest_dirty,
        wake,
    }) catch |err| {
        self.watching = false;
        return err;
    };
}

fn stopWatching(self: *Runtime) void {
    if (!self.watching) return;
    if (comptime browser_host) {
        self.watching = false;
        return;
    }
    self.watch_group.cancel(self.io);
    self.watch_group.await(self.io) catch {};
    self.watching = false;
}

fn watchTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    status_path: []const u8,
    manifest_dirty: *std.atomic.Value(bool),
    wake: Wake,
) std.Io.Cancelable!void {
    const manifest_directory = std.fs.path.dirname(manifest_path) orelse unreachable;
    std.debug.assert(manifest_directory.len > 0);
    std.debug.assert(status_path.len > 0);
    var should_stop: std.atomic.Value(bool) = .init(false);
    var watcher = Watch.init(io, allocator, &should_stop, manifest_directory) catch |err| {
        std.log.err(
            "ts={f} component=hmr-runtime event=watch_start_failed error={s} action=disable_live_reload",
            .{ Log.timestamp(io), @errorName(err) },
        );
        return;
    };
    defer watcher.deinit();

    manifest_dirty.store(true, .release);
    wake.notify(wake.context);
    while (true) {
        try std.Io.checkCancel(io);
        if (watcher.wait(watch_wait_ms) == .dirty) {
            manifest_dirty.store(true, .release);
            wake.notify(wake.context);
        } else if (manifest_dirty.load(.acquire)) {
            wake.notify(wake.context);
        }
    }
}

fn destroyModule(self: *Runtime, module: *Module) void {
    destroyInstance(module);
    if (module.error_context) |context| {
        context.deinit();
        self.allocator.destroy(context);
    }

    self.allocator.free(module.id);
    self.allocator.free(module.source);
    self.allocator.free(module.hash);
    if (!reloadable) {
        if (module.cleanup) |cleanup| cleanup();
    }
    module.resources.deinit(self.allocator);
}

fn destroyInstance(module: *Module) void {
    if (comptime reloadable) {
        if (module.instance) |*instance| {
            instance.deinit();
            module.instance = null;
        }
    }
}

pub const Descriptor = struct { id: []const u8, generation: u64 };

/// Discover the available UI modules. Descriptors are borrowed until the next
/// call; refreshing the catalog never changes a module during its frame call.
pub fn list(self: *Runtime) ![]const Descriptor {
    try self.update();
    std.debug.assert(self.modules.items.len <= Protocol.modules_max);
    std.debug.assert(self.next_generation > 0);
    const descriptors = try self.arena.allocator().alloc(Descriptor, self.modules.items.len);
    for (self.modules.items, descriptors) |module, *descriptor| {
        descriptor.* = .{ .id = module.id, .generation = module.generation };
    }
    return descriptors;
}

pub fn count(self: *const Runtime) u32 {
    return @intCast(self.modules.items.len);
}

pub fn id(self: *const Runtime, index: u32) []const u8 {
    return self.modules.items[index].id;
}

pub fn source(self: *const Runtime, index: u32) []const u8 {
    return self.modules.items[index].source;
}

pub fn generation(self: *const Runtime, index: u32) u64 {
    return self.modules.items[index].generation;
}

fn renderErrorOverlay(self: *Runtime, frame: *ui.Frame) !void {
    if (comptime !reloadable) return;
    const frame_generation = frame.frameGeneration();
    if (self.error_overlay_generation == frame_generation) return;
    self.error_overlay_generation = frame_generation;
    self.error_overlay_active = false;
    const message = self.hmr_error orelse return;
    self.error_overlay_active = true;

    var open = true;
    const dialog: ui.component.Dialog = .{
        .is_open = &open,
        .key = .str("hmr.error.overlay"),
        .close_on_escape = false,
        .close_on_backdrop_press = false,
        // The host overlay packet is composed after every module contribution.
        .z_index = ui.Layer.fromIndex(ui.Frame.host_overlay_layer_min),
        .width = .{ .kind = .fit, .min = 640, .max = 960 },
        .height = .{ .kind = .fit, .max = 720 },
        .panel_style = .{ .color = .elevated, .corner_radius = .lg, .border_color = .@"error", .border_width = .all(2) },
        .backdrop_color = .{ .color = .{ .value = .{ 0, 0, 0, 0.62 } } },
    };
    _ = try dialog.open(frame);
    const title = switch (self.hmr_error_kind) {
        .compile => "HMR build failed",
        .update => "HMR update failed",
    };
    try frame.e(ui.component.Text{ .content = title, .size = .lg, .color = .@"error", .selectable = false, .key = .str("hmr.error.overlay.title") });
    try frame.e(ui.component.Text{ .content = "The last working version is still running. Fix the error and save to retry.", .width = .grow(), .wrap = true, .selectable = false, .key = .str("hmr.error.overlay.reason") });
    try frame.e(ui.component.Text{ .content = message, .width = .grow(), .wrap = true, .size = .xs, .selectable = false, .key = .str("hmr.error.overlay.details") });
    try dialog.close(frame);
}

fn update(self: *Runtime) !void {
    _ = self.arena.reset(.retain_capacity);

    if (!reloadable) return;
    if (comptime browser_host) {
        const revision = Instance.revision();
        if (revision == self.browser_revision) return;
        const status = try Instance.status(self.arena.allocator());
        const manifest = try Instance.manifest(self.arena.allocator());
        try self.refreshStatusBytes(status);
        try self.refreshBytes(manifest);
        self.browser_revision = revision;
        return;
    }
    const manifest_changed = self.manifest_dirty.swap(false, .acq_rel);
    if (!manifest_changed) return;
    self.refreshStatus() catch |err| {
        self.manifest_dirty.store(true, .release);
        std.log.warn(
            "ts={f} component=hmr-runtime event=status_refresh_failed error={s} action=retain_current_ui",
            .{ Log.timestamp(self.io), @errorName(err) },
        );
    };
    self.refresh() catch |err| {
        self.manifest_dirty.store(true, .release);
        std.log.warn(
            "ts={f} component=hmr-runtime event=manifest_refresh_failed error={s} action=retain_current_ui",
            .{ Log.timestamp(self.io), @errorName(err) },
        );
    };
}

fn refreshStatus(self: *Runtime) !void {
    std.debug.assert(self.status_path.len > 0);
    const allocator = self.arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.status_path, allocator, .limited(Status.bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try self.refreshStatusBytes(bytes);
}

fn refreshStatusBytes(self: *Runtime, bytes: []const u8) !void {
    const allocator = self.arena.allocator();
    if (bytes.len == 0) return;
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (self.status_loaded) {
        if (hash == self.status_hash) return;
    }
    const parsed = try std.json.parseFromSlice(Status.Value, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .max_value_len = Status.bytes_max });
    if (!Status.valid(&parsed.value)) return error.InvalidHmrStatus;

    if (std.mem.eql(u8, parsed.value.kind, Status.kind_ready)) {
        self.clearHmrError();
    } else {
        const message = try self.allocator.dupe(u8, parsed.value.message);
        errdefer self.allocator.free(message);
        self.clearHmrError();
        self.hmr_error = message;
        self.hmr_error_kind = if (std.mem.eql(u8, parsed.value.kind, Status.kind_compile_error)) .compile else .update;
        std.log.warn(
            "ts={f} component=hmr-runtime event=hmr_error phase={s} kind={s} diagnostics_bytes={d} action=display_error_ui",
            .{ Log.timestamp(self.io), parsed.value.phase, parsed.value.kind, parsed.value.message.len },
        );
    }
    self.status_hash = hash;
    self.status_loaded = true;
}

fn clearHmrError(self: *Runtime) void {
    if (self.hmr_error) |message| {
        self.allocator.free(message);
        self.hmr_error = null;
    }
}

fn refresh(self: *Runtime) !void {
    const allocator = self.arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.manifest_path, allocator, .limited(Protocol.bytes_max)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try self.refreshBytes(bytes);
}

fn refreshBytes(self: *Runtime, bytes: []const u8) !void {
    const allocator = self.arena.allocator();
    const started_at = std.Io.Clock.awake.now(self.io);
    if (bytes.len == 0) return;
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (self.manifest_loaded) {
        if (hash == self.manifest_hash) return;
    }
    const reload = self.manifest_loaded;
    const phase = if (reload) "reload" else "initial";
    const manifest = try std.json.parseFromSlice(Protocol.Manifest, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = Protocol.bytes_max });
    if (manifest.value.modules.len > Protocol.modules_max) return error.TooManyModules;
    for (manifest.value.modules, 0..) |entry, index| {
        if (!Protocol.validId(entry.id)) return error.InvalidModuleId;
        if (entry.hash.len != 64) return error.InvalidHash;
        for (manifest.value.modules[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateModuleId;
        }
    }
    try self.modules.ensureTotalCapacity(self.allocator, Protocol.modules_max);
    var added_modules: u32 = 0;
    var updated_modules: u32 = 0;
    var unchanged_modules: u32 = 0;
    var removed_modules: u32 = 0;
    var rejected_modules: u32 = 0;
    var changed_ids: std.ArrayList([]const u8) = .empty;
    var removed_ids: std.ArrayList([]const u8) = .empty;
    var rejected_ids: std.ArrayList([]const u8) = .empty;
    // Match IDs rather than positions so changes never reset unrelated stores.
    for (manifest.value.modules) |entry| {
        const existing = self.find(entry.id);
        if (existing) |index| {
            if (std.mem.eql(u8, self.modules.items[index].hash, entry.hash)) {
                unchanged_modules += 1;
                continue;
            }
        }
        const candidate = self.prepare(&entry) catch |err| {
            rejected_modules += 1;
            try rejected_ids.append(allocator, entry.id);
            std.log.warn(
                "ts={f} component=hmr-runtime event=module_rejected module_id={s} error={s} action=display_error_ui",
                .{ Log.timestamp(self.io), entry.id, @errorName(err) },
            );
            const failure: Failure = .{ .operation = "load", .error_name = @errorName(err) };
            if (existing) |index| {
                const requested_hash = try self.allocator.dupe(u8, entry.hash);
                const active = &self.modules.items[index];
                destroyInstance(active);
                self.allocator.free(active.hash);
                active.hash = requested_hash;
                active.failure = failure;
            } else {
                self.modules.appendAssumeCapacity(try self.failedModule(&entry, failure));
            }
            continue;
        };
        try changed_ids.append(allocator, entry.id);
        if (existing) |index| {
            const active = &self.modules.items[index];
            self.destroyModule(active);
            active.* = candidate;
            updated_modules += 1;
        } else {
            self.modules.appendAssumeCapacity(candidate);
            added_modules += 1;
        }
    }
    var index: usize = 0;
    while (index < self.modules.items.len) {
        var present = false;
        for (manifest.value.modules) |entry| {
            if (std.mem.eql(u8, entry.id, self.modules.items[index].id)) {
                present = true;
                break;
            }
        }
        if (present) {
            index += 1;
        } else {
            const removed_id = try allocator.dupe(u8, self.modules.items[index].id);
            try removed_ids.append(allocator, removed_id);
            removed_modules += 1;
            self.destroyModule(&self.modules.items[index]);
            _ = self.modules.orderedRemove(index);
        }
    }
    self.manifest_hash = hash;
    self.manifest_loaded = true;
    std.debug.assert(added_modules + updated_modules + unchanged_modules + rejected_modules == manifest.value.modules.len);
    std.debug.assert(self.modules.items.len <= Protocol.modules_max);
    if (reload) {
        std.log.info(
            "ts={f} component=hmr-runtime event=hmr_applied phase={s} modules={d} added={d} updated={d} removed={d} rejected={d} changed_ids={f} removed_ids={f} rejected_ids={f} duration_ms={d}",
            .{
                Log.timestamp(self.io),
                phase,
                self.modules.items.len,
                added_modules,
                updated_modules,
                removed_modules,
                rejected_modules,
                Log.IdListFormatter{ .ids = changed_ids.items },
                Log.IdListFormatter{ .ids = removed_ids.items },
                Log.IdListFormatter{ .ids = rejected_ids.items },
                Log.elapsedMilliseconds(self.io, started_at),
            },
        );
    } else {
        std.log.info(
            "ts={f} component=hmr-runtime event=hmr_ready modules={d} duration_ms={d}",
            .{ Log.timestamp(self.io), self.modules.items.len, Log.elapsedMilliseconds(self.io, started_at) },
        );
    }
}

fn nextModuleGeneration(self: *Runtime) !u64 {
    if (self.next_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    const assigned_generation = self.next_generation;
    self.next_generation += 1;
    std.debug.assert(assigned_generation > 0);
    std.debug.assert(self.next_generation > assigned_generation);
    return assigned_generation;
}

fn failedModule(self: *Runtime, entry: *const Protocol.Entry, failure: Failure) !Module {
    std.debug.assert(entry.id.len > 0);
    std.debug.assert(entry.hash.len == 64);
    std.debug.assert(failure.operation.len > 0);
    std.debug.assert(failure.error_name.len > 0);
    const name = try self.allocator.dupe(u8, entry.id);
    errdefer self.allocator.free(name);
    const source_text = try self.allocator.dupe(u8, "");
    errdefer self.allocator.free(source_text);
    const hash = try self.allocator.dupe(u8, entry.hash);
    errdefer self.allocator.free(hash);
    return .{
        .id = name,
        .source = source_text,
        .hash = hash,
        .generation = try self.nextModuleGeneration(),
        .native = {},
        .resources = .init(),
        .failure = failure,
    };
}

fn prepare(self: *Runtime, entry: *const Protocol.Entry) !Module {
    std.debug.assert(entry.id.len > 0);
    std.debug.assert(entry.hash.len == 64);
    var instance = if (comptime browser_host) blk: {
        break :blk try Instance.init(entry.id, entry.hash);
    } else blk: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, entry.path, self.arena.allocator(), .limited(32 * 1024 * 1024));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, entry.hash, &std.fmt.bytesToHex(digest, .lower))) return error.HashMismatch;
        break :blk try Instance.init(bytes, .{});
    };
    var instance_live = true;
    errdefer if (instance_live) instance.deinit();
    const name = try self.allocator.dupe(u8, entry.id);
    errdefer self.allocator.free(name);
    const hash = try self.allocator.dupe(u8, entry.hash);
    errdefer self.allocator.free(hash);
    const source_text = try instance.staticString(self.allocator, "source");
    errdefer self.allocator.free(source_text);
    const assigned_generation = try self.nextModuleGeneration();
    instance_live = false;
    return .{ .id = name, .source = source_text, .hash = hash, .instance = instance, .generation = assigned_generation, .native = {}, .resources = .init() };
}

fn find(self: *const Runtime, name: []const u8) ?u32 {
    for (self.modules.items, 0..) |module, index| {
        if (std.mem.eql(u8, module.id, name)) return @intCast(index);
    }
    return null;
}

/// Render a module using the build-selected execution mode.
/// Native modules run in the host frame; reloadable modules use an isolated
/// child frame and serialized transport.
pub fn render(self: *Runtime, index: u32, frame: *ui.Frame) !void {
    try self.renderErrorOverlay(frame);
    if (comptime !reloadable) {
        std.debug.assert(index < self.modules.items.len);
        const module = &self.modules.items[index];
        std.debug.assert(@intFromPtr(module.native) > 0);
        try module.native(frame);
        return;
    }

    const module = &self.modules.items[index];
    const Invocation = struct {
        runtime: *Runtime,
        index: u32,
        state_scope: u64,
        fn draw(pointer: *anyopaque, input: *const FrameInput, state: []const ui.StateBridge.Value, rectangle: math.Rect, allocator: std.mem.Allocator) !ui.Frame.ModuleOutput {
            const invocation: *@This() = @ptrCast(@alignCast(pointer));
            return invocation.runtime.renderFrame(invocation.index, invocation.state_scope, input, state, rectangle, allocator);
        }
    };
    const identity = std.hash.Wyhash.hash(module.generation, module.id);
    const invocation = try frame.arena().create(Invocation);
    invocation.* = .{ .runtime = self, .index = index, .state_scope = ui.StateBridge.key(module.id) };
    try frame.contribute(ui.Key.str(try std.fmt.allocPrint(frame.arena(), "knots.module:{s}", .{module.id})).indexed(@intCast(module.generation)), identity, invocation, Invocation.draw);
}

fn renderFrame(self: *Runtime, index: u32, state_scope: u64, input: *const FrameInput, state: []const ui.StateBridge.Value, rectangle: math.Rect, allocator: std.mem.Allocator) !ui.Frame.ModuleOutput {
    std.debug.assert(index < self.modules.items.len);
    const active = &self.modules.items[index];
    if (self.hmr_error) |message| {
        if (!self.error_overlay_active) return self.renderHmrError(active, message, input, rectangle, allocator);
    }
    if (active.failure) |failure| return self.renderFailure(active, failure, input, rectangle, allocator);
    return self.renderFrameOutput(index, state_scope, input, state, rectangle, allocator) catch |err| {
        if (!@import("builtin").is_test) {
            std.log.warn(
                "ts={f} component=hmr-runtime event=module_frame_failed module_id={s} error={s} action=display_error_ui",
                .{ Log.timestamp(self.io), active.id, @errorName(err) },
            );
        }
        destroyInstance(active);
        active.failure = .{ .operation = "render", .error_name = @errorName(err) };
        return self.renderFailure(active, active.failure.?, input, rectangle, allocator);
    };
}

fn errorContext(self: *Runtime, module: *Module) !*ui.Context {
    if (module.error_context) |context| return context;
    const context = try self.allocator.create(ui.Context);
    errdefer self.allocator.destroy(context);
    context.* = try ui.Context.init(self.allocator, .{});
    module.error_context = context;
    return context;
}

fn renderFailure(self: *Runtime, module: *Module, failure: Failure, input: *const FrameInput, rectangle: math.Rect, allocator: std.mem.Allocator) !ui.Frame.ModuleOutput {
    std.debug.assert(module.failure != null);
    std.debug.assert(failure.operation.len > 0);
    std.debug.assert(failure.error_name.len > 0);
    std.debug.assert(rectangle.w() > 0);
    std.debug.assert(rectangle.h() > 0);
    const context = try self.errorContext(module);
    var error_frame = try context.beginFrame(input.*);
    defer error_frame.deinit();
    const title = try std.fmt.allocPrint(error_frame.arena(), "HMR module failed: {s}", .{module.id});
    const reason = try std.fmt.allocPrint(error_frame.arena(), "Could not {s} the module: {s}", .{ failure.operation, failure.error_name });
    const panel: ui.component.Rect = .{
        .width = .fixed(@floatFromInt(input.logical_extent.width)),
        .height = .fixed(@floatFromInt(input.logical_extent.height)),
        .padding = .init(16, 16, 16, 16),
        .dir = .column,
        .gap = 8,
        .style = .{ .color = .elevated, .corner_radius = .lg, .border_width = .all(1), .border_color = .@"error" },
        .key = .str("hmr.error.panel"),
    };
    _ = try panel.open(&error_frame);
    try error_frame.e(ui.component.Text{ .content = title, .size = .lg, .color = .@"error", .selectable = false, .key = .str("hmr.error.title") });
    try error_frame.e(ui.component.Text{ .content = reason, .width = .grow(), .wrap = true, .selectable = false, .key = .str("hmr.error.reason") });
    try error_frame.e(ui.component.Text{ .content = "Fix the module and save to retry.", .width = .grow(), .color = .dimmed, .selectable = false, .key = .str("hmr.error.action") });
    try panel.close(&error_frame);
    const output = try context.endFrame(&error_frame);
    return .{ .packet = try support.Panels.place(allocator, self.allocator, &module.resources, &output.packet, rectangle) };
}

fn renderHmrError(self: *Runtime, module: *Module, message: []const u8, input: *const FrameInput, rectangle: math.Rect, allocator: std.mem.Allocator) !ui.Frame.ModuleOutput {
    std.debug.assert(self.hmr_error != null);
    std.debug.assert(message.len > 0);
    std.debug.assert(rectangle.w() > 0);
    std.debug.assert(rectangle.h() > 0);
    const context = try self.errorContext(module);
    var error_frame = try context.beginFrame(input.*);
    defer error_frame.deinit();
    const title = switch (self.hmr_error_kind) {
        .compile => "HMR build failed",
        .update => "HMR update failed",
    };
    const panel: ui.component.Rect = .{
        .width = .fixed(@floatFromInt(input.logical_extent.width)),
        .height = .fixed(@floatFromInt(input.logical_extent.height)),
        .padding = .init(16, 16, 16, 16),
        .dir = .column,
        .gap = 8,
        .style = .{ .color = .elevated, .corner_radius = .lg, .border_width = .all(1), .border_color = .@"error" },
        .key = .str("hmr.error.panel"),
    };
    _ = try panel.open(&error_frame);
    try error_frame.e(ui.component.Text{ .content = title, .size = .lg, .color = .@"error", .selectable = false, .key = .str("hmr.error.title") });
    try error_frame.e(ui.component.Text{ .content = "The last working version is still running. Fix the error and save to retry.", .width = .grow(), .wrap = true, .selectable = false, .key = .str("hmr.error.reason") });
    const diagnostics: ui.component.Rect = .{
        .width = .grow(),
        .height = .grow(),
        .padding = .init(8, 8, 8, 8),
        .overflow = .scroll_y,
        .dir = .column,
        .style = .{ .color = .bg, .corner_radius = .sm },
        .key = .str("hmr.error.diagnostics"),
    };
    _ = try diagnostics.open(&error_frame);
    try error_frame.e(ui.component.Text{ .content = message, .width = .grow(), .wrap = true, .size = .xs, .selectable = false, .key = .str("hmr.error.details") });
    try diagnostics.close(&error_frame);
    try panel.close(&error_frame);
    const output = try context.endFrame(&error_frame);
    return .{ .packet = try support.Panels.place(allocator, self.allocator, &module.resources, &output.packet, rectangle) };
}

fn renderFrameOutput(self: *Runtime, index: u32, state_scope: u64, input: *const FrameInput, state: []const ui.StateBridge.Value, rectangle: math.Rect, allocator: std.mem.Allocator) !ui.Frame.ModuleOutput {
    comptime std.debug.assert(reloadable);
    const module = &self.modules.items[index];
    const request: support.FrameProtocol.Request = .{ .frame = input.*, .state_scope = state_scope, .state = state };
    var response: support.FrameProtocol.Response = undefined;
    var writer: support.Wire.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try support.FrameProtocol.encodeRequest(&writer, &request);
    const instance = if (module.instance) |*value| value else return error.ModuleUnavailable;
    const bytes = try instance.frame(allocator, writer.data.items);
    response = try support.FrameProtocol.decodeResponse(allocator, bytes);
    response.contribution.packet = try support.Panels.place(allocator, self.allocator, &module.resources, &response.contribution.packet, rectangle);
    return .{
        .packet = response.contribution.packet,
        .cursor_shape = response.effects.cursor_shape,
        .capture_pointer = response.effects.capture_pointer,
        .capture_keyboard = response.effects.capture_keyboard,
        .text_input = response.effects.text_input,
        .redraw = response.effects.redraw,
        .close = response.effects.close,
        .clipboard_write = response.effects.clipboard_write,
        .state = response.state,
        .dependencies = response.dependencies,
    };
}

test "real Frame executes in isolated guests and replacing one preserves the other" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var left = try Instance.init(@embedFile("fixture_wasm"), .{});
    defer left.deinit();
    var right = try Instance.init(@embedFile("fixture_wasm"), .{});
    defer right.deinit();
    var writer: support.Wire.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    const request: support.FrameProtocol.Request = .{
        .frame = .{
            .input = .{ .pos = .{ -1, -1 } },
            .now_ms = 0,
            .delta_ns = 0,
            .logical_extent = .{ .width = 100, .height = 100 },
            .physical_extent = .{ .width = 100, .height = 100 },
            .content_scale = 1,
        },
        .state_scope = 1,
    };
    try support.FrameProtocol.encodeRequest(&writer, &request);
    for ([_]f32{ 1, 2 }) |expected| {
        const bytes = try right.frame(arena.allocator(), writer.data.items);
        const output = try support.FrameProtocol.decodeResponse(arena.allocator(), bytes);
        try expectInstanceWidth(&output.contribution.packet, expected);
    }
    // A malformed replacement never requires touching the surviving store.
    try std.testing.expectError(error.WasmtimeFailure, Instance.init("invalid wasm", .{}));
    left.deinit();
    left = try Instance.init(@embedFile("fixture_wasm"), .{});
    const left_bytes = try left.frame(arena.allocator(), writer.data.items);
    const left_output = try support.FrameProtocol.decodeResponse(arena.allocator(), left_bytes);
    try expectInstanceWidth(&left_output.contribution.packet, 1);
    const right_bytes = try right.frame(arena.allocator(), writer.data.items);
    const right_output = try support.FrameProtocol.decodeResponse(arena.allocator(), right_bytes);
    try expectInstanceWidth(&right_output.contribution.packet, 3);
    try std.testing.expectError(error.InvalidWire, support.FrameProtocol.decodeResponse(arena.allocator(), right_bytes[0 .. right_bytes.len - 1]));
}

test "failed modules display an error panel and recover after a fix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const storage = arena.allocator();
    const original = @embedFile("fixture_wasm");
    try temporary.dir.writeFile(io, .{ .sub_path = "counter.wasm", .data = original, .flags = .{} });
    const artifact = try temporary.dir.realPathFileAlloc(io, "counter.wasm", storage);
    const manifest = try std.fs.path.join(storage, &.{ std.fs.path.dirname(artifact).?, "manifest.json" });
    const status = try std.fs.path.join(storage, &.{ std.fs.path.dirname(artifact).?, "status.json" });
    var environment_map = std.process.Environ.Map.init(allocator);
    defer environment_map.deinit();
    try environment_map.put(manifest_environment_name, manifest);
    try environment_map.put(status_environment_name, status);
    try testStatus(storage, io, status, .{ .kind = Status.kind_ready, .phase = "initial" });
    const runtime = try Runtime.create(allocator, io, &environment_map);
    defer runtime.destroy();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    var entries = [_]Protocol.Entry{
        .{ .id = "test/left", .path = artifact, .hash = &hash },
        .{ .id = "test/right", .path = artifact, .hash = &hash },
    };
    _ = runtime.arena.reset(.retain_capacity);
    try testPublish(storage, io, manifest, &entries);
    try runtime.refresh();
    try std.testing.expectEqual(@as(u32, 2), runtime.count());
    const generation_left = runtime.generation(0);
    const generation_right = runtime.generation(1);
    var input: FrameInput = .{
        .input = .{ .pos = .{ -1, -1 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 100, .height = 100 },
        .physical_extent = .{ .width = 100, .height = 100 },
        .content_scale = 1,
    };
    const rectangle = math.Rect.init(0, 0, 100, 100);
    _ = try runtime.renderFrame(0, 1, &input, &.{}, rectangle, storage);
    _ = try runtime.renderFrame(1, 2, &input, &.{}, rectangle, storage);

    try testStatus(storage, io, status, .{ .kind = Status.kind_compile_error, .phase = "reload", .message = "error: expected expression" });
    try runtime.refreshStatus();
    try std.testing.expect(runtime.hmr_error != null);
    const build_failure = try runtime.renderFrame(0, 1, &input, &.{}, rectangle, storage);
    try std.testing.expect(build_failure.packet.textInstances().len > 0);
    try testStatus(storage, io, status, .{ .kind = Status.kind_ready, .phase = "reload" });
    try runtime.refreshStatus();
    try std.testing.expect(runtime.hmr_error == null);

    const broken = "not a wasm module";
    try temporary.dir.writeFile(io, .{ .sub_path = "broken.wasm", .data = broken, .flags = .{} });
    const broken_artifact = try temporary.dir.realPathFileAlloc(io, "broken.wasm", storage);
    entries[0].path = broken_artifact;
    std.crypto.hash.sha2.Sha256.hash(broken, &digest, .{});
    const broken_hash = std.fmt.bytesToHex(digest, .lower);
    entries[0].hash = &broken_hash;
    try testPublish(storage, io, manifest, &entries);
    try runtime.refresh();
    const load_failure = try runtime.renderFrame(0, 1, &input, &.{}, rectangle, storage);
    try std.testing.expect(load_failure.packet.textInstances().len > 0);
    try std.testing.expectEqual(generation_left, runtime.generation(0));

    // A valid replacement can still fail on its first real frame.
    const replacement = original ++ "\x00\x04\x03alt";
    try temporary.dir.writeFile(io, .{ .sub_path = "replacement.wasm", .data = replacement, .flags = .{} });
    entries[0].path = try temporary.dir.realPathFileAlloc(io, "replacement.wasm", storage);
    std.crypto.hash.sha2.Sha256.hash(replacement, &digest, .{});
    const replacement_hash = std.fmt.bytesToHex(digest, .lower);
    entries[0].hash = &replacement_hash;
    try testPublish(storage, io, manifest, &entries);
    try runtime.refresh();
    try std.testing.expect(runtime.generation(0) != generation_left);
    try std.testing.expectEqual(generation_right, runtime.generation(1));
    input.logical_extent.width = 13;
    const frame_failure = try runtime.renderFrame(0, 1, &input, &.{}, .init(0, 0, 13, 100), storage);
    try std.testing.expect(frame_failure.packet.textInstances().len > 0);
    const neighbor = try runtime.renderFrame(1, 2, &input, &.{}, .init(0, 0, 13, 100), storage);
    try expectInstanceWidth(&neighbor.packet, 2);

    entries[0].path = artifact;
    entries[0].hash = &hash;
    try testPublish(storage, io, manifest, &entries);
    try runtime.refresh();
    input.logical_extent.width = 100;
    const restored = try runtime.renderFrame(0, 1, &input, &.{}, rectangle, storage);
    try expectInstanceWidth(&restored.packet, 1);

    try testPublish(storage, io, manifest, entries[1..]);
    try runtime.refresh();
    try std.testing.expectEqual(@as(u32, 1), runtime.count());
    try std.testing.expectEqual(generation_right, runtime.generation(0));
}

fn testPublish(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const Protocol.Entry) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, Protocol.Manifest{ .modules = entries }, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}

fn testStatus(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: Status.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}

fn expectInstanceWidth(packet: anytype, expected: f32) !void {
    for (packet.instances()) |instance| {
        if (instance.size[0] == expected) return;
    }
    return error.ExpectedInstanceWidthNotFound;
}
