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
                            ctx.allocator.destroy(ctx);
                        }
                    }).cb,
                },
            };
        }
    };
}

recv_buf: []Completion,
buf: []Completion,
queue: std.Io.Queue(Completion),
wg: std.Io.Group,

const CompletionQueue = @This();

pub fn init(allocator: Allocator, max_completions: usize) !CompletionQueue {
    const buf = try allocator.alloc(Completion, max_completions);
    return CompletionQueue{
        .buf = buf,
        .queue = .init(buf),
        .wg = .init,
        .recv_buf = try allocator.alloc(Completion, max_completions),
    };
}

pub fn deinit(self: *CompletionQueue, allocator: Allocator, io: std.Io) void {
    self.queue.close(io);
    allocator.free(self.buf);
    allocator.free(self.recv_buf);
    self.wg.cancel(io);
    self.wg.await(io) catch {};
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
    ctx.init(onComplete, allocator);
    try self.wg.concurrent(io, workerFn(@TypeOf(args), func), .{ io, args, ctx, &self.queue });
}

pub fn consume(self: *CompletionQueue, app: *App, io: std.Io) !void {
    const n = try self.queue.get(io, self.recv_buf, 0);
    for (self.recv_buf[0..n]) |completion|
        try completion.callback(app, completion.ptr);
}

fn workerFn(
    comptime Args: type,
    func: anytype,
) fn (std.Io, Args, *Context(ReturnType(func)), *std.Io.Queue(Completion)) std.Io.Cancelable!void {
    return struct {
        fn run(
            io: std.Io,
            args: Args,
            ctx: *Context(ReturnType(func)),
            queue: *std.Io.Queue(Completion),
        ) std.Io.Cancelable!void {
            ctx.result = @call(.auto, func, args);
            queue.putOne(io, ctx.completion) catch |err| switch (err) {
                error.Closed => unreachable,
                error.Canceled => return error.Canceled,
            };
        }
    }.run;
}
