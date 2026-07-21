const std = @import("std");

pub fn copy(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) std.mem.Allocator.Error![][]const u8 {
    std.debug.assert(paths.len > 0);
    std.debug.assert(paths.len <= std.math.maxInt(u8));

    const copies = try allocator.alloc([]const u8, paths.len);
    var copied_count: u32 = 0;
    errdefer {
        for (copies[0..copied_count]) |path| allocator.free(path);
        allocator.free(copies);
    }

    for (paths) |path| {
        std.debug.assert(copied_count < paths.len);
        copies[copied_count] = try allocator.dupe(u8, path);
        copied_count += 1;
    }
    std.debug.assert(copied_count == paths.len);
    return copies;
}

fn testCopy(allocator: std.mem.Allocator) !void {
    const source = [_][]const u8{ "first/path", "second/path", "third/path" };
    const copies = try copy(allocator, &source);
    defer {
        for (copies) |path| allocator.free(path);
        allocator.free(copies);
    }

    try std.testing.expectEqual(source.len, copies.len);
    for (source, copies) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "copy frees every partial result after each allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testCopy,
        .{},
    );
}
