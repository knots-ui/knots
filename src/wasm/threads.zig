const std = @import("std");
const worker_host = @import("worker_host");
pub const Runtime = @import("WorkerRuntime.zig");

pub const allocator = Runtime.allocator;

pub fn install(table: *std.Io.VTable) void {
    table.async = futureAsync;
    table.concurrent = futureConcurrent;
    table.await = futureAwait;
    table.cancel = futureCancel;
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

const clock: std.Io = .{ .userdata = null, .vtable = &clock_vtable };
const clock_vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = worker_host.now;
    break :blk table;
};

const FutureState = struct {
    group: std.Io.Group = .init,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,

    fn run(context: *const anyopaque) void {
        const self: *FutureState = @as(*const *FutureState, @ptrCast(@alignCast(context))).*;
        self.start(self.context.ptr, self.result.ptr);
    }

    fn finish(self: *FutureState, result: []u8) void {
        @memcpy(result, self.result);
        if (self.result.len > 0) Runtime.allocator.rawFree(self.result, self.result_alignment, @returnAddress());
        if (self.context.len > 0) Runtime.allocator.rawFree(self.context, self.context_alignment, @returnAddress());
        Runtime.allocator.destroy(self);
    }
};

fn futureConcurrent(
    _: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    const state = Runtime.allocator.create(FutureState) catch return error.ConcurrencyUnavailable;
    errdefer Runtime.allocator.destroy(state);
    const result: []u8 = if (result_len == 0) &.{} else (Runtime.allocator.rawAlloc(result_len, result_alignment, @returnAddress()) orelse
        return error.ConcurrencyUnavailable)[0..result_len];
    errdefer if (result.len > 0) Runtime.allocator.rawFree(result, result_alignment, @returnAddress());
    const context_copy: []u8 = if (context.len == 0) &.{} else (Runtime.allocator.rawAlloc(context.len, context_alignment, @returnAddress()) orelse
        return error.ConcurrencyUnavailable)[0..context.len];
    errdefer if (context_copy.len > 0) Runtime.allocator.rawFree(context_copy, context_alignment, @returnAddress());
    @memcpy(context_copy, context);
    state.* = .{
        .result = result,
        .result_alignment = result_alignment,
        .context = context_copy,
        .context_alignment = context_alignment,
        .start = start,
    };
    try Runtime.concurrent(&state.group, std.mem.asBytes(&state), .of(*FutureState), FutureState.run);
    return @ptrCast(state);
}

fn futureAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*std.Io.AnyFuture {
    return futureConcurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, result.ptr);
        return null;
    };
}

fn futureAwait(_: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const state: *FutureState = @ptrCast(@alignCast(any_future));
    if (state.group.token.load(.acquire)) |token| Runtime.await(&state.group, token) catch {};
    state.finish(result);
}

fn futureCancel(_: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const state: *FutureState = @ptrCast(@alignCast(any_future));
    if (state.group.token.load(.acquire)) |token| Runtime.cancel(&state.group, token);
    state.finish(result);
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
    const deadline = timeout.toDeadline(clock);
    const cancel_ptr = Runtime.cancelAddress() orelse return error.Canceled;
    while (true) {
        try checkCancel(null);
        const timeout_ns: i64 = if (deadline.toDurationFromNow(clock)) |duration|
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
    const duration = timeout.toDurationFromNow(clock);
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

comptime {
    {
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
