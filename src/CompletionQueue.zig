const std = @import("std");
const App = @import("App.zig");
const ReturnType = @import("util.zig").ReturnType;
const Viewport = @import("Viewport.zig");

const Allocator = std.mem.Allocator;

pub const OpaqueCallback = *const fn (*App, *anyopaque) anyerror!void;

pub fn Callback(comptime T: type) type {
    return *const fn (*App, T) anyerror!void;
}

pub const DispatchError = std.mem.Allocator.Error || std.Io.ConcurrentError;

const Completion = struct {
    viewport_id: Viewport.Id,
    ptr: *anyopaque,
    callback: OpaqueCallback,
    destroy: *const fn (*anyopaque) void,
};

pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque) void,
};

fn Context(T: type) type {
    return struct {
        completion: Completion,
        result: T = undefined,
        onComplete: Callback(T),
        allocator: Allocator,

        const Self = @This();

        pub fn init(
            self: *Self,
            onComplete: Callback(T),
            allocator: Allocator,
            viewport_id: Viewport.Id,
        ) void {
            self.* = .{
                .allocator = allocator,
                .onComplete = onComplete,
                .completion = .{
                    .viewport_id = viewport_id,
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
    if (max_completions == 0) return error.InvalidCompletionCapacity;
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
    std.debug.assert(self.in_flight.load(.monotonic) == 0);
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
    viewport_id: Viewport.Id,
    wake: Wake,
) DispatchError!void {
    const ctx = try allocator.create(Context(ReturnType(func)));
    errdefer allocator.destroy(ctx);
    ctx.init(onComplete, allocator, viewport_id);
    const in_flight_before = self.in_flight.fetchAdd(1, .monotonic);
    std.debug.assert(in_flight_before < std.math.maxInt(usize));
    errdefer self.completeInFlight();
    try self.wg.concurrent(
        io,
        workerFn(@TypeOf(args), func),
        .{ io, args, ctx, &self.queue, &self.in_flight, wake },
    );
}

pub fn consume(self: *CompletionQueue, app: *App, io: std.Io, route: anytype) !void {
    const n = try self.queue.get(io, self.recv_buf, 0);
    try self.consumeReceived(app, self.recv_buf[0..n], route);
}

fn consumeReceived(
    self: *CompletionQueue,
    route_context: anytype,
    completions: []const Completion,
    route: anytype,
) !void {
    var callback_error: ?anyerror = null;
    for (completions) |completion| {
        defer self.completeInFlight();
        defer completion.destroy(completion.ptr);
        if (callback_error != null) continue;
        @call(.auto, route, .{
            route_context,
            completion.viewport_id,
            completion.callback,
            completion.ptr,
        }) catch |err| {
            callback_error = err;
        };
    }
    if (callback_error) |err| return err;
}

pub fn inFlight(self: *const CompletionQueue) usize {
    return self.in_flight.load(.monotonic);
}

fn completeInFlight(self: *CompletionQueue) void {
    const in_flight_before = self.in_flight.fetchSub(1, .monotonic);
    std.debug.assert(in_flight_before > 0);
}

fn workerFn(
    comptime Args: type,
    func: anytype,
) fn (
    std.Io,
    Args,
    *Context(ReturnType(func)),
    *std.Io.Queue(Completion),
    *std.atomic.Value(usize),
    Wake,
) std.Io.Cancelable!void {
    return struct {
        fn run(
            io: std.Io,
            args: Args,
            ctx: *Context(ReturnType(func)),
            queue: *std.Io.Queue(Completion),
            in_flight: *std.atomic.Value(usize),
            wake: Wake,
        ) std.Io.Cancelable!void {
            ctx.result = @call(.auto, func, args);
            queue.putOne(io, ctx.completion) catch |err| {
                ctx.completion.destroy(ctx.completion.ptr);
                const in_flight_before = in_flight.fetchSub(1, .monotonic);
                std.debug.assert(in_flight_before > 0);
                switch (err) {
                    error.Closed => {},
                    error.Canceled => return error.Canceled,
                }
                return;
            };
            wake.notify(wake.context);
        }
    }.run;
}

test "initialization rejects a zero completion capacity" {
    try std.testing.expectError(
        error.InvalidCompletionCapacity,
        CompletionQueue.init(std.testing.allocator, 0),
    );
}

test "callback error still destroys every received completion" {
    const TestContext = struct {
        destroyed_count: *u32,

        fn destroy(ptr: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(ptr));
            context.destroyed_count.* += 1;
        }
    };
    const RouteContext = struct {
        called_count: u32 = 0,

        fn route(
            self: *@This(),
            viewport_id: Viewport.Id,
            callback: OpaqueCallback,
            ptr: *anyopaque,
        ) !void {
            _ = viewport_id;
            _ = callback;
            _ = ptr;
            self.called_count += 1;
            return error.ExpectedCallbackFailure;
        }
    };

    var destroyed_count: u32 = 0;
    var contexts = [_]TestContext{
        .{ .destroyed_count = &destroyed_count },
        .{ .destroyed_count = &destroyed_count },
    };
    const callback = struct {
        fn run(app: *App, ptr: *anyopaque) !void {
            _ = app;
            _ = ptr;
        }
    }.run;
    const completions = [_]Completion{
        .{
            .viewport_id = .main,
            .ptr = &contexts[0],
            .callback = callback,
            .destroy = TestContext.destroy,
        },
        .{
            .viewport_id = @enumFromInt(1),
            .ptr = &contexts[1],
            .callback = callback,
            .destroy = TestContext.destroy,
        },
    };
    var queue: CompletionQueue = undefined;
    queue.in_flight = .init(completions.len);
    var route_context: RouteContext = .{};

    try std.testing.expectError(
        error.ExpectedCallbackFailure,
        queue.consumeReceived(&route_context, &completions, RouteContext.route),
    );
    try std.testing.expectEqual(@as(u32, 1), route_context.called_count);
    try std.testing.expectEqual(@as(u32, completions.len), destroyed_count);
    try std.testing.expectEqual(@as(usize, 0), queue.inFlight());
}

test "dispatch wakes after enqueue and preserves the origin viewport" {
    const WakeContext = struct {
        count: std.atomic.Value(u32) = .init(0),

        fn notify(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const count_before = self.count.fetchAdd(1, .monotonic);
            std.debug.assert(count_before < std.math.maxInt(u32));
        }
    };
    const RouteContext = struct {
        called_count: u32 = 0,
        viewport_id: ?Viewport.Id = null,

        fn route(
            self: *@This(),
            viewport_id: Viewport.Id,
            callback: OpaqueCallback,
            ptr: *anyopaque,
        ) !void {
            _ = callback;
            _ = ptr;
            self.called_count += 1;
            self.viewport_id = viewport_id;
        }
    };
    const Work = struct {
        fn run() u32 {
            return 42;
        }

        fn complete(app: *App, result: u32) !void {
            _ = app;
            std.debug.assert(result == 42);
        }
    };

    var queue = try CompletionQueue.init(std.testing.allocator, 1);
    defer queue.deinit(std.testing.allocator, std.testing.io);
    var wake_context: WakeContext = .{};
    const origin: Viewport.Id = @enumFromInt(7);
    try queue.dispatch(
        std.testing.io,
        std.testing.allocator,
        Work.run,
        .{},
        Work.complete,
        origin,
        .{ .context = &wake_context, .notify = WakeContext.notify },
    );

    try queue.wg.await(std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), wake_context.count.load(.monotonic));
    const received_count = try queue.queue.get(std.testing.io, queue.recv_buf, 0);
    try std.testing.expectEqual(@as(usize, 1), received_count);
    var route_context: RouteContext = .{};
    try queue.consumeReceived(
        &route_context,
        queue.recv_buf[0..received_count],
        RouteContext.route,
    );
    try std.testing.expectEqual(@as(u32, 1), route_context.called_count);
    try std.testing.expectEqual(origin, route_context.viewport_id.?);
    try std.testing.expectEqual(@as(usize, 0), queue.inFlight());
}
