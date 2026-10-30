const std = @import("std");
const Reader = @import("Reader.zig");

ascii: [128]u16,
directory: []const u16,
pages: []const [page_size]u16,
variations: ?Reader = null,

const Cmap = @This();

pub const page_size = 256;
pub const codepoint_max = 0x10FFFF;
const directory_len = (codepoint_max + 1) / page_size;

comptime {
    std.debug.assert(directory_len * page_size == codepoint_max + 1);
    std.debug.assert(directory_len <= std.math.maxInt(u16));
}

pub fn glyph(self: *const Cmap, codepoint: u32) u16 {
    if (codepoint < self.ascii.len) return self.ascii[codepoint];
    if (codepoint > codepoint_max) return 0;
    const page = self.directory[codepoint / page_size];
    return self.pages[page][codepoint % page_size];
}

pub fn has(self: *const Cmap, codepoint: u32) bool {
    return self.glyph(codepoint) != 0;
}

/// Glyph for `codepoint` followed by `selector`, from the format 14 subtable.
pub fn variationGlyph(self: *const Cmap, codepoint: u32, selector: u32) ?u16 {
    const table = self.variations orelse return null;
    const count = table.u32At(6) catch return null;
    var low: i64 = 0;
    var high: i64 = @as(i64, count) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const record = 10 + mid * 11;
        const value: u32 = table.u24At(record) catch return null;
        if (selector < value) {
            high = @as(i64, @intCast(mid)) - 1;
        } else if (selector > value) {
            low = @as(i64, @intCast(mid)) + 1;
        } else {
            return variantOf(self, table, record, codepoint);
        }
    }
    return null;
}

fn variantOf(self: *const Cmap, table: Reader, record: usize, codepoint: u32) ?u16 {
    const default_offset = table.u32At(record + 3) catch return null;
    if (default_offset != 0) {
        if (inDefaultRanges(table.sub(default_offset) catch return null, codepoint)) {
            const nominal = self.glyph(codepoint);
            if (nominal == 0) return null;
            return nominal;
        }
    }
    const mapped_offset = table.u32At(record + 7) catch return null;
    if (mapped_offset == 0) return null;
    const mappings = table.sub(mapped_offset) catch return null;
    const count = mappings.u32At(0) catch return null;
    var low: i64 = 0;
    var high: i64 = @as(i64, count) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const value: u32 = mappings.u24At(4 + mid * 5) catch return null;
        if (codepoint < value) {
            high = @as(i64, @intCast(mid)) - 1;
        } else if (codepoint > value) {
            low = @as(i64, @intCast(mid)) + 1;
        } else {
            return mappings.u16At(4 + mid * 5 + 3) catch null;
        }
    }
    return null;
}

