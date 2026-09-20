//! Portable polling watcher backend.
//!
//! This is the fallback used on platforms without a native backend, and when a
//! native backend fails to initialise (old kernel, sandbox, network FS). It is
//! intentionally cheaper than the native backends: detect high-signal repository
//! changes, then let the main thread re-run `git status`.
//!
//! Each `wait` sleeps in small slices (so `stop` is observed promptly) up to the
//! poll interval, then stats the repository root and key `.git` files. This is a
//! degraded fallback: it catches index/branch/checkout changes and root-level
//! directory changes without recursively walking large asset trees.

const std = @import("std");
const Watcher = @import("root.zig");
const WaitResult = Watcher.WaitResult;
const fingerprint_util = @import("fingerprint.zig");

const poll_interval_ms: u64 = 750;
const sleep_slice_ms: u64 = 50;

const Poll = @This();

io: std.Io,
should_stop: *std.atomic.Value(bool),
workdir: []const u8,
last_fingerprint: ?u64,

pub fn init(
    io: std.Io,
    _: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    workdir: []const u8,
) !Poll {
    var self: Poll = .{
        .io = io,
        .should_stop = should_stop,
        .workdir = workdir,
        .last_fingerprint = null,
    };
    // Seed the baseline so the first real change (not the watcher starting up)
    // is what trips `wait`.
    self.last_fingerprint = self.fingerprint();
    return self;
}

pub fn deinit(self: *Poll) void {
    self.* = undefined;
}

/// Polling has no blocking syscall to interrupt; the slice-sleep already checks
/// `should_stop`, so waking is a no-op.
pub fn wake(self: *Poll) void {
    _ = self;
}

pub fn wait(self: *Poll, timeout_ms: u64) WaitResult {
    const budget = if (timeout_ms == 0 or timeout_ms > poll_interval_ms) poll_interval_ms else timeout_ms;
    var slept: u64 = 0;
    while (slept < budget) {
        if (self.should_stop.load(.acquire)) return .timeout;
        const slice = @min(sleep_slice_ms, budget - slept);
        self.io.sleep(.{ .nanoseconds = @intCast(slice * @as(u64, std.time.ns_per_ms)) }, .real) catch return .timeout;
        slept += slice;
    }
    if (self.should_stop.load(.acquire)) return .timeout;

    const fp = self.fingerprint() orelse return .timeout; // transient error: try again next tick
    if (self.last_fingerprint) |last| {
        if (fp == last) return .timeout;
    }
    self.last_fingerprint = fp;
    return .dirty;
}

pub fn changedPath(_: *const Poll) ?[]const u8 {
    return null;
}

/// Hash of cheap repository signals. Returns null on a transient stat failure so
/// the caller skips this tick rather than spuriously refreshing.
fn fingerprint(self: *Poll) ?u64 {
    return fingerprint_util.cheapSignals(self.io, self.workdir);
}
