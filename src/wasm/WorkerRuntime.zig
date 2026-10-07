const std = @import("std");
const worker_host = @import("worker_host");

const Allocator = std.mem.Allocator;
const stack_size = 1024 * 1024;

var allocator_lock: std.atomic.Value(u32) = .init(0);

pub const allocator: Allocator = .{
    .ptr = @ptrCast(&allocator_lock),
    .vtable = &.{
        .alloc = lockedAlloc,
        .resize = lockedResize,
        .remap = lockedRemap,
        .free = lockedFree,
    },
};

const State = struct {
    running: std.atomic.Value(usize) = .init(0),
    tasks: ?*Task = null,
};

pub const Task = struct {
    state: *State,
    prev: ?*Task,
    next: ?*Task,
    context: []u8,
    context_alignment: std.mem.Alignment,
    canceled: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    cancel_protection: std.atomic.Value(u32) = .init(@intFromEnum(std.Io.CancelProtection.unblocked)),
    waiting_on: std.atomic.Value(usize) = .init(0),
};

pub fn concurrent(
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (*const anyopaque) void,
) std.Io.ConcurrentError!void {
    const state = stateFor(group) catch return error.ConcurrencyUnavailable;
    const task = allocator.create(Task) catch return error.ConcurrencyUnavailable;
    errdefer allocator.destroy(task);

    const alignment = context_alignment.max(.of(u128));
    const context_ptr = allocator.rawAlloc(context.len, alignment, @returnAddress()) orelse
        return error.ConcurrencyUnavailable;
    const context_copy = context_ptr[0..context.len];
    errdefer allocator.rawFree(context_copy, alignment, @returnAddress());
    @memcpy(context_copy, context);

    task.* = .{
        .state = state,
        .prev = null,
        .next = state.tasks,
        .context = context_copy,
        .context_alignment = alignment,
    };
    if (state.tasks) |head| head.prev = task;
    state.tasks = task;
    _ = state.running.fetchAdd(1, .release);
    errdefer {
        _ = state.running.fetchSub(1, .release);
        state.tasks = task.next;
        if (task.next) |next| next.prev = null;
    }

    if (!worker_host.spawnConcurrent(@intFromPtr(task), @intFromPtr(state), @intFromPtr(start), @intFromPtr(context_copy.ptr)))
        return error.ConcurrencyUnavailable;
}

fn stateFor(group: *std.Io.Group) Allocator.Error!*State {
    if (group.token.load(.acquire)) |token| return @ptrCast(@alignCast(token));
    const state = try allocator.create(State);
    state.* = .{};
    group.token.store(state, .release);
    return state;
}

pub fn await(group: *std.Io.Group, token: *anyopaque) std.Io.Cancelable!void {
    const state: *State = @ptrCast(@alignCast(token));
    waitForTasks(state);
    destroyState(group, state);
}

pub fn cancel(group: *std.Io.Group, token: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(token));
    var task = state.tasks;
    while (task) |current| : (task = current.next) {
        current.canceled.store(1, .release);
        atomicNotify(&current.canceled.raw, 1);
        const wait_address = current.waiting_on.load(.acquire);
        if (wait_address != 0) atomicNotify(@ptrFromInt(wait_address), 1);
    }
    waitForTasks(state);
    destroyState(group, state);
}

fn waitForTasks(state: *State) void {
    while (state.running.load(.acquire) != 0) std.atomic.spinLoopHint();
}

fn destroyState(group: *std.Io.Group, state: *State) void {
    worker_host.forgetConcurrentGroup(@intFromPtr(state));

    var task = state.tasks;
    while (task) |current| {
        task = current.next;
        destroyTask(current);
    }
    allocator.destroy(state);
    group.token.store(null, .release);
}

fn destroyTask(task: *Task) void {
    allocator.rawFree(task.context, task.context_alignment, @returnAddress());
    allocator.destroy(task);
}

pub fn allocateStack() usize {
    const stack = allocator.alignedAlloc(u8, .of(u128), stack_size) catch return 0;
    return @intFromPtr(stack.ptr + stack.len);
}

