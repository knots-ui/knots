//! Linux filesystem watcher backend.
//!
//! Uses recursive inotify: a watch on the working tree root plus every existing
//! subdirectory. inotify is not recursive on its own, so CREATE and MOVED_TO
//! events for directories install watches immediately, including a recursive
//! scan for directory trees moved into the worktree.
//! Falls back to portable polling if inotify cannot be set up (e.g. the watch
//! limit is exhausted on a huge tree). Only `std` is used — no extra deps.
//!
//! `wait` blocks in `poll()` on the inotify fd plus a self-pipe that `wake` writes
//! to so the loop can observe `should_stop` and exit promptly. Events are drained
//! but not inspected — `git status` is the source of truth.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Watcher = @import("root.zig");
const WaitResult = Watcher.WaitResult;
const Poll = @import("poll.zig");

const Linux = @This();

const Impl = union(enum) {
    inotify: Inotify,
    poll: Poll,
};

const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CLOSE_WRITE |
    linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

const Inotify = struct {
    const Watch = struct {
        descriptor: i32,
        path: []u8,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    wake_r: posix.fd_t,
    wake_w: posix.fd_t,
    should_stop: *std.atomic.Value(bool),
    watches: std.ArrayList(Watch) = .empty,
    changed_path: ?[]u8 = null,

    fn wait(self: *Inotify, timeout_ms: u64) WaitResult {
        var fds = [_]posix.pollfd{
            .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_r, .events = posix.POLL.IN, .revents = 0 },
        };
        const t: i32 = if (timeout_ms == 0) -1 else std.math.cast(i32, timeout_ms) orelse -1;
        const n = posix.poll(&fds, t) catch return .timeout;
        if (n == 0 or self.should_stop.load(.acquire)) return .timeout;

        var dirty = false;
        self.clearChangedPath();
        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
            while (posix.read(self.fd, &buf)) |r| {
                if (r == 0) break;
                dirty = true;
                var offset: usize = 0;
                while (offset + @sizeOf(linux.inotify_event) <= r) {
                    const event: *const linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
                    const record_len = @sizeOf(linux.inotify_event) + @as(usize, event.len);
                    if (record_len > r - offset) break;
                    self.recordChangedPath(event);
                    self.handleEvent(event);
                    offset += record_len;
                }
                if (r < buf.len) break; // fully drained
            } else |_| {}
        }
        if (fds[1].revents & posix.POLL.IN != 0) {
            var drain: [256]u8 = undefined;
            _ = posix.read(self.wake_r, &drain) catch {};
        }
        return if (dirty) .dirty else .timeout;
    }

    fn wake(self: *Inotify) void {
        _ = linux.write(self.wake_w, &[_]u8{0}, 0);
    }

    fn deinit(self: *Inotify) void {
        _ = linux.close(self.fd);
        _ = linux.close(self.wake_r);
        _ = linux.close(self.wake_w);
        for (self.watches.items) |watch| self.allocator.free(watch.path);
        self.watches.deinit(self.allocator);
        self.clearChangedPath();
    }

    fn handleEvent(self: *Inotify, event: *const linux.inotify_event) void {
        if (event.mask & linux.IN.IGNORED != 0) {
            var index: usize = 0;
            while (index < self.watches.items.len) : (index += 1) {
                if (self.watches.items[index].descriptor != event.wd) continue;
                const removed = self.watches.swapRemove(index);
                self.allocator.free(removed.path);
                break;
            }
            return;
        }
        if (event.mask & linux.IN.ISDIR == 0 or event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) == 0) return;
        const name = event.getName() orelse return;
        for (self.watches.items) |watch| {
            if (watch.descriptor != event.wd) continue;
            const path = std.fs.path.join(self.allocator, &.{ watch.path, name }) catch return;
            defer self.allocator.free(path);
            self.watchDirectoryTree(path) catch {};
            return;
        }
    }

    fn clearChangedPath(self: *Inotify) void {
        if (self.changed_path) |path| self.allocator.free(path);
        self.changed_path = null;
    }

    fn recordChangedPath(self: *Inotify, event: *const linux.inotify_event) void {
        if (self.changed_path != null) return;
        for (self.watches.items) |watch| {
            if (watch.descriptor != event.wd) continue;
            const name = event.getName() orelse {
                self.changed_path = self.allocator.dupe(u8, watch.path) catch null;
                return;
            };
            self.changed_path = std.fs.path.join(self.allocator, &.{ watch.path, name }) catch null;
            return;
        }
    }

    fn watchDirectoryTree(self: *Inotify, path: []const u8) !void {
        try self.watchDirectory(path);
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var walker = try std.Io.Dir.walk(dir, self.allocator);
        defer walker.deinit();
        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const child = try std.fs.path.join(self.allocator, &.{ path, entry.path });
            defer self.allocator.free(child);
            self.watchDirectory(child) catch continue;
        }
    }

    fn watchDirectory(self: *Inotify, path: []const u8) !void {
        for (self.watches.items) |watch| {
            if (std.mem.eql(u8, watch.path, path)) return;
        }
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);
        const rc = linux.inotify_add_watch(self.fd, path_z.ptr, mask);
        if (linux.errno(rc) != .SUCCESS) return error.AddWatchFailed;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        for (self.watches.items) |*watch| {
            if (watch.descriptor != @as(i32, @intCast(rc))) continue;
            self.allocator.free(watch.path);
            watch.path = owned_path;
            return;
        }
        self.watches.append(self.allocator, .{ .descriptor = @intCast(rc), .path = owned_path }) catch |err| {
            _ = linux.inotify_rm_watch(self.fd, @intCast(rc));
            return err;
        };
    }
};

impl: Impl,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    workdir: []const u8,
) !Linux {
    if (initInotify(io, allocator, should_stop, workdir)) |ino| {
        return .{ .impl = .{ .inotify = ino } };
    } else |_| {}
    return .{ .impl = .{ .poll = try Poll.init(io, allocator, should_stop, workdir) } };
}

fn initInotify(
    io: std.Io,
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    workdir: []const u8,
) !Inotify {
    const init_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(init_rc) != .SUCCESS) return error.InotifyFailed;
    const fd: posix.fd_t = @intCast(init_rc);

    var pipe_fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (linux.errno(pipe_rc) != .SUCCESS) {
        _ = linux.close(fd);
        return error.InotifyFailed;
    }

    var inotify = Inotify{
        .io = io,
        .allocator = allocator,
        .fd = fd,
        .wake_r = pipe_fds[0],
        .wake_w = pipe_fds[1],
        .should_stop = should_stop,
    };
    errdefer inotify.deinit();
    try inotify.watchDirectoryTree(workdir);
    return inotify;
}

pub fn deinit(self: *Linux) void {
    switch (self.impl) {
        .inotify => |*i| i.deinit(),
        .poll => |*p| p.deinit(),
    }
    self.* = undefined;
}

pub fn wait(self: *Linux, timeout_ms: u64) WaitResult {
    return switch (self.impl) {
        .inotify => |*i| i.wait(timeout_ms),
        .poll => |*p| p.wait(timeout_ms),
    };
}

pub fn wake(self: *Linux) void {
    switch (self.impl) {
        .inotify => |*i| i.wake(),
        .poll => |*p| p.wake(),
    }
}

pub fn changedPath(self: *const Linux) ?[]const u8 {
    return switch (self.impl) {
        .inotify => |inotify| inotify.changed_path,
        .poll => null,
    };
}
