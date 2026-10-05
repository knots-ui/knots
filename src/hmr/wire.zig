//! A compact binary encoding for values that cross the host and guest
//! boundary. Integers are little endian, slices are length prefixed.

const std = @import("std");

pub const bytes_max: usize = 32 * 1024 * 1024;
pub const Error = error{ InvalidWire, LimitExceeded, OutOfMemory, Unsupported };

pub fn encode(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: anytype) Error!void {
    var writer: Writer = .{ .allocator = allocator, .list = list };
    try writer.value(@TypeOf(value), &value);
}

pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!T {
    var reader: Reader = .{ .allocator = allocator, .data = bytes };
    const result = try reader.value(T);
    if (reader.offset != bytes.len)
        return error.InvalidWire;

    return result;
}

/// Hashes the encoding of `T`: field names, kinds and widths. Type names are
/// not included, because module names are different in host and guest builds.
pub fn fingerprint(comptime T: type) u32 {
    return comptime hash: {
        @setEvalBranchQuota(1_000_000);
        var hasher = std.hash.Wyhash.init(0);
        shape(&hasher, T, &.{});
        break :hash @truncate(hasher.final());
    };
}

fn shape(comptime hasher: *std.hash.Wyhash, comptime T: type, comptime enclosing: []const type) void {
    for (enclosing) |outer| {
        if (outer == T)
            return hasher.update("recursive");
    }

    const inner = enclosing ++ [_]type{T};
    hasher.update(@tagName(@typeInfo(T)));
    switch (@typeInfo(T)) {
        .int => hasher.update(@typeName(Wide(T))),
        .float => hasher.update(@typeName(T)),
        .@"enum" => |info| {
            hasher.update(@typeName(Wide(info.tag_type)));
            hasher.update(@tagName(info.mode));
            for (info.field_names, info.field_values) |name, value|
                hasher.update(std.fmt.comptimePrint("{s}={d};", .{ name, value }));
        },
        .optional => |info| shape(hasher, info.child, inner),
        .array => |info| {
            hasher.update(std.fmt.comptimePrint("{d}", .{info.len}));
            shape(hasher, info.child, inner);
        },
        .vector => |info| {
            hasher.update(std.fmt.comptimePrint("{d}", .{info.len}));
            shape(hasher, info.child, inner);
        },
        .@"struct" => |info| if (info.backing_integer) |Backing| shape(hasher, Backing, inner) else {
            for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (attrs.@"comptime")
                    continue;

                hasher.update(name);
                shape(hasher, Field, inner);
            }
        },
        .@"union" => |info| for (info.field_names, info.field_types) |name, Field| {
            hasher.update(name);
            shape(hasher, Field, inner);
        },
        .pointer => |info| {
            hasher.update(@tagName(info.size));
            if (transferable(info.child))
                shape(hasher, info.child, inner);
        },
        else => {},
    }
}

fn Wide(comptime T: type) type {
    if (T == usize)
        return u64;

    if (T == isize)
        return i64;

    return std.math.ByteAlignedInt(T);
}

fn transferable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"opaque", .@"fn" => false,
        else => true,
    };
}

