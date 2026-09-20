//! macOS filesystem watcher backend, built on FSEvents.
//!
//! FSEvents provides *recursive* directory watching through a system service: one
//! watch on the working-tree root covers the whole subtree, scaling to large repos
//! with no per-file descriptors (unlike kqueue). It is a CoreServices C API, reached
//! here via `extern fn` against the CoreServices/CoreFoundation frameworks that
//! `build.zig` links, and the libdispatch wrappers in `std.c.dispatch`.
//!
//! Sequencing follows std's own watcher (`std/Build/Watch/FsEvents.zig`), but is
//! reduced to "any event ⇒ dirty": the stream's callback just signals a semaphore,
//! and `wait` blocks on that semaphore with a timeout. The stream runs on a private
//! serial dispatch queue, so no global state is touched and this is thread-safe.

const std = @import("std");
const dispatch = std.c.dispatch;
const Watcher = @import("root.zig");
const WaitResult = Watcher.WaitResult;

const Macos = @This();

stream: FSEventStreamRef,
queue: dispatch.queue_t,
semaphore: dispatch.semaphore_t,
should_stop: *std.atomic.Value(bool),

pub fn init(
    _: std.Io,
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    workdir: []const u8,
) !Macos {
    const semaphore = dispatch.semaphore_create(0) orelse return error.SystemResources;
    errdefer _ = semaphore.as_object().release();

    const queue = dispatch.queue_create("plainview-watch", dispatch.QUEUE_SERIAL()) orelse return error.SystemResources;
    errdefer _ = queue.as_object().release();

    // The single recursive watch root: the repo's working directory.
    const workdir_z = try allocator.dupeSentinel(u8, workdir, 0);
    defer allocator.free(workdir_z);

    const cf_path = CFStringCreateWithCString(null, workdir_z.ptr, kCFStringEncodingUTF8) orelse return error.SystemResources;
    defer CFRelease(cf_path);
    var paths = [_]?*const anyopaque{cf_path};
    const cf_paths = CFArrayCreate(null, &paths, 1, null) orelse return error.SystemResources;
    defer CFRelease(cf_paths);

    // `info` points at the semaphore; the callback signals it on any event.
    var context: FSEventStreamContext = .{
        .version = 0,
        .info = @ptrCast(semaphore),
        .retain = null,
        .release = null,
        .copy_description = null,
    };

    const stream = FSEventStreamCreate(
        null,
        &eventCallback,
        &context,
        cf_paths,
        kFSEventStreamEventIdSinceNow,
        0.2, // latency seconds: FSEvents' own coalescing layer
        .{ .watch_root = true, .ignore_self = true, .file_events = true },
    ) orelse return error.SystemResources;
    errdefer FSEventStreamRelease(stream);

    FSEventStreamSetDispatchQueue(stream, queue);
    if (!FSEventStreamStart(stream)) {
        FSEventStreamInvalidate(stream);
        return error.StartFailed;
    }

    return .{
        .stream = stream,
        .queue = queue,
        .semaphore = semaphore,
        .should_stop = should_stop,
    };
}

pub fn deinit(self: *Macos) void {
    FSEventStreamStop(self.stream);
    FSEventStreamInvalidate(self.stream);
    FSEventStreamRelease(self.stream);
    _ = self.queue.as_object().release();
    _ = self.semaphore.as_object().release();
    self.* = undefined;
}

/// Block until the stream signals an event or the timeout elapses. `timeout_ms == 0`
/// means wait indefinitely (until an event or `wake`).
pub fn wait(self: *Macos, timeout_ms: u64) WaitResult {
    const deadline: dispatch.time_t = if (timeout_ms == 0)
        .FOREVER
    else
        dispatch.time(.NOW, @intCast(timeout_ms * std.time.ns_per_ms));
    const result = dispatch.semaphore_wait(self.semaphore, deadline);
    // 0 = acquired (an event, or a wake-on-stop signal); non-zero = timed out.
    if (result != 0) return .timeout;
    return .dirty;
}

/// Unblock `wait` so the loop can observe `should_stop` and exit promptly.
pub fn wake(self: *Macos) void {
    _ = self.semaphore.signal();
}

pub fn changedPath(_: *const Macos) ?[]const u8 {
    return null;
}

/// Wake the main thread's run loop from a background thread. On macOS,
/// `[NSApp postEvent:atStart:]` (knots' `postEmptyEvent`) does not reliably wake a
/// `nextEventMatchingMask:` pump blocked on the main thread when posted from another
/// thread; explicitly waking the main CFRunLoop does. Safe to call cross-thread.
pub fn wakeMainLoop() void {
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

fn eventCallback(
    _: ConstFSEventStreamRef,
    info: ?*anyopaque,
    _: usize,
    _: ?*anyopaque,
    _: [*]const FSEventStreamEventFlags,
    _: [*]const FSEventStreamEventId,
) callconv(.c) void {
    // We don't care which path changed — `git status` is the source of truth.
    // Just wake `wait`; the watcher thread debounces before triggering a refresh.
    const semaphore: dispatch.semaphore_t = @ptrCast(@alignCast(info.?));
    _ = dispatch.semaphore_signal(semaphore);
}

// --- CoreServices / CoreFoundation FFI (resolved against the linked frameworks) ---

const CFAllocatorRef = ?*const anyopaque;
const CFArrayRef = *const anyopaque;
const CFStringRef = *const anyopaque;
const CFIndex = isize;
const CFTimeInterval = f64;
const CFStringEncoding = u32;
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

const FSEventStreamRef = *anyopaque;
const ConstFSEventStreamRef = *const anyopaque;
const FSEventStreamEventId = u64;
const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;

const FSEventStreamCreateFlags = packed struct(u32) {
    use_cf_types: bool = false,
    no_defer: bool = false,
    watch_root: bool = false,
    ignore_self: bool = false,
    file_events: bool = false,
    _: u27 = 0,
};

const FSEventStreamEventFlags = u32;

const FSEventStreamContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    release: ?*const fn (?*const anyopaque) callconv(.c) void,
    copy_description: ?*const fn (?*const anyopaque) callconv(.c) CFStringRef,
};

const FSEventStreamCallback = *const fn (
    stream: ConstFSEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: ?*anyopaque,
    event_flags: [*]const FSEventStreamEventFlags,
    event_ids: [*]const FSEventStreamEventId,
) callconv(.c) void;

const CFRunLoopRef = *anyopaque;
extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
extern "c" fn CFRunLoopWakeUp(rl: CFRunLoopRef) void;

extern "c" fn CFRelease(cf: *const anyopaque) void;
extern "c" fn CFStringCreateWithCString(alloc: CFAllocatorRef, c_str: [*:0]const u8, encoding: CFStringEncoding) ?CFStringRef;
extern "c" fn CFArrayCreate(alloc: CFAllocatorRef, values: [*]const ?*const anyopaque, num_values: CFIndex, callbacks: ?*const anyopaque) ?CFArrayRef;

extern "c" fn FSEventStreamCreate(
    alloc: CFAllocatorRef,
    callback: FSEventStreamCallback,
    context: ?*FSEventStreamContext,
    paths_to_watch: CFArrayRef,
    since_when: FSEventStreamEventId,
    latency: CFTimeInterval,
    flags: FSEventStreamCreateFlags,
) ?FSEventStreamRef;
extern "c" fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, queue: dispatch.queue_t) void;
extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) bool;
extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;
