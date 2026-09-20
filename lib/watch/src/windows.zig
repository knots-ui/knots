//! Windows filesystem watcher backend, built on ReadDirectoryChangesW.
//!
//! ReadDirectoryChangesW with `bWatchSubtree = TRUE` gives a recursive watch over
//! the whole working tree from a single directory handle. We use overlapped
//! (asynchronous) I/O with a manual-reset event so `wait` can block with a timeout
//! and `wake` can release it on stop. All Win32 symbols come from the existing
//! `win32` (zigwin32) dependency — no hand-written declarations.

const std = @import("std");
const win32 = @import("win32").everything;
const Watcher = @import("root.zig");
const WaitResult = Watcher.WaitResult;

const Windows = @This();

// 64 KB is the documented buffer-size limit when monitoring over a network share.
const buffer_len = 64 * 1024;

dir: win32.HANDLE,
event: win32.HANDLE,
overlapped: win32.OVERLAPPED,
buffer: []align(@alignOf(win32.FILE_NOTIFY_INFORMATION)) u8,
allocator: std.mem.Allocator,
should_stop: *std.atomic.Value(bool),
listening: bool,

const notify_filter: win32.FILE_NOTIFY_CHANGE = .{
    .FILE_NAME = 1,
    .DIR_NAME = 1,
    .SIZE = 1,
    .LAST_WRITE = 1,
    .CREATION = 1,
};

pub fn init(
    _: std.Io,
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    workdir: []const u8,
) !Windows {
    const workdir_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, workdir);
    defer allocator.free(workdir_w);

    const dir = win32.CreateFileW(
        workdir_w.ptr,
        win32.FILE_LIST_DIRECTORY,
        .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, // share READ|WRITE|DELETE
        null,
        win32.OPEN_EXISTING,
        .{ .FILE_FLAG_BACKUP_SEMANTICS = 1, .FILE_FLAG_OVERLAPPED = 1 },
        null,
    );
    if (dir == win32.INVALID_HANDLE_VALUE) return error.OpenDirFailed;
    errdefer _ = win32.CloseHandle(dir);

    const event = win32.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed; // manual-reset, initially unsignaled
    errdefer _ = win32.CloseHandle(event);

    const buffer = try allocator.alignedAlloc(u8, .of(win32.FILE_NOTIFY_INFORMATION), buffer_len);
    errdefer allocator.free(buffer);

    var self: Windows = .{
        .dir = dir,
        .event = event,
        .overlapped = std.mem.zeroes(win32.OVERLAPPED),
        .buffer = buffer,
        .allocator = allocator,
        .should_stop = should_stop,
        .listening = false,
    };
    try self.arm();
    return self;
}

pub fn deinit(self: *Windows) void {
    if (self.listening) _ = win32.CancelIo(self.dir);
    _ = win32.CloseHandle(self.dir);
    _ = win32.CloseHandle(self.event);
    self.allocator.free(self.buffer);
    self.* = undefined;
}

/// Start (or restart) an asynchronous ReadDirectoryChangesW request.
fn arm(self: *Windows) !void {
    self.overlapped = std.mem.zeroes(win32.OVERLAPPED);
    self.overlapped.hEvent = self.event;
    _ = win32.ResetEvent(self.event);
    const ok = win32.ReadDirectoryChangesW(
        self.dir,
        self.buffer.ptr,
        @intCast(self.buffer.len),
        1, // bWatchSubtree = TRUE (recursive)
        notify_filter,
        null,
        &self.overlapped,
        null,
    );
    if (ok == 0) return error.ReadDirectoryChangesFailed;
    self.listening = true;
}

pub fn wait(self: *Windows, timeout_ms: u64) WaitResult {
    const ms: u32 = if (timeout_ms == 0) win32.INFINITE else std.math.cast(u32, timeout_ms) orelse win32.INFINITE;
    const rc = win32.WaitForSingleObjectEx(self.event, ms, 1); // alertable
    if (rc != win32.WAIT_OBJECT_0) return .timeout; // timeout / wake / APC

    if (self.should_stop.load(.acquire)) return .timeout;

    // Consume the completed request, then re-arm for the next batch. We don't
    // inspect which paths changed — `git status` is the source of truth.
    var bytes: u32 = 0;
    _ = win32.GetOverlappedResult(self.dir, &self.overlapped, &bytes, 0);
    self.listening = false;
    self.arm() catch {};
    return .dirty;
}

/// Release `wait` so the loop can observe `should_stop` and exit promptly.
pub fn wake(self: *Windows) void {
    _ = win32.SetEvent(self.event);
}

pub fn changedPath(_: *const Windows) ?[]const u8 {
    return null;
}