const Writer = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    fn int(self: *Writer, comptime I: type, number: I) Error!void {
        const size = @divExact(@bitSizeOf(I), 8);
        if (self.list.items.len + size > bytes_max)
            return error.LimitExceeded;

        std.mem.writeInt(I, try self.list.addManyAsArray(self.allocator, size), number, .little);
    }

    fn value(self: *Writer, comptime T: type, pointer: *const T) Error!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try self.int(u8, @intFromBool(pointer.*)),
            .int => try self.int(Wide(T), pointer.*),
            .float => try self.int(@Int(.unsigned, @bitSizeOf(T)), @bitCast(pointer.*)),
            .@"enum" => |info| try self.int(Wide(info.tag_type), @backingInt(pointer.*)),
            .optional => |info| if (pointer.*) |child| {
                try self.int(u8, 1);
                try self.value(info.child, &child);
            } else try self.int(u8, 0),
            .array => |info| for (pointer) |*element|
                try self.value(info.child, element),
            .vector => |info| {
                const elements: [info.len]info.child = pointer.*;
                try self.value([info.len]info.child, &elements);
            },
            .@"struct" => |info| if (info.backing_integer) |Backing| {
                try self.int(Wide(Backing), @bitCast(pointer.*));
            } else inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (attrs.@"comptime")
                    continue;

                const field: Field = @field(pointer.*, name);
                try self.value(Field, &field);
            },
            .@"union" => |info| {
                const Tag = info.tag_type orelse return error.Unsupported;
                inline for (info.field_names, info.field_types, 0..) |name, Field, index| {
                    if (pointer.* == @field(Tag, name)) {
                        try self.int(u32, index);
                        const payload: Field = @field(pointer.*, name);
                        return self.value(Field, &payload);
                    }
                }
                unreachable;
            },
            .pointer => |info| {
                if (comptime !transferable(info.child))
                    return error.Unsupported;

                switch (info.size) {
                    .one => try self.value(info.child, pointer.*),
                    .slice => {
                        if (pointer.len > bytes_max)
                            return error.LimitExceeded;

                        try self.int(u32, @intCast(pointer.len));
                        if (info.child == u8) {
                            if (self.list.items.len + pointer.len > bytes_max)
                                return error.LimitExceeded;

                            return self.list.appendSlice(self.allocator, pointer.*);
                        }

                        for (pointer.*) |*element|
                            try self.value(info.child, element);
                    },
                    else => return error.Unsupported,
                }
            },
            else => return error.Unsupported,
        }
    }
};

const Reader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize = 0,

    fn raw(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.data.len - self.offset)
            return error.InvalidWire;

        defer self.offset += count;
        return self.data[self.offset..][0..count];
    }

    fn int(self: *Reader, comptime I: type) Error!I {
        const size = @divExact(@bitSizeOf(I), 8);
        return std.mem.readInt(I, (try self.raw(size))[0..size], .little);
    }

    fn value(self: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return switch (try self.int(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidWire,
            },
            .int => return std.math.cast(T, try self.int(Wide(T))) orelse error.InvalidWire,
            .float => return @bitCast(try self.int(@Int(.unsigned, @bitSizeOf(T)))),
            .@"enum" => |info| {
                const number = std.math.cast(info.tag_type, try self.int(Wide(info.tag_type))) orelse return error.InvalidWire;
                if (info.mode == .nonexhaustive)
                    return @fromBackingInt(number);

                inline for (info.field_values) |field_value| {
                    if (number == field_value)
                        return @fromBackingInt(field_value);
                }

                return error.InvalidWire;
            },
            .optional => |info| return switch (try self.int(u8)) {
                0 => null,
                1 => try self.value(info.child),
                else => error.InvalidWire,
            },
            .array => |info| {
                var result: T = undefined;
                for (&result) |*element|
                    element.* = try self.value(info.child);

                return result;
            },
            .vector => |info| return try self.value([info.len]info.child),
            .@"struct" => |info| {
                if (info.backing_integer) |Backing| {
                    const bits = std.math.cast(Backing, try self.int(Wide(Backing))) orelse return error.InvalidWire;
                    return @bitCast(bits);
                }

                var result: T = undefined;
                inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                    if (!attrs.@"comptime")
                        @field(result, name) = try self.value(Field);
                }

                return result;
            },
            .@"union" => |info| {
                if (info.tag_type == null)
                    return error.InvalidWire;

                const index = try self.int(u32);
                inline for (info.field_names, info.field_types, 0..) |name, Field, field_index| {
                    if (index == field_index)
                        return @unionInit(T, name, try self.value(Field));
                }

                return error.InvalidWire;
            },
            .pointer => |info| {
                if (comptime !transferable(info.child))
                    return error.InvalidWire;

                switch (info.size) {
                    .one => {
                        const result = try self.allocator.create(info.child);
                        result.* = try self.value(info.child);
                        return result;
                    },
                    .slice => {
                        const count = try self.int(u32);

                        // Each element takes at least one byte.
                        if (count > self.data.len - self.offset)
                            return error.InvalidWire;

                        const borrowed = info.child == u8 and info.attrs.@"const" and info.sentinel_ptr == null;
                        if (borrowed)
                            return self.raw(count);

                        const result = try self.allocator.alloc(info.child, count);
                        for (result) |*element|
                            element.* = try self.value(info.child);

                        return result;
                    },
                    else => return error.InvalidWire,
                }
            },
            else => return error.InvalidWire,
        }
    }
};

