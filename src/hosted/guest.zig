const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire");
const imports = @import("imports");
pub const abi = @import("abi");

const threads_enabled = std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
const threads = if (threads_enabled) @import("wasm_threads") else struct {};

pub const allocator = if (threads_enabled) threads.allocator else std.heap.wasm_allocator;

pub const io: std.Io = .{
    .userdata = null,
    .vtable = &vtable,
};

const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = imports.now;
    table.clockResolution = clockResolution;
    table.random = random;
    table.randomSecure = randomSecure;
    if (threads_enabled) threads.install(&table);
    break :blk table;
};

fn clockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return .fromNanoseconds(1);
}

fn random(_: ?*anyopaque, buffer: []u8) void {
    imports.random(buffer);
}

fn randomSecure(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    imports.random(buffer);
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var buffer: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, prefix ++ format, args) catch &buffer;
    imports.log(level, message);
}

pub fn fail(err: anyerror) i32 {
    reportFatalError(err);
    return 1;
}

pub fn reportFatalError(err: anyerror) void {
    imports.log(.err, @errorName(err));
}

var queued: std.ArrayList(u8) = .empty;
var request: std.ArrayList(u8) = .empty;
const queued_bytes_max = 1024 * 1024;

pub fn call(comptime R: type, value: abi.Call) abi.Error!R {
    flush();
    request.clearRetainingCapacity();
    try encode(&request, value);
    var reply_buffer: [1024]u8 = undefined;
    const reply = imports.call(request.items, &reply_buffer);
    // Results hold no pointers.
    return switch (wire.decode(abi.Reply(R), std.mem.Allocator.failing, reply) catch return error.HostCallFailed) {
        .ok => |result| result,
        .failed => |failure| failure.toError(),
    };
}

pub fn queue(command: abi.Command) void {
    encode(&queued, command) catch |err| return std.log.err("hosted: dropped a command: {t}", .{err});
    if (queued.items.len >= queued_bytes_max) flush();
}

export fn knots_hosted_flush() void {
    flush();
}

pub fn flush() void {
    if (queued.items.len == 0) return;
    imports.commands(queued.items);
    queued.clearRetainingCapacity();
}

fn encode(list: *std.ArrayList(u8), value: anytype) abi.Error!void {
    wire.encode(allocator, list, value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.HostCallFailed,
    };
}

var incoming: std.ArrayList(u8) = .empty;

pub fn received() []const u8 {
    return incoming.items;
}

export fn knots_hosted_buffer(length: usize) usize {
    incoming.ensureTotalCapacity(allocator, @max(length, 1)) catch return 0;
    incoming.items.len = length;
    return @intFromPtr(incoming.items.ptr);
}
