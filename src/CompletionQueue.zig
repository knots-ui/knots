const std = @import("std");
const App = @import("App.zig");
const ReturnType = @import("util.zig").ReturnType;

const Allocator = std.mem.Allocator;

const OpaqueCallback = *const fn (*App, *anyopaque) anyerror!void;

pub fn Callback(comptime T: type) type {
    return *const fn (*App, T) anyerror!void;
}

pub const DispatchError = std.mem.Allocator.Error || std.Io.ConcurrentError;

const Completion = struct {
    ptr: *anyopaque,
    callback: OpaqueCallback,
    destroy: *const fn (*anyopaque) void,
};

fn Context(T: type) type {
    return struct {
        completion: Completion,
        result: T = undefined,
        onComplete: Callback(T),
        allocator: Allocator,

        const Self = @This();

        pub fn init(self: *Self, onComplete: Callback(T), allocator: Allocator) void {
            self.* = .{
                .allocator = allocator,
                .onComplete = onComplete,
                .completion = .{
                    .ptr = self,
                    .callback = (struct {
                        fn cb(app: *App, ptr: *anyopaque) anyerror!void {
                            const ctx: *Self = @ptrCast(@alignCast(ptr));
                            try ctx.onComplete(app, ctx.result);
                        }
                    }).cb,
                    .destroy = (struct {
                        fn d(ptr: *anyopaque) void {
                            const ctx: *Self = @ptrCast(@alignCast(ptr));
                            ctx.allocator.destroy(ctx);
                        }
                    }).d,
                },
            };
        }
    };
}

recv_buf: []Completion,
buf: []Completion,
queue: std.Io.Queue(Completion),
wg: std.Io.Group,
in_flight: std.atomic.Value(usize),

const CompletionQueue = @This();

pub fn init(allocator: Allocator, max_completions: usize) !CompletionQueue {
    const buf = try allocator.alloc(Completion, max_completions);
    errdefer allocator.free(buf);
    return .{
        .buf = buf,
        .queue = .init(buf),
        .wg = .init,
        .in_flight = .init(0),
        .recv_buf = try allocator.alloc(Completion, max_completions),
    };
}

pub fn deinit(self: *CompletionQueue, allocator: Allocator, io: std.Io) void {
    self.queue.close(io);
    self.wg.cancel(io);
    self.wg.await(io) catch {};
    while (self.queue.get(io, self.recv_buf, 0)) |n| {
        if (n == 0) break;
        for (self.recv_buf[0..n]) |completion| {
            completion.destroy(completion.ptr);
            self.completeInFlight();
        }
    } else |_| {}
    self.in_flight.store(0, .monotonic);
    allocator.free(self.buf);
    allocator.free(self.recv_buf);
}

pub fn dispatch(
    self: *CompletionQueue,
    io: std.Io,
    allocator: Allocator,
    func: anytype,
    args: anytype,
    onComplete: Callback(ReturnType(func)),
) DispatchError!void {
    const ctx = try allocator.create(Context(ReturnType(func)));
    errdefer allocator.destroy(ctx);
    ctx.init(onComplete, allocator);
    _ = self.in_flight.fetchAdd(1, .monotonic);
    errdefer self.completeInFlight();
    try self.wg.concurrent(io, workerFn(@TypeOf(args), func), .{ io, args, ctx, &self.queue, &self.in_flight });
}

pub fn consume(self: *CompletionQueue, app: *App, io: std.Io) !void {
    const n = try self.queue.get(io, self.recv_buf, 0);
    for (self.recv_buf[0..n]) |completion| {
        defer self.completeInFlight();
        defer completion.destroy(completion.ptr);
        try completion.callback(app, completion.ptr);
    }
}

pub inline fn inFlight(self: *const CompletionQueue) usize {
    return self.in_flight.load(.monotonic);
}

fn completeInFlight(self: *CompletionQueue) void {
    _ = self.in_flight.fetchSub(1, .monotonic);
}

fn workerFn(
    comptime Args: type,
    func: anytype,
) fn (std.Io, Args, *Context(ReturnType(func)), *std.Io.Queue(Completion), *std.atomic.Value(usize)) std.Io.Cancelable!void {
    return struct {
        fn run(
            io: std.Io,
            args: Args,
            ctx: *Context(ReturnType(func)),
            queue: *std.Io.Queue(Completion),
            in_flight: *std.atomic.Value(usize),
        ) std.Io.Cancelable!void {
            ctx.result = @call(.auto, func, args);
            queue.putOne(io, ctx.completion) catch |err| {
                ctx.completion.destroy(ctx.completion.ptr);
                _ = in_flight.fetchSub(1, .monotonic);
                switch (err) {
                    error.Closed => {},
                    error.Canceled => return error.Canceled,
                }
            };
        }
    }.run;
}
