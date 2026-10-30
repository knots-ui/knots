const std = @import("std");
const Reader = @import("Reader.zig");

pub const Error = error{InvalidFont};

pub const Directory = struct {
    file: Reader,
    records: Reader,
    table_count: u16,

    pub fn table(self: Directory, comptime name: *const [4]u8) ?Reader {
        return self.tableTag(Reader.tag(name));
    }

    pub fn tableTag(self: Directory, wanted: u32) ?Reader {
        for (0..self.table_count) |index| {
            const record = index * 16;
            const record_tag = self.records.u32At(record) catch return null;
            if (record_tag != wanted) continue;
            const offset = self.records.u32At(record + 8) catch return null;
            const length = self.records.u32At(record + 12) catch return null;
            return clampedTable(self.file, offset, length);
        }
        return null;
    }
};

fn clampedTable(file: Reader, offset: u32, length: u32) ?Reader {
    if (offset > file.bytes.len) return null;
    const available = file.bytes.len - offset;
    return file.subLen(offset, @min(length, available)) catch null;
}

pub fn faceCount(data: []const u8) u32 {
    const file = Reader.init(data);
    const version = file.u32At(0) catch return 0;
    if (version != Reader.tag("ttcf")) return 1;
    return file.u32At(8) catch 0;
}

pub fn open(data: []const u8, face_index: u32) Error!Directory {
    const file = Reader.init(data);
    const version = file.u32At(0) catch return error.InvalidFont;
    const face_offset = switch (version) {
        Reader.tag("ttcf") => try collectionFaceOffset(file, face_index),
        else => face: {
            if (face_index != 0) return error.InvalidFont;
            break :face 0;
        },
    };
    return openAt(file, face_offset);
}

fn collectionFaceOffset(file: Reader, face_index: u32) Error!u32 {
    const count = file.u32At(8) catch return error.InvalidFont;
    if (face_index >= count) return error.InvalidFont;
    return file.u32At(12 + @as(usize, face_index) * 4) catch error.InvalidFont;
}

fn openAt(file: Reader, offset: u32) Error!Directory {
    const header = file.sub(offset) catch return error.InvalidFont;
    const version = header.u32At(0) catch return error.InvalidFont;
    switch (version) {
        0x00010000, Reader.tag("OTTO"), Reader.tag("true") => {},
        else => return error.InvalidFont,
    }
    const table_count = header.u16At(4) catch return error.InvalidFont;
    const records = header.subLen(12, @as(usize, table_count) * 16) catch return error.InvalidFont;
    return .{ .file = file, .records = records, .table_count = table_count };
}

test "rejects truncated and unknown headers" {
    try std.testing.expectError(error.InvalidFont, open(&.{}, 0));
    try std.testing.expectError(error.InvalidFont, open(&.{ 0, 1, 0, 0, 0, 9 }, 0));
    try std.testing.expectError(error.InvalidFont, open("wOFF0000000000000000", 0));
    try std.testing.expectError(error.InvalidFont, open("ttcf\x00\x01\x00\x00\x00\x00\x00\x05", 0));
}

test "clamps tables that run past the end of the file" {
    var data: [12 + 16 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, data[4..6], 1, .big);
    @memcpy(data[12..16], "head");
    std.mem.writeInt(u32, data[20..24], 28, .big);
    std.mem.writeInt(u32, data[24..28], 100, .big);
    const directory = try open(&data, 0);
    const head = directory.table("head").?;
    try std.testing.expectEqual(@as(usize, 4), head.bytes.len);
    try std.testing.expect(directory.table("cmap") == null);
}
