const std = @import("std");
const js = @import("js-bridge");

pub fn spawnConcurrent(task: usize, group: usize, start: usize, context: usize) bool {
    const host = js.host() catch return false;
    defer host.release();
    const spawned = host.call("spawnConcurrent", &.{
        js.Arg.usize(task),
        js.Arg.usize(group),
        js.Arg.usize(start),
        js.Arg.usize(context),
    }) catch return false;
    defer spawned.release();
    return spawned.tryBool() catch false;
}

pub fn forgetConcurrentGroup(group: usize) void {
    const host = js.host() catch return;
    defer host.release();
    host.callVoid("forgetConcurrentGroup", &.{js.Arg.usize(group)}) catch {};
}

pub fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    switch (clock) {
        .real, .awake, .boot => {
            const host = js.host() catch return .zero;
            defer host.release();
            const result = host.call("nowMs", &.{js.Arg.u32(@backingInt(clock))}) catch return .zero;
            defer result.release();
            const ms = result.tryF64() catch return .zero;
            if (!std.math.isFinite(ms) or ms <= 0) return .zero;
            return .fromNanoseconds(@intFromFloat(ms * @as(f64, std.time.ns_per_ms)));
        },
        .cpu_process, .cpu_thread => return .zero,
    }
}

comptime {
    if (@sizeOf(usize) == 4) {
        asm (
            \\.globaltype knots_worker_task, i32
            \\knots_worker_task:
        );
    } else {
        asm (
            \\.globaltype knots_worker_task, i64
            \\knots_worker_task:
        );
    }
}

pub fn currentTask() usize {
    return asm volatile (
        \\ global.get knots_worker_task
        \\ local.set %[address]
        : [address] "=r" (-> usize),
    );
}

pub fn setCurrentTask(address: usize) void {
    asm volatile (
        \\ local.get %[address]
        \\ global.set knots_worker_task
        :
        : [address] "r" (address),
    );
}

pub fn atomicWait(ptr: *const u32, expected: u32, timeout_ns: i64) u32 {
    return asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[expected]
        \\ local.get %[timeout]
        \\ memory.atomic.wait32 0
        \\ local.set %[result]
        : [result] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expected] "r" (expected),
          [timeout] "r" (timeout_ns),
    );
}

pub fn atomicNotify(ptr: *const u32, max_waiters: u32) void {
    _ = asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[max_waiters]
        \\ memory.atomic.notify 0
        \\ local.set %[result]
        : [result] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [max_waiters] "r" (max_waiters),
    );
}
