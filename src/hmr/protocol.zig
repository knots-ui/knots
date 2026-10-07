const std = @import("std");

pub const Manifest = struct {
    app: ?[]const u8 = null,
    build_error: ?[]const u8 = null,
};

pub fn contentHash(bytes: []const u8) [16]u8 {
    var result: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)}) catch unreachable;
    return result;
}
