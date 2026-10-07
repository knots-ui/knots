const std = @import("std");
const wire = @import("wire");
const abi = @import("abi");

const Reply = @This();

arena: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,

pub fn ok(self: *Reply, comptime T: type, value: T) !void {
    try wire.encode(self.arena, &self.bytes, abi.Reply(T){ .ok = value });
}

pub fn failed(self: *Reply, err: anyerror) !void {
    self.bytes.clearRetainingCapacity();
    try wire.encode(self.arena, &self.bytes, abi.Reply(void){ .failed = .of(err) });
}
