const std = @import("std");
const Reader = @import("Reader.zig");

pub const not_covered = std.math.maxInt(u32);

pub fn validate(table: Reader) bool {
    const format = table.u16At(0) catch return false;
    const count = table.u16At(2) catch return false;
    return switch (format) {
        1 => table.has(4, @as(usize, count) * 2),
        2 => table.has(4, @as(usize, count) * 6),
        else => false,
    };
}

/// Coverage index of `glyph`, found by binary search like HarfBuzz.
pub fn index(table: Reader, glyph: u32) u32 {
    const format = table.u16At(0) catch return not_covered;
    const count = table.u16At(2) catch return not_covered;
    switch (format) {
        1 => {
            var low: i32 = 0;
            var high: i32 = @as(i32, count) - 1;
            while (low <= high) {
                const mid: u32 = @intCast(@divTrunc(low + high, 2));
                const value: u32 = table.u16At(4 + mid * 2) catch return not_covered;
                if (glyph < value) {
                    high = @as(i32, @intCast(mid)) - 1;
                } else if (glyph > value) {
                    low = @as(i32, @intCast(mid)) + 1;
                } else {
                    return mid;
                }
            }
            return not_covered;
        },
        2 => {
            var low: i32 = 0;
            var high: i32 = @as(i32, count) - 1;
            while (low <= high) {
                const mid: u32 = @intCast(@divTrunc(low + high, 2));
                const record = 4 + mid * 6;
                const first: u32 = table.u16At(record) catch return not_covered;
                const last: u32 = table.u16At(record + 2) catch return not_covered;
                if (glyph < first) {
                    high = @as(i32, @intCast(mid)) - 1;
                } else if (glyph > last) {
                    low = @as(i32, @intCast(mid)) + 1;
                } else {
                    const start: u32 = table.u16At(record + 4) catch return not_covered;
                    return start + (glyph - first);
                }
            }
            return not_covered;
        },
        else => return not_covered,
    }
}

/// `index` for a coverage that passed `validate`.
pub fn indexValidated(table: Reader, glyph: u32) u32 {
    const format = table.u16Unchecked(0);
    const count = table.u16Unchecked(2);
    var low: i32 = 0;
    var high: i32 = @as(i32, count) - 1;
    switch (format) {
        1 => while (low <= high) {
            const mid: u32 = @intCast(@divTrunc(low + high, 2));
            const value: u32 = table.u16Unchecked(4 + mid * 2);
            if (glyph < value) {
                high = @as(i32, @intCast(mid)) - 1;
            } else if (glyph > value) {
                low = @as(i32, @intCast(mid)) + 1;
            } else {
                return mid;
            }
        },
        else => while (low <= high) {
            const mid: u32 = @intCast(@divTrunc(low + high, 2));
            const record = 4 + mid * 6;
            const first: u32 = table.u16Unchecked(record);
            const last: u32 = table.u16Unchecked(record + 2);
            if (glyph < first) {
                high = @as(i32, @intCast(mid)) - 1;
            } else if (glyph > last) {
                low = @as(i32, @intCast(mid)) + 1;
            } else {
                return table.u16Unchecked(record + 4) + (glyph - first);
            }
        },
    }
    return not_covered;
}

pub fn contains(table: Reader, glyph: u32) bool {
    return index(table, glyph) != not_covered;
}

/// Calls `visit(context, glyph)` for every covered glyph. Glyphs can repeat in malformed tables.
pub fn forEach(table: Reader, context: anytype, comptime visit: fn (@TypeOf(context), u32) void) void {
    const format = table.u16At(0) catch return;
    const count = table.u16At(2) catch return;
    switch (format) {
        1 => for (0..count) |i| {
            const glyph = table.u16At(4 + i * 2) catch return;
            visit(context, glyph);
        },
        2 => for (0..count) |i| {
            const record = 4 + i * 6;
            const first: u32 = table.u16At(record) catch return;
            const last: u32 = table.u16At(record + 2) catch return;
            var glyph = first;
            while (glyph <= last) : (glyph += 1) visit(context, glyph);
        },
        else => {},
    }
}

test "binary search finds covered glyphs in both formats" {
    const format1 = [_]u8{ 0, 1, 0, 3, 0, 5, 0, 9, 0, 20 };
    try std.testing.expectEqual(@as(u32, 1), index(Reader.init(&format1), 9));
    try std.testing.expectEqual(not_covered, index(Reader.init(&format1), 10));
    const format2 = [_]u8{ 0, 2, 0, 1, 0, 10, 0, 19, 0, 4 };
    try std.testing.expectEqual(@as(u32, 7), index(Reader.init(&format2), 13));
    try std.testing.expectEqual(not_covered, index(Reader.init(&format2), 20));
    try std.testing.expect(!validate(Reader.init(format2[0..8])));
}
