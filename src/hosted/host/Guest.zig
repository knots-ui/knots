const std = @import("std");
const wasmtime = @import("wasmtime");
const abi = @import("abi");
const Workers = @import("Workers.zig");
const wasm_module = @import("module.zig");

const Guest = @This();
const log = std.log.scoped(.dev_host);

/// Stops a call that does not return.
const fuel_per_call: u64 = 4_000_000_000;
const memory_bytes: i64 = 1024 * 1024 * 1024;

pub const Problem = enum(u32) { none, build_failed, crashed };

pub const Runtime = struct {
    engine: wasmtime.Engine,
    linker: wasmtime.Linker,

    pub fn deinit(self: *Runtime) void {
        self.linker.deinit();
        self.engine.deinit();
    }
};

pub const Error = error{ Trapped, MissingExport, OutOfMemory };

gpa: std.mem.Allocator,
runtime: *Runtime,
store: wasmtime.Store,
instance: wasmtime.Instance,
module: wasmtime.Module,
memory: union(enum) {
    own: wasmtime.Memory,
    shared: wasmtime.SharedMemory,
},
workers: ?*Workers = null,
trap: ?[]u8 = null,

pub fn init(gpa: std.mem.Allocator, runtime: *Runtime, prepared: wasm_module.Prepared) !Guest {
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    errdefer logDiagnostics(gpa, "load_failed", &diagnostics);

    var compiled = try wasmtime.Module.init(runtime.engine, prepared.bytes, &diagnostics);
    errdefer compiled.deinit();
    var shared: ?wasmtime.SharedMemory = if (prepared.shared)
        try wasmtime.SharedMemory.init(runtime.engine, prepared.memory_minimum, prepared.memory_maximum, &diagnostics)
    else
        null;
    errdefer if (shared) |*memory| memory.deinit();

    var store = try wasmtime.Store.init(runtime.engine, &.{
        .memory_bytes = memory_bytes,
        .table_elements = 1 << 20,
        .instances = 1,
        .tables = 4,
        .memories = 1,
    });
    errdefer store.deinit();
    store.setFuel(fuel_per_call, null) catch {};
    if (shared) |memory| try runtime.linker.defineSharedMemory(&store, "env", "memory", memory, &diagnostics);
    const instance = try runtime.linker.instantiate(&store, &compiled, &diagnostics);
    return .{
        .gpa = gpa,
        .runtime = runtime,
        .store = store,
        .instance = instance,
        .module = compiled,
        .memory = if (shared) |memory| .{ .shared = memory } else .{ .own = try instance.memory("memory") },
    };
}

pub fn deinit(self: *Guest) void {
    if (self.workers) |workers| workers.stop();
    self.store.deinit();
    self.module.deinit();
    switch (self.memory) {
        .own => {},
        .shared => |*memory| memory.deinit(),
    }
    if (self.trap) |message| self.gpa.free(message);
}

pub fn call(self: *Guest, name: []const u8, arguments: []const u32, comptime Result: type) Error!Result {
    const result = try self.invoke(name, arguments, Result);
    try self.invoke("knots_hosted_flush", &.{}, void);
    return result;
}

fn invoke(self: *Guest, name: []const u8, arguments: []const u32, comptime Result: type) Error!Result {
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    const function = self.instance.function(name) catch return error.MissingExport;
    self.store.setFuel(fuel_per_call, null) catch {};
    var values: [4]wasmtime.Value = undefined;
    for (arguments, values[0..arguments.len]) |argument, *value| value.* = int(argument);
    var results: [1]wasmtime.Value = undefined;
    const result_count: usize = if (Result == void) 0 else 1;
    function.call(values[0..arguments.len], results[0..result_count], &diagnostics) catch {
        const message = diagnostics.message(self.gpa) catch "";
        defer self.gpa.free(message);
        log.err("event=guest_trapped export={s} {s}", .{ name, message });
        if (self.trap == null) self.trap = try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ name, message });
        return error.Trapped;
    };
    if (Result == void) return;
    defer wasmtime.unrootValues(results[0..1]);
    return @bitCast(results[0].of.i32);
}

pub fn range(self: *Guest, pointer: u32, length: u32) []u8 {
    return switch (self.memory) {
        .own => |memory| memory.range(pointer, length),
        .shared => |memory| memory.range(pointer, length),
    } catch &.{};
}

pub fn frame(self: *Guest, window: abi.Window, input: []const u8) Error!void {
    try self.write("knots_hosted_buffer", input);
    try self.call("knots_hosted_frame", &.{@backingInt(window)}, void);
}

pub fn saveState(self: *Guest) Error!?[]u8 {
    const length = try self.call("knots_dev_save", &.{}, u32);
    if (length == 0) return null;
    // The buffer has the state, and keeps it at its length.
    const pointer = try self.call("knots_dev_buffer", &.{length}, u32);
    return try self.gpa.dupe(u8, self.range(pointer, length));
}

pub fn loadState(self: *Guest, state: []const u8) Error!void {
    try self.write("knots_dev_buffer", state);
    try self.call("knots_dev_load", &.{}, void);
}

pub fn showProblem(self: *Guest, problem: Problem, details: []const u8) Error!void {
    try self.write("knots_dev_buffer", details);
    try self.call("knots_dev_problem", &.{@backingInt(problem)}, void);
}

fn write(self: *Guest, buffer: []const u8, bytes: []const u8) Error!void {
    const pointer = try self.call(buffer, &.{@intCast(bytes.len)}, u32);
    if (pointer == 0) return error.OutOfMemory;
    @memcpy(self.range(pointer, @intCast(bytes.len)), bytes);
}

pub fn spawn(self: *Guest, io: std.Io, job: Workers.Job, context: *anyopaque, wake: *const fn (*anyopaque) void) bool {
    const memory = switch (self.memory) {
        .shared => |memory| memory,
        .own => return false,
    };
    const workers = self.workers orelse workers: {
        self.workers = Workers.create(self.gpa, io, context, wake) catch return false;
        break :workers self.workers.?;
    };
    return workers.spawn(job, .{
        .engine = self.runtime.engine,
        .linker = &self.runtime.linker,
        .module = &self.module,
        .memory = memory,
        .main = &self.instance,
    });
}

pub fn releaseTasks(self: *Guest) Error!usize {
    const workers = self.workers orelse return 0;
    var finished: std.ArrayList(u32) = .empty;
    defer finished.deinit(self.gpa);
    workers.takeCompletions(&finished);
    for (finished.items) |task| try self.call("knots_worker_release", &.{task}, void);
    return finished.items.len;
}

fn int(value: u32) wasmtime.Value {
    return .{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(value) } };
}

fn logDiagnostics(gpa: std.mem.Allocator, event: []const u8, diagnostics: *wasmtime.Diagnostics) void {
    const message = diagnostics.message(gpa) catch "";
    defer gpa.free(message);
    log.err("event={s} {s}", .{ event, message });
}
