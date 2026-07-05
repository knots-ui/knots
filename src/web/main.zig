const std = @import("std");
const js = @import("js-bridge");

const error_buffer_len = 2048;

var last_error_buf: [error_buffer_len]u8 = @splat(0);
var last_error_len: usize = 0;

const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = now;
    table.clockResolution = clockResolution;
    table.groupConcurrent = groupConcurrent;
    table.recancel = recancel;
    table.swapCancelProtection = swapCancelProtection;
    table.checkCancel = checkCancel;
    table.random = random;
    table.randomSecure = randomSecure;
    break :blk table;
};

pub const io: std.Io = .{
    .userdata = null,
    .vtable = &vtable,
};

fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    switch (clock) {
        .real, .awake, .boot => {
            const host = js.host() catch return .zero;
            defer host.release();
            const result = host.call("nowMs", &.{js.Arg.u32(@intFromEnum(clock))}) catch return .zero;
            defer result.release();
            const ms = result.tryF64() catch return .zero;
            if (!std.math.isFinite(ms) or ms <= 0) return .zero;
            return .fromNanoseconds(@intFromFloat(ms * @as(f64, std.time.ns_per_ms)));
        },
        .cpu_process, .cpu_thread => return .zero,
    }
}

fn clockResolution(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return switch (clock) {
        .real => std.Io.Duration.fromMilliseconds(1),
        .awake, .boot => std.Io.Duration.fromMicroseconds(1),
        .cpu_process, .cpu_thread => error.ClockUnavailable,
    };
}

fn groupConcurrent(
    _: ?*anyopaque,
    _: *std.Io.Group,
    context: []const u8,
    _: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) std.Io.ConcurrentError!void {
    // Browser dispatch is cooperative: work runs immediately on the main thread.
    start(context.ptr);
}

fn recancel(_: ?*anyopaque) void {}

fn swapCancelProtection(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
    return .unblocked;
}

fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

fn random(_: ?*anyopaque, buffer: []u8) void {
    randomSecure(null, buffer) catch @memset(buffer, 0);
}

fn randomSecure(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    if (buffer.len == 0) return;
    const host = js.host() catch return error.EntropyUnavailable;
    defer host.release();
    host.callVoid("randomSecure", &.{js.Arg.bytes(buffer)}) catch return error.EntropyUnavailable;
}

pub fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, format, args) catch "log formatting failed";
    const host = js.host() catch return;
    defer host.release();
    host.callVoid("log", &.{
        js.Arg.u32(switch (level) {
            .err => 3,
            .warn => 2,
            .info => 1,
            .debug => 0,
        }),
        js.Arg.string(message),
    }) catch {};
}

pub fn alloc(len: usize) usize {
    const ptr = js.alloc(len);
    if (ptr == 0 and len != 0) _ = fail(error.OutOfMemory);
    return ptr;
}

pub fn free(ptr: usize, len: usize) void {
    js.free(ptr, len);
}

pub fn dispatch(id: u32, args_handle: js.Handle, args_len: u32) void {
    js.dispatch(id, args_handle, args_len);
}

pub fn fail(err: anyerror) i32 {
    setLastErrorFromError(err);
    return -1;
}

pub fn reportFatalError(err: anyerror) void {
    setLastErrorFromError(err);
    const host = js.host() catch return;
    defer host.release();
    host.callVoid("fatalError", &.{js.Arg.string(last_error_buf[0..last_error_len])}) catch {};
}

pub fn setLastError(message: []const u8) void {
    last_error_len = @min(message.len, last_error_buf.len);
    @memcpy(last_error_buf[0..last_error_len], message[0..last_error_len]);
}

pub fn clearLastError() void {
    last_error_len = 0;
}

pub fn lastErrorLen() usize {
    return last_error_len;
}

pub fn lastErrorCopy(ptr: usize, len: usize) usize {
    if (ptr == 0 or len == 0 or last_error_len == 0) return 0;
    const out: [*]u8 = @ptrFromInt(ptr);
    const n = @min(len, last_error_len);
    @memcpy(out[0..n], last_error_buf[0..n]);
    return n;
}

fn setLastErrorFromError(err: anyerror) void {
    if (err == error.JavaScriptException) {
        const msg = js.lastError(std.heap.wasm_allocator) catch {
            setLastError(@errorName(err));
            return;
        };
        defer std.heap.wasm_allocator.free(msg);
        if (msg.len > 0) {
            setLastError(msg);
            return;
        }
    }

    setLastError(@errorName(err));
}

export fn js_bridge_alloc(len: usize) callconv(.{ .wasm_mvp = .{} }) usize {
    return alloc(len);
}

export fn js_bridge_free(ptr: usize, len: usize) callconv(.{ .wasm_mvp = .{} }) void {
    free(ptr, len);
}

export fn js_bridge_dispatch(id: u32, args_handle: js.Handle, args_len: u32) callconv(.{ .wasm_mvp = .{} }) void {
    dispatch(id, args_handle, args_len);
}

export fn js_bridge_pointer_size() callconv(.{ .wasm_mvp = .{} }) u32 {
    return @sizeOf(usize);
}

export fn knots_last_error_len() callconv(.{ .wasm_mvp = .{} }) usize {
    return lastErrorLen();
}

export fn knots_last_error_copy(ptr: usize, len: usize) callconv(.{ .wasm_mvp = .{} }) usize {
    return lastErrorCopy(ptr, len);
}
