const std = @import("std");
const allocator = @import("platform_impl").allocator;

pub var bytes: std.ArrayList(u8) = .empty;

export fn knots_buffer(length: usize) usize {
    // An empty buffer still has an address in memory.
    bytes.ensureTotalCapacity(allocator, @max(length, 1)) catch return 0;
    bytes.items.len = length;
    return @intFromPtr(bytes.items.ptr);
}
