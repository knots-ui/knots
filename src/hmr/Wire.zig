//! Bounded, fixed-width framing around pack. Never serialize a usize or slice
//! directly: pack slice lengths are target-sized, while this ABI spans wasm32
//! and 64-bit hosts. Scalar/record encoding is entirely owned by pack.
const std = @import("std");
const pack = @import("pack");

pub const version: u32 = 1;
pub const bytes_max: u32 = 32 * 1024 * 1024;
pub const items_max: u32 = 1 << 18;
pub const Error = error{ InvalidWire, LimitExceeded, UnsupportedVersion, OutOfMemory };

pub const Writer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Writer) void {
        std.debug.assert(self.data.items.len <= bytes_max);
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Error!void {
        std.debug.assert(@bitSizeOf(T) % 8 == 0);
        try self.record(value);
    }

    pub fn raw(self: *Writer, encoded: []const u8) Error!void {
        std.debug.assert(self.data.items.len <= bytes_max);
        if (encoded.len > bytes_max - self.data.items.len) return error.LimitExceeded;
        try self.data.appendSlice(self.allocator, encoded);
        std.debug.assert(self.data.items.len <= bytes_max);
    }

    pub fn bytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > bytes_max) return error.LimitExceeded;
        try self.int(u32, @intCast(value.len));
        try self.raw(value);
    }

    pub fn boolean(self: *Writer, value: bool) Error!void {
        try self.int(u8, @intFromBool(value));
    }

    pub fn float(self: *Writer, comptime T: type, value: T) Error!void {
        if (!std.math.isFinite(value)) return error.InvalidWire;
        try self.record(value);
    }

    pub fn record(self: *Writer, value: anytype) Error!void {
        // Records are fixed-size DTOs. Slices are framed by bytes/readCount.
        var buffer: [@sizeOf(@TypeOf(value)) * 2 + 64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        pack.write(value, &writer) catch return error.InvalidWire;
        try self.raw(writer.buffered());
    }
};

pub const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn raw(self: *Reader, count: usize) Error![]const u8 {
        std.debug.assert(self.offset <= self.data.len);
        if (self.data.len > bytes_max) return error.LimitExceeded;
        if (count > self.data.len - self.offset) return error.InvalidWire;
        const result = self.data[self.offset..][0..count];
        self.offset += count;
        std.debug.assert(self.offset <= self.data.len);
        return result;
    }

    pub fn int(self: *Reader, comptime T: type) Error!T {
        std.debug.assert(@bitSizeOf(T) % 8 == 0);
        return self.record(T);
    }

    pub fn bytes(self: *Reader) Error![]const u8 {
        return self.raw(try self.int(u32));
    }

    pub fn boolean(self: *Reader) Error!bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidWire,
        };
    }

    pub fn float(self: *Reader, comptime T: type) Error!T {
        const result = try self.record(T);
        if (!std.math.isFinite(result)) return error.InvalidWire;
        return result;
    }

    pub fn enumeration(self: *Reader, comptime T: type) Error!T {
        const tag = try self.int(u32);
        inline for (@typeInfo(T).@"enum".field_values) |value| {
            if (tag == value) return @fromBackingInt(@intCast(value));
        }
        return error.InvalidWire;
    }

    pub fn record(self: *Reader, comptime T: type) Error!T {
        std.debug.assert(self.offset <= self.data.len);
        if (self.data.len > bytes_max) return error.LimitExceeded;
        var reader = std.Io.Reader.fixed(self.data[self.offset..]);
        const result = pack.read(T, &reader) catch return error.InvalidWire;
        self.offset += reader.seek;
        std.debug.assert(self.offset <= self.data.len);
        return result;
    }

    pub fn end(self: *const Reader) Error!void {
        std.debug.assert(self.offset <= self.data.len);
        if (self.offset != self.data.len) return error.InvalidWire;
    }
};

test "wire rejects truncation, invalid booleans and nonfinite floats" {
    var reader: Reader = .{ .data = &.{2} };
    try std.testing.expectError(error.InvalidWire, reader.boolean());
    try std.testing.expectError(error.InvalidWire, reader.int(u64));
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(error.InvalidWire, writer.float(f32, std.math.inf(f32)));
    try writer.int(u32, 0x12345678);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, writer.data.items);
}
