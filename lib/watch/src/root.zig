const std = @import("std");
const builtin = @import("builtin");

const Watch = @This();
const log = std.log.scoped(.watch);

io: std.Io,
native: ?Native,

const Native = switch (builtin.os.tag) {
    .macos => MacOS,
    .linux => Linux,
    .windows => Windows,
    else => Unsupported,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator) Watch {
    const native = Native.init(allocator) catch |err| {
        log.warn("event=file_events_unavailable error={t} action=rescan", .{err});
        return .{ .io = io, .native = null };
    };
    return .{ .io = io, .native = native };
}

pub fn deinit(self: *Watch) void {
    if (self.native) |*native| native.deinit();
}

pub fn setDirectories(self: *Watch, directories: []const []const u8) !void {
    if (self.native) |*native| try native.setDirectories(directories);
}

pub fn wait(self: *Watch, timeout_ms: u32) bool {
    if (self.native) |*native| return native.wait(timeout_ms);
    std.Io.sleep(self.io, .fromMilliseconds(timeout_ms), .awake) catch {};
    return false;
}

const Unsupported = struct {
    fn init(_: std.mem.Allocator) !Unsupported {
        return error.Unsupported;
    }
    fn deinit(_: *Unsupported) void {}
    fn setDirectories(_: *Unsupported, _: []const []const u8) !void {}
    fn wait(_: *Unsupported, _: u32) bool {
        return false;
    }
};

const MacOS = struct {
    const dispatch = std.c.dispatch;

    allocator: std.mem.Allocator,
    stream: ?*anyopaque = null,
    queue: dispatch.queue_t,
    semaphore: dispatch.semaphore_t,

    fn init(allocator: std.mem.Allocator) !MacOS {
        const semaphore = dispatch.semaphore_create(0) orelse return error.SystemResources;
        errdefer _ = semaphore.as_object().release();
        const queue = dispatch.queue_create("knots-watch", dispatch.QUEUE_SERIAL()) orelse return error.SystemResources;
        return .{ .allocator = allocator, .queue = queue, .semaphore = semaphore };
    }

    fn deinit(self: *MacOS) void {
        self.stop();
        _ = self.queue.as_object().release();
        _ = self.semaphore.as_object().release();
    }

    fn stop(self: *MacOS) void {
        const stream = self.stream orelse return;
        FSEventStreamStop(stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        self.stream = null;
    }

    fn setDirectories(self: *MacOS, directories: []const []const u8) !void {
        self.stop();
        if (directories.len == 0) return;
        const strings = try self.allocator.alloc(?*const anyopaque, directories.len);
        defer self.allocator.free(strings);
        var created: usize = 0;
        defer for (strings[0..created]) |string| CFRelease(string.?);
        for (directories) |directory| {
            const path = try self.allocator.dupeSentinel(u8, directory, 0);
            defer self.allocator.free(path);
            strings[created] = CFStringCreateWithCString(null, path.ptr, 0x08000100) orelse return error.SystemResources;
            created += 1;
        }
        const paths = CFArrayCreate(null, strings.ptr, @intCast(strings.len), null) orelse return error.SystemResources;
        defer CFRelease(paths);

        var context: StreamContext = .{ .info = @ptrCast(self.semaphore) };
        const stream = FSEventStreamCreate(null, &onEvents, &context, paths, since_now, 0.01, .{ .no_defer = true, .file_events = true }) orelse return error.SystemResources;
        FSEventStreamSetDispatchQueue(stream, self.queue);
        if (!FSEventStreamStart(stream)) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            return error.StartFailed;
        }
        self.stream = stream;
    }

    fn wait(self: *MacOS, timeout_ms: u32) bool {
        return self.semaphore.wait(dispatch.time(.NOW, @as(i64, timeout_ms) * std.time.ns_per_ms)) == 0;
    }

    fn onEvents(_: *const anyopaque, info: ?*anyopaque, _: usize, _: ?*anyopaque, _: [*]const u32, _: [*]const u64) callconv(.c) void {
        const semaphore: dispatch.semaphore_t = @ptrCast(@alignCast(info.?));
        _ = semaphore.signal();
    }

    const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
    const Flags = packed struct(u32) {
        use_cf_types: bool = false,
        no_defer: bool = false,
        watch_root: bool = false,
        ignore_self: bool = false,
        file_events: bool = false,
        _: u27 = 0,
    };
    const StreamContext = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };
    const Callback = *const fn (*const anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;

    extern "c" fn CFRelease(object: *const anyopaque) void;
    extern "c" fn CFStringCreateWithCString(allocator: ?*const anyopaque, string: [*:0]const u8, encoding: u32) ?*const anyopaque;
    extern "c" fn CFArrayCreate(allocator: ?*const anyopaque, values: [*]const ?*const anyopaque, count: isize, callbacks: ?*const anyopaque) ?*const anyopaque;
    extern "c" fn FSEventStreamCreate(allocator: ?*const anyopaque, callback: Callback, context: *StreamContext, paths: *const anyopaque, since: u64, latency: f64, flags: Flags) ?*anyopaque;
    extern "c" fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: dispatch.queue_t) void;
    extern "c" fn FSEventStreamStart(stream: *anyopaque) bool;
    extern "c" fn FSEventStreamStop(stream: *anyopaque) void;
    extern "c" fn FSEventStreamInvalidate(stream: *anyopaque) void;
    extern "c" fn FSEventStreamRelease(stream: *anyopaque) void;
};

