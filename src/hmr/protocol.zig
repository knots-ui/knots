//! What the dev server publishes in `hmr/manifest.json`. Artifacts live at
//! `hmr/artifacts/<hash>.wasm`.

const std = @import("std");

pub const Manifest = struct {
    modules: []const Entry = &.{},
    build_error: ?[]const u8 = null,
};

pub const Entry = struct {
    id: []const u8,
    hash: []const u8,
};

pub fn contentHash(bytes: []const u8) [16]u8 {
    var result: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)}) catch unreachable;
    return result;
}
