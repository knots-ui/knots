const std = @import("std");
const js = @import("js-bridge");
const config = @import("web_config");
const Runtime = if (config.worker_concurrency_enabled) @import("WorkerRuntime.zig") else struct {};

const error_buffer_len = 2048;

var last_error_buf: [error_buffer_len]u8 = @splat(0);
var last_error_len: usize = 0;

const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = now;
    table.clockResolution = clockResolution;
    table.random = random;
    table.randomSecure = randomSecure;
    if (config.worker_concurrency_enabled) {
        table.groupAsync = groupAsync;
        table.groupConcurrent = groupConcurrent;
        table.recancel = recancel;
        table.swapCancelProtection = swapCancelProtection;
        table.checkCancel = checkCancel;
        table.sleep = sleep;
        table.groupAwait = groupAwait;
        table.groupCancel = groupCancel;
        table.futexWait = futexWait;
        table.futexWaitUncancelable = futexWaitUncancelable;
        table.futexWake = futexWake;
    }
    break :blk table;
};

pub const io: std.Io = .{
    .userdata = null,
    .vtable = &vtable,
};

pub const allocator = if (config.worker_concurrency_enabled) Runtime.allocator else std.heap.wasm_allocator;

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
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) std.Io.ConcurrentError!void {
    try Runtime.concurrent(group, context, context_alignment, start);
}

fn groupAsync(
    userdata: ?*anyopaque,
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    groupConcurrent(userdata, group, context, context_alignment, start) catch start(context.ptr);
}

fn groupAwait(_: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) std.Io.Cancelable!void {
    try Runtime.await(group, token);
}

fn groupCancel(_: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
    Runtime.cancel(group, token);
}

fn recancel(_: ?*anyopaque) void {
    Runtime.recancel();
}

fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    return Runtime.swapCancelProtection(new);
}

fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
    if (Runtime.isCanceled()) return error.Canceled;
}

fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const deadline = timeout.toDeadline(io);
    const cancel_ptr = Runtime.cancelAddress() orelse return error.Canceled;
    while (true) {
        try checkCancel(null);
        const timeout_ns: i64 = if (deadline.toDurationFromNow(io)) |duration|
            if (duration.raw.nanoseconds <= 0)
                return
            else if (duration.raw.nanoseconds >= std.math.maxInt(i64))
                std.math.maxInt(i64)
            else
                @intCast(duration.raw.nanoseconds)
        else
            -1;
        if (Runtime.atomicWait(cancel_ptr, 0, timeout_ns) == 2) return;
    }
}

fn futexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    try checkCancel(null);
    Runtime.beginWait(ptr);
    defer Runtime.endWait();
    try checkCancel(null);
    const duration = timeout.toDurationFromNow(io);
    const timeout_ns: i64 = if (duration) |value|
        if (value.raw.nanoseconds <= 0)
            0
        else if (value.raw.nanoseconds >= std.math.maxInt(i64))
            std.math.maxInt(i64)
        else
            @intCast(value.raw.nanoseconds)
    else
        -1;
    _ = Runtime.atomicWait(ptr, expected, timeout_ns);
    try checkCancel(null);
}

fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = Runtime.atomicWait(ptr, expected, -1);
}

fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    Runtime.atomicNotify(ptr, max_waiters);
}

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
    if (len == 0) return 0;
    const bytes = allocator.alloc(u8, len) catch {
        _ = fail(error.OutOfMemory);
        return 0;
    };
    return @intFromPtr(bytes.ptr);
}

pub fn free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
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
        const msg = js.lastError(allocator) catch {
            setLastError(@errorName(err));
            return;
        };
        defer allocator.free(msg);
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

comptime {
    if (config.worker_concurrency_enabled) {
        const exports = struct {
            fn run(start: usize, context: usize, task: *Runtime.Task) callconv(.{ .wasm_mvp = .{} }) void {
                Runtime.run(start, context, task);
            }

            fn complete(task: *Runtime.Task) callconv(.{ .wasm_mvp = .{} }) void {
                Runtime.complete(task);
            }

            fn release(task: *Runtime.Task) callconv(.{ .wasm_mvp = .{} }) void {
                Runtime.release(task);
            }

            fn abort(task: *Runtime.Task) callconv(.{ .wasm_mvp = .{} }) void {
                Runtime.abort(task);
            }

            fn stackAlloc() callconv(.{ .wasm_mvp = .{} }) usize {
                return Runtime.allocateStack();
            }

            fn stackFree(stack_top: usize) callconv(.{ .wasm_mvp = .{} }) void {
                Runtime.freeStack(stack_top);
            }
        };
        @export(&exports.run, .{ .name = "knots_worker_run" });
        @export(&exports.complete, .{ .name = "knots_worker_complete" });
        @export(&exports.release, .{ .name = "knots_worker_release" });
        @export(&exports.abort, .{ .name = "knots_worker_abort" });
        @export(&exports.stackAlloc, .{ .name = "knots_worker_stack_alloc" });
        @export(&exports.stackFree, .{ .name = "knots_worker_stack_free" });
    }
}
