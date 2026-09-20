//! Owns one isolated store. Never share a Store between concurrently running calls.
const std = @import("std");
const hmr = @import("hmr");
const wasmtime = @import("wasmtime");

pub const Limits = struct {
    memory_bytes: u32 = 256 * 1024 * 1024,
    fuel_per_call: u64 = 100_000_000,
};

const Self = @This();

engine: wasmtime.Engine,
store: wasmtime.Store,
instance: wasmtime.Instance,
memory: wasmtime.Memory,
limits: Limits,

pub fn init(bytes: []const u8, limits: Limits) !Self {
    if (bytes.len > 32 * 1024 * 1024)
        return error.ModuleTooLarge;
    if (limits.memory_bytes == 0)
        return error.InvalidLimits;
    if (limits.fuel_per_call == 0)
        return error.InvalidLimits;

    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    errdefer logDiagnostic(&diagnostics);

    var engine = try wasmtime.Engine.init(.{ .consume_fuel = true });
    errdefer engine.deinit();

    var store = try wasmtime.Store.init(engine, &.{
        .memory_bytes = limits.memory_bytes,
        .table_elements = 65536,
        .instances = 1,
        .tables = 1,
        .memories = 1,
    });
    errdefer store.deinit();

    var module = try wasmtime.Module.init(engine, bytes, &diagnostics);
    defer module.deinit();

    try store.setFuel(limits.fuel_per_call, &diagnostics);
    const instance = wasmtime.Instance.init(&store, &module, &.{}, &diagnostics) catch |err| return mapError(err);
    const memory = instance.memory("memory") catch |err| switch (err) {
        error.MissingExport => return error.MissingMemory,
        error.WrongExportType => return error.InvalidMemory,
        else => return err,
    };

    var self: Self = .{ .engine = engine, .store = store, .instance = instance, .memory = memory, .limits = limits };
    if (try self.call("knots_hmr_version", null) != hmr.Protocol.version)
        return error.UnsupportedVersion;
    if (try self.call("knots_hmr_init", null) != 0)
        return error.GuestInitFailed;

    return self;
}

pub fn deinit(self: *Self) void {
    // Destroying the store releases all guest allocations even after a trap.
    self.store.deinit();
    self.engine.deinit();
    self.* = undefined;
}

/// The returned bytes belong to the caller, never to the Wasmtime store.
pub fn frame(self: *Self, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    if (request.len > hmr.Protocol.bytes_max)
        return error.LimitExceeded;

    const offset = try self.call("knots_hmr_input", @intCast(request.len));
    if (offset == 0)
        return error.GuestAllocationFailed;

    @memcpy(try self.memoryRange(offset, @intCast(request.len)), request);
    if (try self.call("knots_hmr_frame", null) != 0)
        return error.GuestFrameFailed;

    const output_offset = try self.call("knots_hmr_output", null);
    const output_length = try self.call("knots_hmr_output_length", null);
    if (output_length > hmr.Protocol.bytes_max)
        return error.LimitExceeded;

    return allocator.dupe(u8, try self.memoryRange(output_offset, output_length));
}

pub fn staticString(self: *Self, allocator: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(self.limits.memory_bytes > 0);

    const offset = try self.call("knots_hmr_" ++ name, null);
    const length = try self.call("knots_hmr_" ++ name ++ "_length", null);

    if (length > hmr.Protocol.bytes_max)
        return error.LimitExceeded;

    return allocator.dupe(u8, try self.memoryRange(offset, length));
}

fn memoryRange(self: *Self, offset: u32, length: u32) ![]u8 {
    return self.memory.range(offset, length) catch |err| return mapError(err);
}

fn call(self: *Self, name: []const u8, argument: ?u32) !u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(self.limits.fuel_per_call > 0);

    const function = self.instance.function(name) catch |err| return mapError(err);
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    errdefer logDiagnostic(&diagnostics);

    try self.store.setFuel(self.limits.fuel_per_call, &diagnostics);
    const arguments = [_]wasmtime.Value{.{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(argument orelse 0) } }};

    var results: [1]wasmtime.Value = undefined;
    function.call(if (argument != null) &arguments else &.{}, &results, &diagnostics) catch |err| return mapError(err);
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

    const message = diagnostics.message(std.heap.page_allocator) catch
        return;
    defer std.heap.page_allocator.free(message);

    if (message.len > 0)
        std.log.warn("Wasmtime: {s}", .{message});
}
