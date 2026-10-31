const std = @import("std");
const Reader = @import("Reader.zig");
const sfnt = @import("sfnt.zig");
const Cmap = @import("Cmap.zig");
const Gdef = @import("Gdef.zig");
const Colr = @import("Colr.zig");
const Kern = @import("Kern.zig");
const Layout = @import("Layout.zig");
const Partition = @import("Partition.zig");
const Outline = @import("Outline.zig");

arena_state: std.heap.ArenaAllocator,
data: []const u8,
directory: sfnt.Directory,
units_per_em: u16,
glyph_count: u16,
advances: []const u16,
metrics: Metrics,
cmap: Cmap,
gdef: Gdef,
gsub: Layout,
gpos: Layout,
kern: Kern,
colr: Colr,
outline: Outline,
partition: Partition,
space_glyph: u16,

const FontProgram = @This();

pub const Metrics = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    underline_position: i16,
    underline_thickness: i16,
    strikeout_position: i16,
    strikeout_thickness: i16,
};

pub const Error = error{ InvalidFont, OutOfMemory };

pub fn init(gpa: std.mem.Allocator, data: []const u8, face_index: u32) Error!FontProgram {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const directory = try sfnt.open(data, face_index);
    const head = directory.table("head") orelse return error.InvalidFont;
    const maxp = directory.table("maxp") orelse return error.InvalidFont;
    const hhea = directory.table("hhea") orelse return error.InvalidFont;
    const hmtx = directory.table("hmtx") orelse return error.InvalidFont;

    const units_per_em = try readUnitsPerEm(head);
    const glyph_count = maxp.u16At(4) catch return error.InvalidFont;
    const advances = try compileAdvances(arena, hhea, hmtx, glyph_count);
    const cmap = try Cmap.compile(arena, directory.table("cmap"));
    var builder: Partition.Builder = .{ .arena = arena };
    const gdef = try Gdef.compile(arena, directory.table("GDEF"), glyph_count, &builder);
    const gsub = try Layout.compile(arena, directory.table("GSUB"), .gsub, &builder);
    const gpos = try Layout.compile(arena, directory.table("GPOS"), .gpos, &builder);
    const kern = try Kern.compile(arena, directory.table("kern"));
    const space_glyph = cmap.glyph(' ');
    _ = try builder.glyphId(space_glyph);
    const partition = try builder.finish(gpa, glyph_count);

    return .{
        .arena_state = arena_state,
        .data = data,
        .directory = directory,
        .units_per_em = units_per_em,
        .glyph_count = glyph_count,
        .advances = advances,
        .metrics = try readMetrics(directory, hhea, units_per_em),
        .cmap = cmap,
        .gdef = gdef,
        .gsub = gsub,
        .gpos = gpos,
        .kern = kern,
        .colr = Colr.compile(directory.table("COLR"), directory.table("CPAL")),
        .outline = Outline.compile(directory, glyph_count),
        .partition = partition,
        .space_glyph = space_glyph,
    };
}

/// Feature tags the GSUB and GPOS tables define, sorted and without duplicates.
pub fn featureTags(self: *const FontProgram, gpa: std.mem.Allocator) ![]u32 {
    var tags: std.ArrayList(u32) = .empty;
    errdefer tags.deinit(gpa);
    for ([_]*const Layout{ &self.gsub, &self.gpos }) |layout| {
        for (0..layout.featureCount()) |index| try tags.append(gpa, layout.featureTag(@intCast(index)));
    }
    std.mem.sort(u32, tags.items, {}, std.sort.asc(u32));
    var unique: usize = 0;
    for (tags.items) |tag| {
        if (unique > 0 and tags.items[unique - 1] == tag) continue;
        tags.items[unique] = tag;
        unique += 1;
    }
    tags.shrinkRetainingCapacity(unique);
    return tags.toOwnedSlice(gpa);
}

pub fn deinit(self: *FontProgram) void {
    self.arena_state.deinit();
}

pub fn advance(self: *const FontProgram, glyph_id: u32) u16 {
    if (glyph_id >= self.advances.len) return 0;
    return self.advances[glyph_id];
}

pub fn memoryBytes(self: *const FontProgram) usize {
    return self.arena_state.queryCapacity();
}

fn readUnitsPerEm(head: Reader) Error!u16 {
    const major = head.u16At(0) catch return error.InvalidFont;
    const magic = head.u32At(12) catch return error.InvalidFont;
    if (major != 1 or magic != 0x5F0F3CF5) return error.InvalidFont;
    const units_per_em = head.u16At(18) catch return error.InvalidFont;
    if (units_per_em < 16 or units_per_em > 16384) return error.InvalidFont;
    return units_per_em;
}

