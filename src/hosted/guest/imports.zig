const std = @import("std");

const host = struct {
    extern "knots_hosted" fn log(level: u32, message: [*]const u8, length: usize) void;
    extern "knots_hosted" fn now() u64;
    extern "knots_hosted" fn random(buffer: [*]u8, length: usize) void;
    extern "knots_hosted" fn call(request: [*]const u8, length: usize, reply: [*]u8, capacity: usize) usize;
    extern "knots_hosted" fn commands(bytes: [*]const u8, length: usize) void;
    extern "knots_hosted" fn spawn_concurrent(task: usize, group: usize, start: usize, context: usize) bool;
    extern "knots_hosted" fn forget_concurrent_group(group: usize) void;
    extern "knots_hosted" fn current_task() usize;
    extern "knots_hosted" fn set_current_task(task: usize) void;
    extern "knots_hosted" fn atomic_wait(ptr: *const u32, expected: u32, timeout_ns: i64) u32;
    extern "knots_hosted" fn atomic_notify(ptr: *const u32, max_waiters: u32) void;
};

pub fn log(level: std.log.Level, message: []const u8) void {
    host.log(@backingInt(level), message.ptr, message.len);
}

pub fn random(buffer: []u8) void {
    host.random(buffer.ptr, buffer.len);
}

pub fn call(request: []const u8, reply: []u8) []u8 {
    return reply[0..host.call(request.ptr, request.len, reply.ptr, reply.len)];
}

pub fn commands(bytes: []const u8) void {
    host.commands(bytes.ptr, bytes.len);
}

pub fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    return .fromNanoseconds(@intCast(host.now()));
}

pub fn spawnConcurrent(task: usize, group: usize, start: usize, context: usize) bool {
    return host.spawn_concurrent(task, group, start, context);
}

pub fn forgetConcurrentGroup(group: usize) void {
    host.forget_concurrent_group(group);
}

pub fn currentTask() usize {
    return host.current_task();
}

pub fn setCurrentTask(task: usize) void {
    host.set_current_task(task);
}

pub fn atomicWait(ptr: *const u32, expected: u32, timeout_ns: i64) u32 {
    return host.atomic_wait(ptr, expected, timeout_ns);
}

pub fn atomicNotify(ptr: *const u32, max_waiters: u32) void {
    host.atomic_notify(ptr, max_waiters);
}
