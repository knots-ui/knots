//! COLR version 0 layers with CPAL palette 0. Later COLR versions keep their v0 records.

const std = @import("std");
const Reader = @import("Reader.zig");

base_glyphs: Reader,
base_count: u16,
layer_records: Reader,
layer_count: u16,
colors: Reader,
palette_size: u16,

const Colr = @This();

pub const empty: Colr = .{
    .base_glyphs = Reader.init(&.{}),
    .base_count = 0,
    .layer_records = Reader.init(&.{}),
    .layer_count = 0,
    .colors = Reader.init(&.{}),
    .palette_size = 0,
};

pub const foreground = 0xFFFF;

pub const Layer = struct {
    glyph: u16,
    palette_index: u16,
};

pub const Range = struct { start: u16 = 0, count: u16 = 0 };

pub fn compile(colr: ?Reader, cpal: ?Reader) Colr {
    var result = empty;
    const table = colr orelse return empty;
    result.base_count = table.u16At(2) catch return empty;
    const base_offset = table.u32At(4) catch return empty;
    const layer_offset = table.u32At(8) catch return empty;
    result.layer_count = table.u16At(12) catch return empty;
    result.base_glyphs = table.subLen(base_offset, @as(usize, result.base_count) * 6) catch return empty;
    result.layer_records = table.subLen(layer_offset, @as(usize, result.layer_count) * 4) catch return empty;
    const palette = cpal orelse return result;
    const palette_size = palette.u16At(2) catch return result;
    const palette_count = palette.u16At(4) catch return result;
    const record_count = palette.u16At(6) catch return result;
    const records_offset = palette.u32At(8) catch return result;
    if (palette_count == 0) return result;
    const first = palette.u16At(12) catch return result;
    if (@as(usize, first) + palette_size > record_count) return result;
    result.colors = palette.subLen(records_offset + @as(usize, first) * 4, @as(usize, palette_size) * 4) catch return result;
    result.palette_size = palette_size;
    return result;
}

/// Layer records of `glyph`, bottom first. Empty when the glyph has no color layers.
pub fn layers(self: *const Colr, glyph: u32) Range {
    var low: usize = 0;
    var high: usize = self.base_count;
    while (low < high) {
        const mid = (low + high) / 2;
        const record = mid * 6;
        const id = self.base_glyphs.u16Unchecked(record);
        if (glyph < id) {
            high = mid;
        } else if (glyph > id) {
            low = mid + 1;
        } else {
            const start = self.base_glyphs.u16Unchecked(record + 2);
            const count = self.base_glyphs.u16Unchecked(record + 4);
            if (@as(usize, start) + count > self.layer_count) return .{};
            return .{ .start = start, .count = count };
        }
    }
    return .{};
}

pub fn layer(self: *const Colr, index: u32) Layer {
    return .{
        .glyph = self.layer_records.u16Unchecked(index * 4),
        .palette_index = self.layer_records.u16Unchecked(index * 4 + 2),
    };
}

/// Linear RGBA of a palette entry, or null for the text color.
pub fn color(self: *const Colr, palette_index: u16) ?[4]f32 {
    if (palette_index == foreground or palette_index >= self.palette_size) return null;
    const bgra = self.colors.bytes[@as(usize, palette_index) * 4 ..][0..4];
    return .{ srgbToLinear(bgra[2]), srgbToLinear(bgra[1]), srgbToLinear(bgra[0]), @as(f32, @floatFromInt(bgra[3])) / 255 };
}

fn srgbToLinear(value: u8) f32 {
    const c = @as(f32, @floatFromInt(value)) / 255;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

test "finds layers and palette colors" {
    const colr = [_]u8{
        0, 0, 0, 1, 0, 0, 0, 14, 0, 0, 0, 20, 0, 2, // header
        0, 5, 0, 0, 0, 2, // glyph 5 -> layers 0..2
        0, 7, 0, 0, 0, 9, 0, 1, 0xFF, 0xFF, // layers
    };
    const cpal = [_]u8{
        0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 14, 0, 0, // header
        0, 0, 255, 255, // red, BGRA
    };
    const table = compile(Reader.init(&colr), Reader.init(&cpal));
    const range = table.layers(5);
    try std.testing.expectEqual(@as(u16, 2), range.count);
    try std.testing.expectEqual(@as(u16, 0), table.layers(6).count);
    try std.testing.expectEqual(@as(u16, 9), table.layer(1).glyph);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, table.color(table.layer(0).palette_index).?);
    try std.testing.expectEqual(@as(?[4]f32, null), table.color(table.layer(1).palette_index));
}