const Linux = struct {
    const linux = std.os.linux;
    const mask = linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO;

    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    watches: std.ArrayList(i32) = .empty,

    fn init(allocator: std.mem.Allocator) !Linux {
        const result = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return error.SystemResources;
        return .{ .allocator = allocator, .fd = @intCast(result) };
    }

    fn deinit(self: *Linux) void {
        _ = linux.close(self.fd);
        self.watches.deinit(self.allocator);
    }

    fn setDirectories(self: *Linux, directories: []const []const u8) !void {
        for (self.watches.items) |descriptor| _ = linux.inotify_rm_watch(self.fd, descriptor);
        self.watches.clearRetainingCapacity();
        for (directories) |directory| {
            const path = try self.allocator.dupeSentinel(u8, directory, 0);
            defer self.allocator.free(path);
            const result = linux.inotify_add_watch(self.fd, path.ptr, mask);
            switch (linux.errno(result)) {
                .SUCCESS => try self.watches.append(self.allocator, @intCast(result)),
                .NOENT, .NOTDIR => {},
                else => return error.SystemResources,
            }
        }
    }

    fn wait(self: *Linux, timeout_ms: u32) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return false;
        if (ready == 0) return false;
        var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (std.posix.read(self.fd, &buffer)) |length| {
            if (length == 0) break;
        } else |_| {}
        return true;
    }
};

const Windows = struct {
    const win32 = @import("win32").everything;
    const directories_max = 64;

    const Directory = struct {
        handle: win32.HANDLE,
        event: win32.HANDLE,
        overlapped: win32.OVERLAPPED,
        buffer: []align(@alignOf(win32.FILE_NOTIFY_INFORMATION)) u8,
    };

    allocator: std.mem.Allocator,
    directories: std.ArrayList(*Directory) = .empty,

    fn init(allocator: std.mem.Allocator) !Windows {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Windows) void {
        self.clear();
        self.directories.deinit(self.allocator);
    }

    fn clear(self: *Windows) void {
        for (self.directories.items) |directory| {
            _ = win32.CancelIo(directory.handle);
            _ = win32.CloseHandle(directory.handle);
            _ = win32.CloseHandle(directory.event);
            self.allocator.free(directory.buffer);
            self.allocator.destroy(directory);
        }
        self.directories.clearRetainingCapacity();
    }

    fn setDirectories(self: *Windows, paths: []const []const u8) !void {
        self.clear();
        if (paths.len > directories_max) return error.TooManyDirectories;
        for (paths) |path| try self.add(path);
    }

    fn add(self: *Windows, directory_path: []const u8) !void {
        const path = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, directory_path);
        defer self.allocator.free(path);
        const handle = win32.CreateFileW(path.ptr, win32.FILE_LIST_DIRECTORY, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, win32.OPEN_EXISTING, .{ .FILE_FLAG_BACKUP_SEMANTICS = 1, .FILE_FLAG_OVERLAPPED = 1 }, null);
        if (handle == win32.INVALID_HANDLE_VALUE) return;
        errdefer _ = win32.CloseHandle(handle);
        const event = win32.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        errdefer _ = win32.CloseHandle(event);
        const directory = try self.allocator.create(Directory);
        errdefer self.allocator.destroy(directory);
        // 64 KiB is the limit for network shares.
        const buffer = try self.allocator.alignedAlloc(u8, .of(win32.FILE_NOTIFY_INFORMATION), 64 * 1024);
        errdefer self.allocator.free(buffer);
        directory.* = .{ .handle = handle, .event = event, .overlapped = undefined, .buffer = buffer };
        try listen(directory);
        try self.directories.append(self.allocator, directory);
    }

    fn wait(self: *Windows, timeout_ms: u32) bool {
        var events: [directories_max]?win32.HANDLE = undefined;
        const count = self.directories.items.len;
        if (count == 0) {
            win32.Sleep(timeout_ms);
            return false;
        }
        for (self.directories.items, events[0..count]) |directory, *event| event.* = directory.event;
        const result = @backingInt(win32.WaitForMultipleObjects(@intCast(count), &events, 0, timeout_ms));
        const first = @backingInt(win32.WAIT_OBJECT_0);
        if (result < first or result >= first + count) return false;
        const directory = self.directories.items[result - first];
        var length: u32 = 0;
        _ = win32.GetOverlappedResult(directory.handle, &directory.overlapped, &length, 0);
        listen(directory) catch {};
        return true;
    }

    fn listen(directory: *Directory) !void {
        directory.overlapped = std.mem.zeroes(win32.OVERLAPPED);
        directory.overlapped.hEvent = directory.event;
        _ = win32.ResetEvent(directory.event);
        const filter: win32.FILE_NOTIFY_CHANGE = .{ .FILE_NAME = 1, .DIR_NAME = 1, .SIZE = 1, .LAST_WRITE = 1, .CREATION = 1 };
        if (win32.ReadDirectoryChangesW(directory.handle, directory.buffer.ptr, @intCast(directory.buffer.len), 0, filter, null, &directory.overlapped, null) == 0) return error.ReadDirectoryChangesFailed;
    }
};

test "reports a change in a watched directory, not in others" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try temporary.dir.createDirPath(io, "watched");
    try temporary.dir.createDirPath(io, "other");
    const watched = try std.fs.path.join(std.testing.allocator, &.{ directory, "watched" });
    defer std.testing.allocator.free(watched);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing" });
    defer std.testing.allocator.free(missing);

    var watch: Watch = .init(io, std.testing.allocator);
    defer watch.deinit();
    try watch.setDirectories(&.{ watched, missing });
    // FSEvents can still report changes from just before the stream started.
    while (watch.wait(100)) {}
    if (builtin.os.tag != .macos) {
        try temporary.dir.writeFile(io, .{ .sub_path = "other/file.zig", .data = "changed", .flags = .{} });
        try std.testing.expect(!watch.wait(200));
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "watched/file.zig", .data = "changed", .flags = .{} });
    try std.testing.expect(watch.wait(2000));
}
