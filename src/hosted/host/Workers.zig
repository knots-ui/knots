const std = @import("std");
const wasmtime = @import("wasmtime");
const module = @import("module.zig");

const Workers = @This();
const log = std.log.scoped(.dev_host);

pub const workers_max = 4;

pub threadlocal var current: ?*Worker = null;
pub threadlocal var task: usize = 0;

pub const Job = struct { task: u32, group: u32, start: u32, context: u32 };
pub const Completion = struct { task: u32, group: u32 };

pub const Worker = struct {
    workers: *Workers,
    store: wasmtime.Store,
    instance: wasmtime.Instance,
    memory: wasmtime.SharedMemory,
    stack_top: u32,
};

gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
jobs: std.ArrayList(Job) = .empty,
completions: std.ArrayList(Completion) = .empty,
forgotten: std.ArrayList(u32) = .empty,
count: u32 = 0,
idle: u32 = 0,
alive: u32 = 0,
stopping: std.atomic.Value(bool) = .init(false),
orphaned: bool = false,
wake: struct { context: *anyopaque, notify: *const fn (*anyopaque) void },

pub const Spawner = struct {
    engine: wasmtime.Engine,
    linker: *wasmtime.Linker,
    module: *const wasmtime.Module,
    memory: wasmtime.SharedMemory,
    main: *const wasmtime.Instance,
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, context: *anyopaque, notify: *const fn (*anyopaque) void) !*Workers {
    const self = try gpa.create(Workers);
    self.* = .{ .gpa = gpa, .io = io, .wake = .{ .context = context, .notify = notify } };
    return self;
}

pub fn stop(self: *Workers) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping.store(true, .release);
    self.jobs.clearRetainingCapacity();
    self.condition.broadcast(self.io);
    var waited_ms: u32 = 0;
    while (self.alive > 0 and waited_ms < 2000) : (waited_ms += 10) {
        self.mutex.unlock(self.io);
        self.io.sleep(.fromMilliseconds(10), .awake) catch {};
        self.mutex.lockUncancelable(self.io);
    }
    const last = self.alive == 0;
    self.orphaned = !last;
    self.mutex.unlock(self.io);
    if (last) self.destroy() else log.warn("event=workers_still_running count={d}", .{self.alive});
}

fn destroy(self: *Workers) void {
    self.jobs.deinit(self.gpa);
    self.completions.deinit(self.gpa);
    self.forgotten.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn spawn(self: *Workers, job: Job, spawner: ?Spawner) bool {
    self.mutex.lockUncancelable(self.io);
    // A worker counts as idle until it takes a job, so compare with the queue.
    const start_worker = self.jobs.items.len + 1 > self.idle and self.count < workers_max and spawner != null;
    if (self.count == 0 and !start_worker) {
        self.mutex.unlock(self.io);
        return false;
    }
    self.jobs.append(self.gpa, job) catch {
        self.mutex.unlock(self.io);
        return false;
    };
    self.condition.signal(self.io);
    self.mutex.unlock(self.io);
    if (start_worker) self.startWorker(spawner.?) catch |err| log.err("event=worker_start_failed error={t}", .{err});
    return true;
}

pub fn forget(self: *Workers, group: u32) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.forgotten.append(self.gpa, group) catch {};
}

pub fn takeCompletions(self: *Workers, out: *std.ArrayList(u32)) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.completions.items) |completion| {
        if (std.mem.indexOfScalar(u32, self.forgotten.items, completion.group) != null) continue;
        out.append(self.gpa, completion.task) catch {};
    }
    self.completions.clearRetainingCapacity();
    if (self.jobs.items.len == 0 and self.idle == self.count) self.forgotten.clearRetainingCapacity();
}

