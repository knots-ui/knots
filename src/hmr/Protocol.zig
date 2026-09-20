const std = @import("std");

pub const version: u32 = 1;
pub const bytes_max = 32 * 1024 * 1024;
pub const modules_max = 128;

pub const Entry = struct {
    id: []const u8,
    path: []const u8,
    hash: []const u8,
};

pub const Manifest = struct {
    modules: []const Entry,
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > 240) return false;
    var parts = std.mem.splitScalar(u8, id, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".")) return false;
        if (std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        };
    }
    return true;
}