pub fn freeStack(stack_top: usize) void {
    if (stack_top == 0) return;
    const stack: [*]align(16) u8 = @ptrFromInt(stack_top - stack_size);
    const memory: []align(16) u8 = stack[0..stack_size];
    allocator.free(memory);
}

pub fn release(task: *Task) void {
    const state = task.state;
    if (task.prev) |prev|
        prev.next = task.next
    else
        state.tasks = task.next;
    if (task.next) |next| next.prev = task.prev;
    destroyTask(task);
}

pub fn run(start_address: usize, context_address: usize, task: *Task) void {
    setCurrentTask(task);
    defer setCurrentTask(null);

    const start: *const fn (*const anyopaque) void =
        @ptrFromInt(start_address);
    const context: *const anyopaque =
        @ptrFromInt(context_address);

    start(context);
}

pub fn complete(task: *Task) void {
    if (task.finished.swap(1, .acq_rel) == 0) _ = task.state.running.fetchSub(1, .release);
}

pub const abort = complete;

pub fn isCanceled() bool {
    const task = currentTask() orelse return false;
    if (task.cancel_protection.load(.acquire) != @intFromEnum(std.Io.CancelProtection.unblocked)) return false;
    return task.canceled.swap(0, .acq_rel) != 0;
}

pub fn recancel() void {
    const task = currentTask() orelse return;
    task.canceled.store(1, .release);
}

pub fn swapCancelProtection(new: std.Io.CancelProtection) std.Io.CancelProtection {
    const task = currentTask() orelse return .unblocked;
    return @enumFromInt(task.cancel_protection.swap(@intFromEnum(new), .acq_rel));
}

pub fn cancelAddress() ?*const u32 {
    const task = currentTask() orelse return null;
    return &task.canceled.raw;
}

pub fn beginWait(ptr: *const u32) void {
    const task = currentTask() orelse return;
    task.waiting_on.store(@intFromPtr(ptr), .release);
}

pub fn endWait() void {
    const task = currentTask() orelse return;
    task.waiting_on.store(0, .release);
}

fn currentTask() ?*Task {
    const address = worker_host.currentTask();
    return if (address == 0) null else @ptrFromInt(address);
}

fn setCurrentTask(task: ?*Task) void {
    worker_host.setCurrentTask(if (task) |value| @intFromPtr(value) else 0);
}

/// Returns 0 when woken, 1 if `ptr` did not hold `expected`, 2 on timeout.
pub fn atomicWait(ptr: *const u32, expected: u32, timeout_ns: i64) u32 {
    if (currentTask() == null) {
        if (@atomicLoad(u32, ptr, .acquire) != expected) return 1;
        if (timeout_ns == 0) return 2;
        while (@atomicLoad(u32, ptr, .acquire) == expected) std.atomic.spinLoopHint();
        return 0;
    }
    return worker_host.atomicWait(ptr, expected, timeout_ns);
}

pub fn atomicNotify(ptr: *const u32, max_waiters: u32) void {
    worker_host.atomicNotify(ptr, max_waiters);
}

fn lockAllocator() void {
    while (allocator_lock.cmpxchgWeak(0, 1, .acquire, .monotonic)) |_| {
        _ = atomicWait(&allocator_lock.raw, 1, -1);
    }
}

fn unlockAllocator() void {
    allocator_lock.store(0, .release);
    atomicNotify(&allocator_lock.raw, 1);
}

fn lockedAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    lockAllocator();
    defer unlockAllocator();
    return std.heap.wasm_allocator.rawAlloc(len, alignment, return_address);
}

fn lockedResize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
    lockAllocator();
    defer unlockAllocator();
    return std.heap.wasm_allocator.rawResize(memory, alignment, new_len, return_address);
}

fn lockedRemap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    lockAllocator();
    defer unlockAllocator();
    return std.heap.wasm_allocator.rawRemap(memory, alignment, new_len, return_address);
}

fn lockedFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    lockAllocator();
    defer unlockAllocator();
    std.heap.wasm_allocator.rawFree(memory, alignment, return_address);
}