fn startWorker(self: *Workers, spawner: Spawner) !void {
    const worker = try self.gpa.create(Worker);
    errdefer self.gpa.destroy(worker);
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();

    // The stack comes from the guest's allocator, on the main instance.
    const allocate = try spawner.main.function("knots_worker_stack_alloc");
    var results: [1]wasmtime.Value = undefined;
    try allocate.call(&.{}, &results, &diagnostics);
    const stack_top: u32 = @bitCast(results[0].of.i32);
    if (stack_top == 0) return error.StackAllocationFailed;

    var store = try wasmtime.Store.init(spawner.engine, &.{ .memory_bytes = -1, .table_elements = 1 << 20, .instances = 1, .tables = 4, .memories = 1 });
    errdefer store.deinit();
    store.setFuel(std.math.maxInt(u64), null) catch {};
    const memory = spawner.memory.clone();
    try spawner.linker.defineSharedMemory(&store, "env", "memory", memory, &diagnostics);
    const instance = try spawner.linker.instantiate(&store, spawner.module, &diagnostics);
    worker.* = .{ .workers = self, .store = store, .instance = instance, .memory = memory, .stack_top = stack_top };

    self.mutex.lockUncancelable(self.io);
    self.count += 1;
    self.idle += 1;
    self.alive += 1;
    self.mutex.unlock(self.io);
    const thread = std.Thread.spawn(.{}, run, .{worker}) catch |err| {
        self.mutex.lockUncancelable(self.io);
        self.count -= 1;
        self.idle -= 1;
        self.alive -= 1;
        self.mutex.unlock(self.io);
        return err;
    };
    thread.detach();
}

fn run(worker: *Worker) void {
    current = worker;
    const self = worker.workers;
    while (true) {
        self.mutex.lockUncancelable(self.io);
        while (self.jobs.items.len == 0 and !self.stopping.raw) self.condition.waitUncancelable(self.io, &self.mutex);
        if (self.stopping.raw) break;
        const job = self.jobs.orderedRemove(0);
        self.idle -= 1;
        self.mutex.unlock(self.io);

        execute(worker, job);

        self.mutex.lockUncancelable(self.io);
        self.idle += 1;
        const stopping = self.stopping.raw;
        if (!stopping) self.completions.append(self.gpa, .{ .task = job.task, .group = job.group }) catch {};
        self.mutex.unlock(self.io);
        if (!stopping) self.wake.notify(self.wake.context);
    }
    // Locked from the loop above. The worker goes first: once this thread
    // counts itself out, another may free `self`.
    self.mutex.unlock(self.io);
    worker.store.deinit();
    worker.memory.deinit();
    self.gpa.destroy(worker);
    self.mutex.lockUncancelable(self.io);
    self.alive -= 1;
    const last = self.alive == 0 and self.orphaned;
    self.mutex.unlock(self.io);
    if (last) self.destroy();
}

fn execute(worker: *Worker, job: Job) void {
    var diagnostics: wasmtime.Diagnostics = .{};
    defer diagnostics.deinit();
    const value: wasmtime.Value = .{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(worker.stack_top) } };
    worker.instance.setGlobal(module.stack_pointer_export, value, &diagnostics) catch return log.err("event=worker_stack_failed", .{});
    const arguments = [_]wasmtime.Value{
        .{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(job.start) } },
        .{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(job.context) } },
        .{ .kind = wasmtime.c.WASMTIME_I32, .of = .{ .i32 = @bitCast(job.task) } },
    };
    const task_argument = [_]wasmtime.Value{arguments[2]};
    const run_task = worker.instance.function("knots_worker_run") catch return;
    run_task.call(&arguments, &.{}, &diagnostics) catch {
        if (worker.workers.stopping.load(.acquire)) return;
        const message = diagnostics.message(worker.workers.gpa) catch "";
        defer worker.workers.gpa.free(message);
        log.err("event=worker_task_trapped {s}", .{message});
        const abort = worker.instance.function("knots_worker_abort") catch return;
        abort.call(&task_argument, &.{}, null) catch {};
        return;
    };
    const complete = worker.instance.function("knots_worker_complete") catch return;
    complete.call(&task_argument, &.{}, null) catch {};
}
