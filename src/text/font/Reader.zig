const std = @import("std");

bytes: []const u8,

const Reader = @This();

pub const Error = error{OutOfBounds};

pub fn init(bytes: []const u8) Reader {
    return .{ .bytes = bytes };
}

pub fn sub(self: Reader, offset: usize) Error!Reader {
    if (offset > self.bytes.len) return error.OutOfBounds;
    return .{ .bytes = self.bytes[offset..] };
}

pub fn subLen(self: Reader, offset: usize, len: usize) Error!Reader {
    if (offset > self.bytes.len) return error.OutOfBounds;
    if (len > self.bytes.len - offset) return error.OutOfBounds;
    return .{ .bytes = self.bytes[offset..][0..len] };
}

pub fn has(self: Reader, offset: usize, len: usize) bool {
    if (offset > self.bytes.len) return false;
    return len <= self.bytes.len - offset;
}

pub fn read(self: Reader, comptime T: type, offset: usize) Error!T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    if (!self.has(offset, size)) return error.OutOfBounds;
    return std.mem.readInt(T, self.bytes[offset..][0..size], .big);
}

/// For data validated at compile time.
pub fn u16Unchecked(self: Reader, offset: usize) u16 {
    std.debug.assert(self.has(offset, 2));
    return std.mem.readInt(u16, self.bytes[offset..][0..2], .big);
}

pub fn u8At(self: Reader, offset: usize) Error!u8 {
    return self.read(u8, offset);
}

pub fn u16At(self: Reader, offset: usize) Error!u16 {
    return self.read(u16, offset);
}

pub fn i16At(self: Reader, offset: usize) Error!i16 {
    return self.read(i16, offset);
}

pub fn u24At(self: Reader, offset: usize) Error!u24 {
    return self.read(u24, offset);
}

pub fn u32At(self: Reader, offset: usize) Error!u32 {
    return self.read(u32, offset);
}

pub fn tagAt(self: Reader, offset: usize) Error!u32 {
    return self.read(u32, offset);
}

pub fn offset16(self: Reader, offset: usize) Error!?Reader {
    const value = try self.u16At(offset);
    if (value == 0) return null;
    return try self.sub(value);
}

pub fn offset32(self: Reader, offset: usize) Error!?Reader {
    const value = try self.u32At(offset);
    if (value == 0) return null;
    return try self.sub(value);
}

pub fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

test "reads big-endian values and rejects out-of-bounds reads" {
    const reader = Reader.init(&.{ 0x01, 0x02, 0x03, 0x04, 0xff, 0xfe });
    try std.testing.expectEqual(@as(u16, 0x0102), try reader.u16At(0));
    try std.testing.expectEqual(@as(u32, 0x01020304), try reader.u32At(0));
    try std.testing.expectEqual(@as(i16, -2), try reader.i16At(4));
    try std.testing.expectError(error.OutOfBounds, reader.u32At(3));
    try std.testing.expectError(error.OutOfBounds, reader.u16At(std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfBounds, reader.subLen(4, 3));
    const sub_reader = try reader.sub(4);
    try std.testing.expectEqual(@as(u8, 0xfe), try sub_reader.u8At(1));
}