fn inDefaultRanges(ranges: Reader, codepoint: u32) bool {
    const count = ranges.u32At(0) catch return false;
    var low: i64 = 0;
    var high: i64 = @as(i64, count) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const start: u32 = ranges.u24At(4 + mid * 4) catch return false;
        const additional: u32 = ranges.u8At(4 + mid * 4 + 3) catch return false;
        if (codepoint < start) {
            high = @as(i64, @intCast(mid)) - 1;
        } else if (codepoint > start + additional) {
            low = @as(i64, @intCast(mid)) + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn compile(arena: std.mem.Allocator, cmap_table: ?Reader) !Cmap {
    var builder = try Builder.init(arena);
    if (cmap_table) |table| {
        if (bestSubtable(table)) |best| {
            builder.addSubtable(best.reader) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OutOfBounds => builder.reset(),
            };
            if (best.symbol) try builder.addSymbolAliases();
        }
    }
    var result = try builder.finish();
    if (cmap_table) |table| result.variations = variationSubtable(table);
    return result;
}

const Best = struct {
    reader: Reader,
    symbol: bool,
};

const preferred_encodings = [_][2]u16{
    .{ 3, 10 }, .{ 0, 6 }, .{ 0, 4 }, .{ 3, 1 }, .{ 0, 3 }, .{ 0, 2 }, .{ 0, 1 }, .{ 0, 0 },
};

fn bestSubtable(table: Reader) ?Best {
    if (findSubtable(table, 3, 0)) |reader| return .{ .reader = reader, .symbol = true };
    for (preferred_encodings) |encoding| {
        if (findSubtable(table, encoding[0], encoding[1])) |reader| {
            return .{ .reader = reader, .symbol = false };
        }
    }
    return null;
}

fn findSubtable(table: Reader, platform: u16, encoding: u16) ?Reader {
    const count = table.u16At(2) catch return null;
    for (0..count) |index| {
        const record = 4 + index * 8;
        const record_platform = table.u16At(record) catch return null;
        const record_encoding = table.u16At(record + 2) catch return null;
        if (record_platform != platform or record_encoding != encoding) continue;
        const offset = table.u32At(record + 4) catch return null;
        const subtable = table.sub(offset) catch return null;
        if (!isSupported(subtable)) return null;
        return subtable;
    }
    return null;
}

fn variationSubtable(table: Reader) ?Reader {
    const count = table.u16At(2) catch return null;
    for (0..count) |index| {
        const record = 4 + index * 8;
        const platform = table.u16At(record) catch return null;
        const encoding = table.u16At(record + 2) catch return null;
        if (platform != 0 or encoding != 5) continue;
        const subtable = table.sub(table.u32At(record + 4) catch return null) catch return null;
        const format = subtable.u16At(0) catch return null;
        if (format != 14) return null;
        return subtable;
    }
    return null;
}

fn isSupported(subtable: Reader) bool {
    const format = subtable.u16At(0) catch return false;
    return format == 4 or format == 12;
}

const Builder = struct {
    arena: std.mem.Allocator,
    directory: []u16,
    pages: std.ArrayList([page_size]u16),

    fn init(arena: std.mem.Allocator) !Builder {
        const directory = try arena.alloc(u16, directory_len);
        @memset(directory, 0);
        var pages: std.ArrayList([page_size]u16) = .empty;
        try pages.append(arena, @splat(0));
        return .{ .arena = arena, .directory = directory, .pages = pages };
    }

    fn reset(self: *Builder) void {
        @memset(self.directory, 0);
        self.pages.shrinkRetainingCapacity(1);
    }

    fn set(self: *Builder, codepoint: u32, glyph_id: u16) !void {
        std.debug.assert(codepoint <= codepoint_max);
        if (glyph_id == 0) return;
        const page_index = codepoint / page_size;
        if (self.directory[page_index] == 0) {
            self.directory[page_index] = @intCast(self.pages.items.len);
            try self.pages.append(self.arena, @splat(0));
        }
        self.pages.items[self.directory[page_index]][codepoint % page_size] = glyph_id;
    }

    fn get(self: *const Builder, codepoint: u32) u16 {
        return self.pages.items[self.directory[codepoint / page_size]][codepoint % page_size];
    }

    fn addSubtable(self: *Builder, subtable: Reader) !void {
        switch (try subtable.u16At(0)) {
            4 => try self.addFormat4(subtable),
            12 => try self.addFormat12(subtable),
            else => unreachable,
        }
    }

    fn addFormat4(self: *Builder, subtable: Reader) !void {
        const declared_len = try subtable.u16At(2);
        const len = @min(declared_len, subtable.bytes.len);
        const seg_count = (try subtable.u16At(6)) / 2;
        const ends = 14;
        const starts = ends + seg_count * 2 + 2;
        const deltas = starts + seg_count * 2;
        const range_offsets = deltas + seg_count * 2;
        const glyph_ids = range_offsets + seg_count * 2;
        if (glyph_ids > len) return error.OutOfBounds;
        const glyph_id_count = (len - glyph_ids) / 2;

        for (0..seg_count) |segment| {
            const end: u32 = try subtable.u16At(ends + segment * 2);
            const start: u32 = try subtable.u16At(starts + segment * 2);
            const delta = try subtable.u16At(deltas + segment * 2);
            const range_offset: u32 = try subtable.u16At(range_offsets + segment * 2);
            if (start > end) continue;
            var codepoint = start;
            while (codepoint <= end) : (codepoint += 1) {
                const glyph_id = try format4Glyph(.{
                    .subtable = subtable,
                    .glyph_ids = glyph_ids,
                    .glyph_id_count = glyph_id_count,
                    .seg_count = seg_count,
                    .segment = segment,
                    .start = start,
                    .delta = delta,
                    .range_offset = range_offset,
                }, codepoint);
                try self.set(codepoint, glyph_id);
            }
        }
    }

    const Format4Segment = struct {
        subtable: Reader,
        glyph_ids: usize,
        glyph_id_count: usize,
        seg_count: usize,
        segment: usize,
        start: u32,
        delta: u16,
        range_offset: u32,
    };

    fn format4Glyph(segment: Format4Segment, codepoint: u32) !u16 {
        if (segment.range_offset == 0) return @truncate(codepoint +% segment.delta);
        const index = segment.range_offset / 2 + (codepoint - segment.start) + segment.segment;
        if (index < segment.seg_count) return 0;
        const array_index = index - segment.seg_count;
        if (array_index >= segment.glyph_id_count) return 0;
        const raw = try segment.subtable.u16At(segment.glyph_ids + array_index * 2);
        if (raw == 0) return 0;
        return raw +% segment.delta;
    }

    fn addFormat12(self: *Builder, subtable: Reader) !void {
        const group_count = try subtable.u32At(12);
        if (!subtable.has(16, @as(usize, group_count) * 12)) return error.OutOfBounds;
        for (0..group_count) |group| {
            const record = 16 + group * 12;
            const start = try subtable.u32At(record);
            const end = @min(try subtable.u32At(record + 4), codepoint_max);
            const start_glyph = try subtable.u32At(record + 8);
            if (start > end) continue;
            var codepoint = start;
            while (codepoint <= end) : (codepoint += 1) {
                const glyph_id = start_glyph +% (codepoint - start);
                if (glyph_id > std.math.maxInt(u16)) break;
                try self.set(codepoint, @intCast(glyph_id));
            }
        }
    }

    fn addSymbolAliases(self: *Builder) !void {
        for (0..0x100) |codepoint| {
            if (self.get(@intCast(codepoint)) != 0) continue;
            try self.set(@intCast(codepoint), self.get(0xF000 + @as(u32, @intCast(codepoint))));
        }
    }

    fn finish(self: *Builder) !Cmap {
        var ascii: [128]u16 = undefined;
        for (&ascii, 0..) |*slot, codepoint| slot.* = self.get(@intCast(codepoint));
        return .{
            .ascii = ascii,
            .directory = self.directory,
            .pages = try self.pages.toOwnedSlice(self.arena),
        };
    }
};

fn testFormat4(arena: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    const header = [_]u16{ 0, 1, 3, 1, 0, 12 };
    const words = [_]u16{ 4, 0, 0, 4, 4, 1, 0, 0x42, 0xFFFF, 0, 0x41, 0xFFFF, 0xFFC4, 1, 0, 0 };
    for (header) |word| try bytes.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, word)));
    for (words) |word| try bytes.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, word)));
    std.mem.writeInt(u16, bytes.items[14..][0..2], @intCast(bytes.items.len - 12), .big);
    return bytes.items;
}

test "compiles format 4 deltas into the page table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try testFormat4(arena);
    const cmap = try compile(arena, Reader.init(table));
    try std.testing.expectEqual(@as(u16, 5), cmap.glyph('A'));
    try std.testing.expectEqual(@as(u16, 6), cmap.glyph('B'));
    try std.testing.expectEqual(@as(u16, 0), cmap.glyph('C'));
    try std.testing.expectEqual(@as(u16, 0), cmap.glyph(0x1F600));
    try std.testing.expectEqual(@as(u16, 0), cmap.glyph(0x7FFFFFFF));
}

test "truncated subtables compile to an empty map" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try testFormat4(arena);
    for (0..table.len) |len| {
        const cmap = try compile(arena, Reader.init(table[0..len]));
        try std.testing.expectEqual(@as(u16, 0), cmap.glyph('B'));
    }
}
