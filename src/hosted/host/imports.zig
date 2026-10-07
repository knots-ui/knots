const std = @import("std");
const wasmtime = @import("wasmtime");
const abi = @import("abi");
const Host = @import("Host.zig");
const Reply = @import("Reply.zig");
const Workers = @import("Workers.zig");

pub fn define(linker: *wasmtime.Linker, host: *Host) !void {
    inline for (@typeInfo(functions).@"struct".decl_names) |name|
        try linker.defineFunction(abi.module, name, Host, host, @field(functions, name), null);
}

const functions = struct {
    pub fn log(host: *Host, level: u32, pointer: u32, length: u32) void {
        const message = host.memory(pointer, length);
        const guest = std.log.scoped(.guest);
        switch (level) {
            0 => guest.err("{s}", .{message}),
            1 => guest.warn("{s}", .{message}),
            2 => guest.info("{s}", .{message}),
            else => guest.debug("{s}", .{message}),
        }
    }

    pub fn now(host: *Host) u64 {
        return @intCast(std.Io.Clock.awake.now(host.io).nanoseconds);
    }

    pub fn random(host: *Host, pointer: u32, length: u32) void {
        var prng = std.Random.DefaultPrng.init(host.seed.fetchAdd(0x9e3779b97f4a7c15, .monotonic));
        prng.fill(host.memory(pointer, length));
    }

    pub fn call(host: *Host, pointer: u32, length: u32, reply_pointer: u32, capacity: u32) u32 {
        var arena = std.heap.ArenaAllocator.init(host.gpa);
        defer arena.deinit();
        var reply: Reply = .{ .arena = arena.allocator() };
        host.call(host.memory(pointer, length), &reply) catch |err| reply.failed(err) catch return 0;
        if (reply.bytes.items.len > capacity) {
            std.log.scoped(.dev_host).err("event=reply_too_long length={d}", .{reply.bytes.items.len});
            return 0;
        }
        const destination = host.memory(reply_pointer, @intCast(reply.bytes.items.len));
        if (destination.len != reply.bytes.items.len) return 0;
        @memcpy(destination, reply.bytes.items);
        return @intCast(reply.bytes.items.len);
    }

    pub fn commands(host: *Host, pointer: u32, length: u32) void {
        var arena = std.heap.ArenaAllocator.init(host.gpa);
        defer arena.deinit();
        host.commands(arena.allocator(), host.memory(pointer, length)) catch |err|
            std.log.scoped(.dev_host).err("event=invalid_commands error={t}", .{err});
    }

    pub fn spawn_concurrent(host: *Host, task: u32, group: u32, start: u32, context: u32) bool {
        const job: Workers.Job = .{ .task = task, .group = group, .start = start, .context = context };
        if (Workers.current) |worker| return worker.workers.spawn(job, null);
        const guest = &(host.guest orelse return false);
        return guest.spawn(host.io, job, host, Host.taskFinished);
    }

    pub fn forget_concurrent_group(host: *Host, group: u32) void {
        const guest = &(host.guest orelse return);
        if (guest.workers) |workers| workers.forget(group);
    }

    pub fn current_task(_: *Host) u32 {
        return @intCast(Workers.task);
    }

    pub fn set_current_task(_: *Host, task: u32) void {
        Workers.task = task;
    }

    /// Wakes after at most 50 ms: the caller checks its deadline.
    pub fn atomic_wait(host: *Host, pointer: u32, expected: u32, timeout_ns: i64) error{GuestStopped}!u32 {
        if (Workers.current) |worker| if (worker.workers.stopping.load(.acquire)) return error.GuestStopped;
        const bytes = host.memory(pointer, 4);
        if (bytes.len != 4) return 1;
        const word: *const u32 = @ptrCast(@alignCast(bytes.ptr));
        if (@atomicLoad(u32, word, .acquire) != expected) return 1;
        const slice_ns = 50 * std.time.ns_per_ms;
        const wait_ns = if (timeout_ns < 0) slice_ns else @min(timeout_ns, slice_ns);
        host.io.futexWaitTimeout(u32, word, expected, .{ .duration = .{ .raw = .fromNanoseconds(wait_ns), .clock = .awake } }) catch {};
        return 0;
    }

    pub fn atomic_notify(host: *Host, pointer: u32, count: u32) void {
        const bytes = host.memory(pointer, 4);
        if (bytes.len != 4) return;
        host.io.futexWake(u32, @ptrCast(@alignCast(bytes.ptr)), count);
    }
};
