//! Finds which of the application's files changed (see graph.zig).

const std = @import("std");

const missing_stamp: u64 = 0;

pub const Stamp = struct { path: []const u8, stamp: u64 };

/// The stamp changes when the file is written, created or deleted. It comes
/// from `stat`, so it is cheap to poll. `paths` must be sorted. The result
/// owns copies of the paths, because the graph that owns `paths` is replaced
/// when imports change.
pub fn stamps(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) ![]Stamp {
    const result = try allocator.alloc(Stamp, paths.len);
    for (paths, result) |source_path, *entry| {
        const path = try allocator.dupe(u8, source_path);
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                entry.* = .{ .path = path, .stamp = missing_stamp };
                continue;
            },
            else => return err,
        };

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&stat.size));
        hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
        entry.* = .{ .path = path, .stamp = hasher.final() };
    }
    return result;
}

pub fn changed(allocator: std.mem.Allocator, before: []const Stamp, after: []const Stamp) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var old: usize = 0;
    var new: usize = 0;
    while (old < before.len or new < after.len) {
        switch (compare(before, after, old, new)) {
            .lt => {
                try result.append(allocator, try allocator.dupe(u8, before[old].path));
                old += 1;
            },
            .gt => {
                try result.append(allocator, try allocator.dupe(u8, after[new].path));
                new += 1;
            },
            .eq => {
                if (before[old].stamp != after[new].stamp)
                    try result.append(allocator, try allocator.dupe(u8, after[new].path));

                old += 1;
                new += 1;
            },
        }
    }
    return result.items;
}

fn compare(before: []const Stamp, after: []const Stamp, old: usize, new: usize) std.math.Order {
    if (old == before.len)
        return .gt;

    if (new == after.len)
        return .lt;

    return std.mem.order(u8, before[old].path, after[new].path);
}

test "stamps report added, removed and written paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]Stamp{
        .{ .path = "a", .stamp = 1 },
        .{ .path = "b", .stamp = 1 },
        .{ .path = "c", .stamp = 1 },
    };
    const after = [_]Stamp{
        .{ .path = "a", .stamp = 1 },
        .{ .path = "c", .stamp = 2 },
        .{ .path = "d", .stamp = 1 },
    };
    const result = try changed(arena.allocator(), &before, &after);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("b", result[0]);
    try std.testing.expectEqualStrings("c", result[1]);
    try std.testing.expectEqualStrings("d", result[2]);
}
