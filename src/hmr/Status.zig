const std = @import("std");

pub const version: u32 = 1;
pub const bytes_max: usize = 64 * 1024;
pub const message_max: usize = 24 * 1024;
pub const field_max: usize = 32;

pub const kind_ready = "ready";
pub const kind_compile_error = "compile_error";
pub const kind_error = "error";

pub const Value = struct {
    version: u32 = version,
    kind: []const u8,
    phase: []const u8,
    message: []const u8 = "",
};

pub fn valid(value: *const Value) bool {
    std.debug.assert(@intFromPtr(value) > 0);
    if (value.version != version) return false;
    if (value.kind.len == 0) return false;
    if (value.kind.len > field_max) return false;
    if (value.phase.len == 0) return false;
    if (value.phase.len > field_max) return false;
    if (value.message.len > message_max) return false;
    if (std.mem.eql(u8, value.kind, kind_ready)) return value.message.len == 0;
    if (std.mem.eql(u8, value.kind, kind_compile_error)) return value.message.len > 0;
    if (std.mem.eql(u8, value.kind, kind_error)) return value.message.len > 0;
    return false;
}

test "status values validate ready and compile errors" {
    const ready: Value = .{ .kind = kind_ready, .phase = "initial" };
    try std.testing.expect(valid(&ready));

    const failure: Value = .{ .kind = kind_compile_error, .phase = "reload", .message = "error: expected expression" };
    try std.testing.expect(valid(&failure));

    const invalid: Value = .{ .kind = "unknown", .phase = "reload" };
    try std.testing.expect(!valid(&invalid));

    const empty_failure: Value = .{ .kind = kind_compile_error, .phase = "reload" };
    try std.testing.expect(!valid(&empty_failure));
}
