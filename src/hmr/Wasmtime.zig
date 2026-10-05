//! One HMR module, run natively in its own store.

const std = @import("std");
const hmr = @import("hmr");
const wasmtime = @import("wasmtime");

const fuel_per_call: u64 = 100_000_000;
const memory_bytes: u32 = 256 * 1024 * 1024;

var shared_engine: ?wasmtime.Engine = null;

const Wasmtime = @This();

store: wasmtime.Store,
instance: wasmtime.Instance,
memory: wasmtime.Memory,

pub fn initEngine() !void {
    if (shared_engine != null)
        return;

    // Winch compiles 4x faster than Cranelift. Its code is 3-4x slower, but
    // module frames take less than 2 ms.
    shared_engine = try wasmtime.Engine.init(.{ .consume_fuel = true, .compiler = .winch });
}

pub fn init(bytes: []const u8) !Wasmtime {
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    errdefer logDiagnostic(&diagnostics);

    const engine = shared_engine orelse return error.EngineNotInitialized;
    var store = try wasmtime.Store.init(engine, &.{
        .memory_bytes = memory_bytes,
        .table_elements = 65536,
        .instances = 1,
        .tables = 1,
        .memories = 1,
    });
    errdefer store.deinit();

    var module = try wasmtime.Module.init(engine, bytes, &diagnostics);
    defer module.deinit();

    try store.setFuel(fuel_per_call, &diagnostics);
    const instance = wasmtime.Instance.init(&store, &module, &.{}, &diagnostics) catch |err| return mapError(err);
    const memory = instance.memory("memory") catch |err| return mapError(err);

    var self: Wasmtime = .{ .store = store, .instance = instance, .memory = memory };

    if (try self.call("knots_hmr_fingerprint", null) != hmr.fingerprint)
        return error.HostOutdated;

    if (try self.call("knots_hmr_init", null) != 0)
        return error.GuestInitFailed;

    return self;
}

pub fn deinit(self: *Wasmtime) void {
    self.store.deinit();
    self.* = undefined;
}

pub fn frame(self: *Wasmtime, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    return self.exchange(allocator, "knots_hmr_frame", request);
}

pub fn snapshotState(self: *Wasmtime, allocator: std.mem.Allocator) ![]u8 {
    return self.exchange(allocator, "knots_hmr_snapshot", null);
}

pub fn restoreState(self: *Wasmtime, allocator: std.mem.Allocator, snapshot: []const u8) ![]u8 {
    return self.exchange(allocator, "knots_hmr_restore", snapshot);
}

pub fn source(self: *Wasmtime, allocator: std.mem.Allocator) ![]u8 {
    const offset = try self.call("knots_hmr_source", null);
    const length = try self.call("knots_hmr_source_length", null);
    return self.copyOut(allocator, offset, length);
}

fn exchange(self: *Wasmtime, allocator: std.mem.Allocator, comptime name: []const u8, payload: ?[]const u8) ![]u8 {
    if (payload) |bytes| {
        const offset = try self.call("knots_hmr_input", @intCast(bytes.len));
        if (offset == 0)
            return error.GuestAllocationFailed;

        @memcpy(try self.range(offset, @intCast(bytes.len)), bytes);
    }

    if (try self.call(name, null) != 0)
        return error.GuestCallFailed;

    const offset = try self.call("knots_hmr_output", null);
    const length = try self.call("knots_hmr_output_length", null);
    return self.copyOut(allocator, offset, length);
}

fn copyOut(self: *Wasmtime, allocator: std.mem.Allocator, offset: u32, length: u32) ![]u8 {
    return allocator.dupe(u8, try self.range(offset, length));
}

fn range(self: *Wasmtime, offset: u32, length: u32) ![]u8 {
    return self.memory.range(offset, length) catch |err| return mapError(err);
}

fn call(self: *Wasmtime, name: []const u8, argument: ?u32) !u32 {
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    errdefer logDiagnostic(&diagnostics);

    const function = self.instance.function(name) catch |err| return mapError(err);
    try self.store.setFuel(fuel_per_call, &diagnostics);
    const arguments = [_]wasmtime.Value{.{
        .kind = wasmtime.c.WASMTIME_I32,
        .of = .{ .i32 = @bitCast(argument orelse 0) },
    }};
    const passed: []const wasmtime.Value = if (argument != null)
        &arguments
    else
        &.{};

    var results: [1]wasmtime.Value = undefined;
    function.call(passed, &results, &diagnostics) catch |err| return mapError(err);
    defer wasmtime.unrootValues(&results);

    if (results[0].kind != wasmtime.c.WASMTIME_I32)
        return error.InvalidResult;

    return @bitCast(results[0].of.i32);
}

fn mapError(err: wasmtime.Error) (wasmtime.Error || error{ GuestTrap, InvalidExport, InvalidGuestRange }) {
    return switch (err) {
        error.Trap => error.GuestTrap,
        error.WrongExportType => error.InvalidExport,
        error.InvalidMemoryRange => error.InvalidGuestRange,
        else => err,
    };
}

fn logDiagnostic(diagnostics: *const wasmtime.Diagnostics) void {
    if (@import("builtin").is_test)
        return;

    const message = diagnostics.message(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(message);

    if (message.len > 0)
        std.log.warn("wasmtime: {s}", .{message});
}