fn compileAdvances(arena: std.mem.Allocator, hhea: Reader, hmtx: Reader, glyph_count: u16) Error![]u16 {
    const declared = hhea.u16At(34) catch return error.InvalidFont;
    const metric_count: usize = @min(declared, hmtx.bytes.len / 4);
    if (metric_count == 0 and glyph_count > 0) return error.InvalidFont;
    const advances = try arena.alloc(u16, glyph_count);
    for (advances, 0..) |*slot, glyph_id| {
        const metric = @min(glyph_id, metric_count - 1);
        slot.* = hmtx.u16At(metric * 4) catch unreachable;
    }
    return advances;
}

fn readMetrics(directory: sfnt.Directory, hhea: Reader, units_per_em: u16) Error!Metrics {
    const os2 = directory.table("OS/2");
    const vertical = readVertical(os2, hhea) orelse return error.InvalidFont;
    const post = directory.table("post");
    const upem: i32 = units_per_em;
    return .{
        .ascender = vertical.ascender,
        .descender = vertical.descender,
        .line_gap = vertical.line_gap,
        .underline_position = readOr(post, 8, @intCast(@divTrunc(-upem, 10))),
        .underline_thickness = readOr(post, 10, @intCast(@divTrunc(upem, 14))),
        .strikeout_position = readOr(os2, 28, @intCast(@divTrunc(upem * 2, 7))),
        .strikeout_thickness = readOr(os2, 26, @intCast(@divTrunc(upem, 14))),
    };
}

const Vertical = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
};

fn readVertical(os2: ?Reader, hhea: Reader) ?Vertical {
    if (os2) |table| {
        if (usesTypoMetrics(table)) {
            if (readVerticalAt(table, 68)) |vertical| return vertical;
        }
    }
    return readVerticalAt(hhea, 4);
}

fn usesTypoMetrics(os2: Reader) bool {
    const selection = os2.u16At(62) catch return false;
    return selection & (1 << 7) != 0;
}

fn readVerticalAt(table: Reader, offset: usize) ?Vertical {
    const ascender = table.i16At(offset) catch return null;
    const descender = table.i16At(offset + 2) catch return null;
    const line_gap = table.i16At(offset + 4) catch return null;
    return .{
        .ascender = absI16(ascender),
        .descender = -absI16(descender),
        .line_gap = line_gap,
    };
}

fn absI16(value: i16) i16 {
    if (value == std.math.minInt(i16)) return std.math.maxInt(i16);
    return @intCast(@abs(value));
}

fn readOr(table: ?Reader, offset: usize, fallback: i16) i16 {
    const reader = table orelse return fallback;
    return reader.i16At(offset) catch fallback;
}

test "rejects fonts missing required tables" {
    try std.testing.expectError(error.InvalidFont, init(std.testing.allocator, &.{}, 0));
}

test "compiles the bundled font" {
    var program = try init(std.testing.allocator, @embedFile("test_font"), 0);
    defer program.deinit();
    try std.testing.expect(program.cmap.glyph('A') != 0);
    try std.testing.expect(program.advance(program.cmap.glyph('A')) > 0);
    try std.testing.expectEqual(@as(i16, 1900), program.metrics.ascender);
}

test "truncated fonts never panic" {
    const data = @embedFile("test_font");
    var len: usize = 0;
    while (len < data.len) : (len += 97) {
        var program = init(std.testing.allocator, data[0..len], 0) catch continue;
        program.deinit();
    }
}

test "mutated fonts never panic" {
    const original = @embedFile("test_font");
    const data = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(data);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const directory = try sfnt.open(original, 0);
    const targets = [_]?Reader{ directory.table("cmap"), directory.table("hhea"), directory.table("maxp"), directory.table("head"), Reader.init(original[0..256]) };
    for (0..400) |_| {
        @memcpy(data, original);
        const target = targets[random.uintLessThan(usize, targets.len)].?;
        const base = @intFromPtr(target.bytes.ptr) - @intFromPtr(original.ptr);
        for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
            data[base + random.uintLessThan(usize, @min(target.bytes.len, 4096))] = random.int(u8);
        }
        var program = init(std.testing.allocator, data, 0) catch continue;
        _ = program.cmap.glyph(random.int(u21));
        program.deinit();
    }
}
