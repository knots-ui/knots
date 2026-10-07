const std = @import("std");

pub const bytes_max: usize = std.math.maxInt(u32);
pub const Error = error{ InvalidWire, LimitExceeded, OutOfMemory, Unsupported };

pub fn encode(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: anytype) Error!void {
    var writer: Writer = .{ .allocator = allocator, .list = list };
    try writer.value(@TypeOf(value), &value);
}

pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) Error!T {
    var reader: Reader = .{ .allocator = allocator, .data = bytes };
    const result = try reader.value(T);
    try reader.finish();
    return result;
}

/// Changes when the encoding of `T` does, so a reader can reject bytes that
/// another version of `T` wrote.
pub fn schema(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var hasher = std.hash.Wyhash.init(0);
        hashSchema(&hasher, T, 0);
        break :blk hasher.final();
    };
}

fn hashSchema(comptime hasher: *std.hash.Wyhash, comptime T: type, comptime depth: u32) void {
    if (depth > 32) @compileError("wire: " ++ @typeName(T) ++ " nests too deeply for a schema");
    hasher.update(@tagName(@typeInfo(T)));
    switch (@typeInfo(T)) {
        .int, .float => hasher.update(@typeName(T)),
        .@"enum" => |info| {
            hashSchema(hasher, info.tag_type, depth + 1);
            for (info.field_names, info.field_values) |name, field_value|
                hasher.update(std.fmt.comptimePrint("{s}={d};", .{ name, field_value }));
        },
        .optional => |info| hashSchema(hasher, info.child, depth + 1),
        .array => |info| {
            hasher.update(std.fmt.comptimePrint("{d}", .{info.len}));
            hashSchema(hasher, info.child, depth + 1);
        },
        .vector => |info| {
            hasher.update(std.fmt.comptimePrint("{d}", .{info.len}));
            hashSchema(hasher, info.child, depth + 1);
        },
        .@"struct" => |info| {
            if (info.backing_integer) |Backing| hashSchema(hasher, Backing, depth + 1);
            for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (attrs.@"comptime") continue;
                hasher.update(name);
                hashSchema(hasher, Field, depth + 1);
            }
        },
        .@"union" => |info| for (info.field_names, info.field_types) |name, Field| {
            hasher.update(name);
            hashSchema(hasher, Field, depth + 1);
        },
        .pointer => |info| {
            hasher.update(@tagName(info.size));
            hashSchema(hasher, info.child, depth + 1);
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
                const bits: Backing = @bitCast(pointer.*);
                try self.int(Wide(Backing), bits);
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

pub const Reader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize = 0,

    const Self = @This();

    pub fn finish(self: *const Self) Error!void {
        if (!self.done())
            return error.InvalidWire;
    }

    pub fn done(self: *const Self) bool {
        return self.offset == self.data.len;
    }

    fn raw(self: *Self, count: usize) Error![]const u8 {
        if (count > self.data.len - self.offset)
            return error.InvalidWire;

        defer self.offset += count;
        return self.data[self.offset..][0..count];
    }

    fn int(self: *Self, comptime I: type) Error!I {
        const size = @divExact(@bitSizeOf(I), 8);
        return std.mem.readInt(I, (try self.raw(size))[0..size], .little);
    }

    pub fn value(self: *Self, comptime T: type) Error!T {
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

                        if (info.sentinel_ptr != null)
                            return error.InvalidWire;
                        const alignment = info.attrs.@"align" orelse @alignOf(info.child);
                        const borrowed = info.child == u8 and info.attrs.@"const" and info.sentinel_ptr == null and alignment == 1;
                        if (borrowed)
                            return self.raw(count);

                        const result = try self.allocator.alignedAlloc(info.child, .fromByteUnits(alignment), count);
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

test "schemas change with the encoding" {
    const A = struct { x: u32, y: []const u8 };
    const B = struct { x: u32, y: []const u8 };
    const Reordered = struct { y: []const u8, x: u32 };
    const Wider = struct { x: u64, y: []const u8 };
    try std.testing.expectEqual(schema(A), schema(B));
    try std.testing.expect(schema(A) != schema(Reordered));
    try std.testing.expect(schema(A) != schema(Wider));
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
