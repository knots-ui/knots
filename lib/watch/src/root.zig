//! Bounded, blocking filesystem change notifications.

const std = @import("std");
const builtin = @import("builtin");

pub const WaitResult = enum { dirty, timeout };

const Backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    else => @import("poll.zig"),
};

backend: Backend,

const Watch = @This();

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    directory: []const u8,
) !Watch {
    std.debug.assert(directory.len > 0);
    std.debug.assert(@intFromPtr(should_stop) > 0);
    return .{ .backend = try Backend.init(io, allocator, should_stop, directory) };
}

pub fn deinit(self: *Watch) void {
    std.debug.assert(@intFromPtr(self) > 0);
    self.backend.deinit();
    self.* = undefined;
}

/// A zero timeout blocks until a filesystem event or an explicit wake.
pub fn wait(self: *Watch, timeout_ms: u64) WaitResult {
    std.debug.assert(@intFromPtr(self) > 0);
    const result = self.backend.wait(timeout_ms);
    std.debug.assert(result == .dirty or result == .timeout);
    return result;
}

pub fn wake(self: *Watch) void {
    std.debug.assert(@intFromPtr(self) > 0);
    self.backend.wake();
}

/// The first path from the most recently returned native event batch.
/// The slice is owned by the watcher and remains valid until its next `wait`.
pub fn changedPath(self: *const Watch) ?[]const u8 {
    std.debug.assert(@intFromPtr(self) > 0);
    return self.backend.changedPath();
}

pub fn wakeMainLoop() void {
    if (builtin.os.tag == .macos) @import("macos.zig").wakeMainLoop();
}

test {
    _ = Backend;
}

test "reports a file change" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    var should_stop: std.atomic.Value(bool) = .init(false);
    var watcher = try Watch.init(io, std.testing.allocator, &should_stop, directory);
    defer watcher.deinit();

    var writer: std.Io.Group = .init;
    try writer.concurrent(io, testWriteFile, .{ io, directory });
    defer writer.await(io) catch {};

    try std.testing.expectEqual(WaitResult.dirty, watcher.wait(1_000));
    if (builtin.os.tag == .linux) {
        const path = watcher.changedPath() orelse return error.ExpectedChangedPath;
        try std.testing.expect(std.mem.endsWith(u8, path, "/changed"));
    }
}

fn testWriteFile(io: std.Io, directory: []const u8) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    const path = std.fs.path.join(std.testing.allocator, &.{ directory, "changed" }) catch return;
    defer std.testing.allocator.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "changed", .flags = .{} }) catch return;
}
