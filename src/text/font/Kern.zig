//! Legacy `kern` table, format 0 subtables only.

const std = @import("std");
const Reader = @import("Reader.zig");

present: bool,
has_state_machine: bool,
has_cross_stream: bool,
subtables: []const Subtable,

const Kern = @This();

pub const Subtable = struct {
    pairs: Reader,
    count: u16,
    cross_stream: bool,
    override: bool,
};

pub const empty: Kern = .{ .present = false, .has_state_machine = false, .has_cross_stream = false, .subtables = &.{} };

pub fn compile(arena: std.mem.Allocator, table: ?Reader) !Kern {
    const reader = table orelse return empty;
    const version = reader.u16At(0) catch return empty;
    return switch (version) {
        0 => compileOt(arena, reader),
        1 => compileApple(arena, reader),
        else => empty,
    };
}

fn compileOt(arena: std.mem.Allocator, reader: Reader) !Kern {
    var result: Kern = .{ .present = true, .has_state_machine = false, .has_cross_stream = false, .subtables = &.{} };
    const count = reader.u16At(2) catch return empty;
    var subtables: std.ArrayList(Subtable) = .empty;
    var offset: usize = 4;
    for (0..count) |_| {
        const length = reader.u16At(offset + 2) catch break;
        const format = reader.u8At(offset + 4) catch break;
        const flags = reader.u8At(offset + 5) catch break;
        const subtable = reader.sub(offset) catch break;
        if (format == 1) result.has_state_machine = true;
        if (flags & 0x04 != 0) result.has_cross_stream = true;
        if (format == 0 and flags & 0x01 != 0) {
            if (pairList(subtable, 6)) |pairs| try subtables.append(arena, .{
                .pairs = pairs.reader,
                .count = pairs.count,
                .cross_stream = flags & 0x04 != 0,
                .override = flags & 0x08 != 0,
            });
        }
        if (length < 6) break;
        offset += length;
    }
    result.subtables = subtables.items;
    return result;
}

fn compileApple(arena: std.mem.Allocator, reader: Reader) !Kern {
    const version = reader.u32At(0) catch return empty;
    if (version != 0x00010000) return empty;
    var result: Kern = .{ .present = true, .has_state_machine = false, .has_cross_stream = false, .subtables = &.{} };
    const count = reader.u32At(4) catch return empty;
    var subtables: std.ArrayList(Subtable) = .empty;
    var offset: usize = 8;
    for (0..count) |_| {
        const length = reader.u32At(offset) catch break;
        const flags = reader.u8At(offset + 4) catch break;
        const format = reader.u8At(offset + 5) catch break;
        const subtable = reader.sub(offset) catch break;
        if (format == 1) result.has_state_machine = true;
        if (flags & 0x40 != 0) result.has_cross_stream = true;
        if (format == 0 and flags & 0x80 == 0 and flags & 0x20 == 0) {
            if (pairList(subtable, 8)) |pairs| try subtables.append(arena, .{
                .pairs = pairs.reader,
                .count = pairs.count,
                .cross_stream = flags & 0x40 != 0,
                .override = false,
            });
        }
        if (length < 8) break;
        offset += length;
    }
    result.subtables = subtables.items;
    return result;
}

const Pairs = struct { reader: Reader, count: u16 };

fn pairList(subtable: Reader, header: usize) ?Pairs {
    const count = subtable.u16At(header) catch return null;
    const pairs = subtable.subLen(header + 8, @as(usize, count) * 6) catch return null;
    return .{ .reader = pairs, .count = count };
}

pub fn value(subtable: Subtable, left: u32, right: u32) i16 {
    if (left > 0xFFFF or right > 0xFFFF) return 0;
    const key = (left << 16) | right;
    var low: i32 = 0;
    var high: i32 = @as(i32, subtable.count) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const pair = subtable.pairs.u32At(mid * 6) catch return 0;
        if (key < pair) {
            high = @as(i32, @intCast(mid)) - 1;
        } else if (key > pair) {
            low = @as(i32, @intCast(mid)) + 1;
        } else {
            return subtable.pairs.i16At(mid * 6 + 4) catch 0;
        }
    }
    return 0;
}

pub fn hasPairWith(self: *const Kern, glyph: u32) bool {
    for (self.subtables) |subtable| {
        for (0..subtable.count) |index| {
            const pair = subtable.pairs.u32At(index * 6) catch break;
            const kerning = subtable.pairs.i16At(index * 6 + 4) catch break;
            if (kerning == 0) continue;
            if (pair >> 16 == glyph or pair & 0xFFFF == glyph) return true;
        }
    }
    return false;
}
