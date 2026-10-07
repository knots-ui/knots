const std = @import("std");

pub const stack_pointer_export = "__stack_pointer";

pub const Prepared = struct {
    bytes: []u8,
    shared: bool,
    memory_minimum: u64 = 0,
    memory_maximum: u64 = 0,
};

const section_import = 2;
const section_global = 6;
const section_export = 7;
const section_custom = 0;
const kind_global = 3;
const kind_memory = 2;

pub fn prepare(gpa: std.mem.Allocator, bytes: []const u8) !Prepared {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return error.NotWasm;
    var stack_pointer: u32 = 0;
    var memory_minimum: ?u64 = null;
    var memory_maximum: u64 = 0;
    var shared = false;
    var export_section: ?[]const u8 = null;
    var export_offset: usize = 0;

    var reader: Reader = .{ .bytes = bytes, .offset = 8 };
    while (reader.offset < bytes.len) {
        const start = reader.offset;
        const id = try reader.byte();
        const size = try reader.uleb();
        const body = try reader.take(size);
        var section: Reader = .{ .bytes = body, .offset = 0 };
        switch (id) {
            section_import => {
                const count = try section.uleb();
                for (0..count) |_| {
                    _ = try section.name();
                    _ = try section.name();
                    switch (try section.byte()) {
                        0 => _ = try section.uleb(),
                        1 => {
                            _ = try section.byte();
                            const flags = try section.byte();
                            _ = try section.uleb();
                            if (flags & 1 != 0) _ = try section.uleb();
                        },
                        kind_memory => {
                            const flags = try section.byte();
                            shared = flags & 2 != 0;
                            memory_minimum = try section.uleb();
                            if (flags & 1 != 0) memory_maximum = try section.uleb();
                        },
                        kind_global => {
                            _ = try section.byte();
                            _ = try section.byte();
                        },
                        else => return error.UnsupportedImport,
                    }
                }
            },
            section_export => {
                export_section = body;
                export_offset = start;
            },
            section_custom => if (std.mem.eql(u8, try section.name(), "name")) {
                if (try globalIndex(&section, stack_pointer_export)) |index| stack_pointer = index;
            },
            else => {},
        }
    }

    if (!shared) return .{ .bytes = try gpa.dupe(u8, bytes), .shared = false };
    const exports = export_section orelse return error.NoExports;
    const minimum = memory_minimum orelse return error.MemoryNotImported;

    var section: Reader = .{ .bytes = exports, .offset = 0 };
    const count = try section.uleb();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try writeUleb(gpa, &body, count + 1);
    try body.appendSlice(gpa, exports[section.offset..]);
    try writeUleb(gpa, &body, stack_pointer_export.len);
    try body.appendSlice(gpa, stack_pointer_export);
    try body.append(gpa, kind_global);
    try writeUleb(gpa, &body, stack_pointer);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, bytes[0..export_offset]);
    try result.append(gpa, section_export);
    try writeUleb(gpa, &result, body.items.len);
    try result.appendSlice(gpa, body.items);
    const old_end = export_offset + 1 + ulebLength(exports.len) + exports.len;
    try result.appendSlice(gpa, bytes[old_end..]);
    return .{ .bytes = try result.toOwnedSlice(gpa), .shared = true, .memory_minimum = minimum, .memory_maximum = memory_maximum };
}

fn globalIndex(section: *Reader, wanted: []const u8) !?u32 {
    while (section.offset < section.bytes.len) {
        const id = try section.byte();
        const size = try section.uleb();
        const body = try section.take(size);
        if (id != 7) continue;
        var names: Reader = .{ .bytes = body, .offset = 0 };
        const count = try names.uleb();
        for (0..count) |_| {
            const index = try names.uleb();
            if (std.mem.eql(u8, try names.name(), wanted)) return @intCast(index);
        }
    }
    return null;
}

const Reader = struct {
    bytes: []const u8,
    offset: usize,

    fn byte(self: *Reader) !u8 {
        if (self.offset >= self.bytes.len) return error.TruncatedWasm;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn uleb(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const value = try self.byte();
            result |= @as(u64, value & 0x7f) << shift;
            if (value & 0x80 == 0) return result;
            if (shift >= 56) return error.InvalidWasm;
            shift += 7;
        }
    }

    fn take(self: *Reader, length: u64) ![]const u8 {
        if (length > self.bytes.len - self.offset) return error.TruncatedWasm;
        defer self.offset += @intCast(length);
        return self.bytes[self.offset..][0..@intCast(length)];
    }

    fn name(self: *Reader) ![]const u8 {
        return self.take(try self.uleb());
    }
};

fn writeUleb(gpa: std.mem.Allocator, list: *std.ArrayList(u8), value: u64) !void {
    var rest = value;
    while (true) {
        const low: u8 = @intCast(rest & 0x7f);
        rest >>= 7;
        if (rest == 0) return list.append(gpa, low);
        try list.append(gpa, low | 0x80);
    }
}

fn ulebLength(value: u64) usize {
    var length: usize = 1;
    var rest = value >> 7;
    while (rest != 0) : (rest >>= 7) length += 1;
    return length;
}

test "the stack pointer is exported, and the rest of the module is unchanged" {
    // (module (import "env" "memory" (memory 1 2 shared))
    //   (global (mut i32) (i32.const 1024)) (func (export "f")))
    const original = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type
        0x02, 0x10, 0x01, 0x03, 'e', 'n', 'v', 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x03, 0x01, 0x02, // import
        0x03, 0x02, 0x01, 0x00, // function
        0x06, 0x07, 0x01, 0x7f, 0x01, 0x41, 0x80, 0x08, 0x0b, // global
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code
    };
    const prepared = try prepare(std.testing.allocator, &original);
    defer std.testing.allocator.free(prepared.bytes);
    try std.testing.expect(prepared.shared);
    try std.testing.expectEqual(@as(u64, 1), prepared.memory_minimum);
    try std.testing.expectEqual(@as(u64, 2), prepared.memory_maximum);
    const exports = [_]u8{ 0x07, 0x17, 0x02, 0x01, 'f', 0x00, 0x00, 0x0f } ++ stack_pointer_export.* ++ [_]u8{ 0x03, 0x00 };
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, &exports) != null);
    try std.testing.expectEqualSlices(u8, original[original.len - 6 ..], prepared.bytes[prepared.bytes.len - 6 ..]);
}
