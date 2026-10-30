const std = @import("std");
const Reader = @import("Reader.zig");

pub fn forEach(table: Reader, glyph_count: u32, context: anytype, comptime visit: fn (@TypeOf(context), u32, u16) void) Reader.Error!void {
    switch (try table.u16At(0)) {
        1 => {
            const start: u32 = try table.u16At(2);
            const count = try table.u16At(4);
            if (!table.has(6, @as(usize, count) * 2)) return error.OutOfBounds;
            for (0..count) |index| {
                const glyph = start + @as(u32, @intCast(index));
                if (glyph >= glyph_count) break;
                const class = try table.u16At(6 + index * 2);
                if (class != 0) visit(context, glyph, class);
            }
        },
        2 => {
            const count = try table.u16At(2);
            if (!table.has(4, @as(usize, count) * 6)) return error.OutOfBounds;
            for (0..count) |index| {
                const record = 4 + index * 6;
                const first: u32 = try table.u16At(record);
                const last: u32 = @min(try table.u16At(record + 2), glyph_count -| 1);
                const class = try table.u16At(record + 4);
                if (class == 0 or first > last or first >= glyph_count) continue;
                var glyph = first;
                while (glyph <= last) : (glyph += 1) visit(context, glyph, class);
            }
        },
        else => return error.OutOfBounds,
    }
}

pub fn compile(arena: std.mem.Allocator, table: Reader, glyph_count: u32) error{ OutOfMemory, OutOfBounds }![]u16 {
    const classes = try arena.alloc(u16, glyph_count);
    @memset(classes, 0);
    try forEach(table, glyph_count, classes, struct {
        fn visit(target: []u16, glyph: u32, class: u16) void {
            target[glyph] = class;
        }
    }.visit);
    return classes;
}

pub fn validate(table: Reader) bool {
    const format = table.u16At(0) catch return false;
    return switch (format) {
        1 => blk: {
            const count = table.u16At(4) catch return false;
            break :blk table.has(6, @as(usize, count) * 2);
        },
        2 => blk: {
            const count = table.u16At(2) catch return false;
            break :blk table.has(4, @as(usize, count) * 6);
        },
        else => false,
    };
}

pub fn value(table: Reader, glyph: u32) u16 {
    const format = table.u16At(0) catch return 0;
    switch (format) {
        1 => {
            const start: u32 = table.u16At(2) catch return 0;
            const count: u32 = table.u16At(4) catch return 0;
            if (glyph < start or glyph - start >= count) return 0;
            return table.u16At(6 + (glyph - start) * 2) catch 0;
        },
        2 => {
            const count = table.u16At(2) catch return 0;
            var low: i32 = 0;
            var high: i32 = @as(i32, count) - 1;
            while (low <= high) {
                const mid: u32 = @intCast(@divTrunc(low + high, 2));
                const record = 4 + mid * 6;
                const first: u32 = table.u16At(record) catch return 0;
                const last: u32 = table.u16At(record + 2) catch return 0;
                if (glyph < first) {
                    high = @as(i32, @intCast(mid)) - 1;
                } else if (glyph > last) {
                    low = @as(i32, @intCast(mid)) + 1;
                } else {
                    return table.u16At(record + 4) catch 0;
                }
            }
            return 0;
        },
        else => return 0,
    }
}