test "values round trip and truncation is rejected" {
    const Mods = packed struct(u8) { shift: bool = false, ctrl: bool = false, _pad: u6 = 0 };
    const Kind = enum(u8) { a, b, c };
    const Value = struct {
        flag: bool,
        count: usize,
        code: u21,
        scale: f32,
        kind: Kind,
        mods: Mods,
        maybe: ?[2]f64,
        text: []const u8,
        list: []const Kind,
        keys: *const [3]bool,
        offset: @Vector(2, f32),
        choice: union(enum) { none, some: u32 },
    };
    const keys = [3]bool{ true, false, true };
    const original: Value = .{
        .flag = true,
        .count = 7,
        .code = 0x1f600,
        .scale = 1.5,
        .kind = .c,
        .mods = .{ .ctrl = true },
        .maybe = .{ 1, 2 },
        .text = "hello",
        .list = &.{ .b, .a },
        .keys = &keys,
        .offset = .{ 3, 4 },
        .choice = .{ .some = 9 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bytes: std.ArrayList(u8) = .empty;
    try encode(arena.allocator(), &bytes, original);
    const decoded = try decode(Value, arena.allocator(), bytes.items);

    try std.testing.expect(decoded.flag and decoded.count == 7 and decoded.code == 0x1f600 and decoded.scale == 1.5);
    try std.testing.expect(decoded.kind == .c and decoded.mods.ctrl and !decoded.mods.shift);
    try std.testing.expectEqual([2]f64{ 1, 2 }, decoded.maybe.?);
    try std.testing.expectEqualStrings("hello", decoded.text);
    try std.testing.expectEqualSlices(Kind, &.{ .b, .a }, decoded.list);
    try std.testing.expectEqual(keys, decoded.keys.*);
    try std.testing.expectEqual(@as(f32, 4), decoded.offset[1]);
    try std.testing.expectEqual(@as(u32, 9), decoded.choice.some);

    for (0..bytes.items.len) |length|
        try std.testing.expectError(error.InvalidWire, decode(Value, arena.allocator(), bytes.items[0..length]));

    try std.testing.expectError(error.InvalidWire, decode(bool, arena.allocator(), &.{2}));
    try std.testing.expectError(error.InvalidWire, decode(Kind, arena.allocator(), &.{3}));
}

test "pointers to code cannot be encoded" {
    const Callback = struct { run: *const fn () void };
    const value: Callback = .{ .run = struct {
        fn run() void {}
    }.run };

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try std.testing.expectError(error.Unsupported, encode(std.testing.allocator, &bytes, value));
}

test "fingerprints follow the encoding, not the names" {
    const A = struct { x: u32, list: []const struct { y: f32 } };
    const B = struct { x: u32, list: []const struct { y: f32 } };
    const Renamed = struct { z: u32, list: []const struct { y: f32 } };
    const Widened = struct { x: u64, list: []const struct { y: f32 } };
    const Node = struct { children: []const @This() };

    try std.testing.expectEqual(fingerprint(A), fingerprint(B));
    try std.testing.expect(fingerprint(A) != fingerprint(Renamed));
    try std.testing.expect(fingerprint(A) != fingerprint(Widened));
    try std.testing.expectEqual(fingerprint(usize), fingerprint(u64));
    _ = fingerprint(Node);
}
