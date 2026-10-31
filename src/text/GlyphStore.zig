//! Glyph outlines for the Slug shader, one relocatable blob per glyph in a single
//! word buffer, plus a table of per-slot bounds and band transforms.
//!
//! A blob holds band headers, band lists and a point stream. Band headers and lists
//! are relative to the blob, so compaction moves blobs without rewriting them. Points
//! are quantized to u16 inside the glyph's bounds, and consecutive curves of a contour
//! share end points. Slots unused for `eviction_age_frames` are evicted, oldest first,
//! while the store is over its byte budget.

const std = @import("std");
const Curve = @import("curve.zig").Curve;
const band = @import("band.zig");

allocator: std.mem.Allocator,
words: std.ArrayList(u32) = .empty,
table: std.ArrayList(Entry) = .empty,
slots: std.ArrayList(SlotInfo) = .empty,
free_slots: std.ArrayList(u32) = .empty,
dead_words: usize = 0,
budget_bytes: usize = budget_bytes_default,
frame: u32 = 0,
revision_value: u64 = 1,
/// Bumped when slots are evicted, so holders of slot numbers know to look them up again.
generation: u64 = 0,
emitted_revision: u64 = 0,
dirty: Dirty = .{},

const GlyphStore = @This();

pub const budget_bytes_default = 64 * 1024 * 1024;
pub const eviction_age_frames = 2;
pub const empty_slot: u32 = 0;
pub const blob_words_max = std.math.maxInt(u16);

comptime {
    std.debug.assert(eviction_age_frames == 2);
    std.debug.assert(@sizeOf(Entry) == 48);
}

/// GPU layout of one slot, shared with the renderer.
pub const Entry = @import("render_types").GlyphEntry;

const SlotInfo = struct {
    blob: u32,
    words: u32,
    last_used: u32,
    owner: u64,
    live: bool,
};

const Dirty = struct {
    words_start: usize = std.math.maxInt(usize),
    words_end: usize = 0,
    table_start: usize = std.math.maxInt(usize),
    table_end: usize = 0,
    full: bool = true,

    fn markWords(self: *Dirty, start: usize, end: usize) void {
        self.words_start = @min(self.words_start, start);
        self.words_end = @max(self.words_end, end);
    }

    fn markTable(self: *Dirty, slot: usize) void {
        self.table_start = @min(self.table_start, slot);
        self.table_end = @max(self.table_end, slot + 1);
    }
};

pub const Added = struct {
    slot: u32,
    entry: Entry,
};

pub fn init(allocator: std.mem.Allocator) !GlyphStore {
    var store: GlyphStore = .{ .allocator = allocator };
    try store.table.append(allocator, .empty);
    try store.slots.append(allocator, .{ .blob = 0, .words = 0, .last_used = 0, .owner = 0, .live = true });
    try store.words.append(allocator, 0);
    return store;
}

pub fn deinit(self: *GlyphStore) void {
    self.words.deinit(self.allocator);
    self.table.deinit(self.allocator);
    self.slots.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
}

pub fn bytes(self: *const GlyphStore) usize {
    return self.words.items.len * 4 + self.table.items.len * @sizeOf(Entry);
}

pub fn liveBytes(self: *const GlyphStore) usize {
    return self.bytes() - self.dead_words * 4;
}

pub fn touch(self: *GlyphStore, slot: u32) void {
    self.slots.items[slot].last_used = self.frame;
}

pub fn add(self: *GlyphStore, curves: []const Curve, owner: u64) !Added {
    if (curves.len == 0) return .{ .slot = empty_slot, .entry = .empty };
    const encoded = try encode(self.allocator, curves);
    defer self.allocator.free(encoded.words);
    if (encoded.words.len > blob_words_max) return .{ .slot = empty_slot, .entry = .empty };

    const blob: u32 = @intCast(self.words.items.len);
    try self.words.appendSlice(self.allocator, encoded.words);
    self.dirty.markWords(blob, self.words.items.len);

    var entry = encoded.entry;
    entry.blob = blob;
    const slot = try self.allocateSlot();
    self.table.items[slot] = entry;
    self.slots.items[slot] = .{ .blob = blob, .words = @intCast(encoded.words.len), .last_used = self.frame, .owner = owner, .live = true };
    self.dirty.markTable(slot);
    self.bumpRevision();
    return .{ .slot = slot, .entry = entry };
}

fn allocateSlot(self: *GlyphStore) !u32 {
    if (self.free_slots.pop()) |slot| return slot;
    try self.table.append(self.allocator, .empty);
    try self.slots.append(self.allocator, undefined);
    return @intCast(self.table.items.len - 1);
}

fn bumpRevision(self: *GlyphStore) void {
    self.revision_value +%= 1;
    if (self.revision_value == 0) self.revision_value = 1;
}

/// Evicts slots unused for `eviction_age_frames`, oldest first, while over budget, and compacts.
/// Returns the owners of evicted slots, valid until the next call.
pub fn endFrame(self: *GlyphStore, evicted: *std.ArrayList(u64)) !void {
    evicted.clearRetainingCapacity();
    defer self.frame +%= 1;
    if (self.liveBytes() > self.budget_bytes) try self.evictOldest(evicted);
    if (self.dead_words > 0 and (self.dead_words * 2 > self.words.items.len or self.bytes() > self.budget_bytes)) try self.compact();
}

fn evictOldest(self: *GlyphStore, evicted: *std.ArrayList(u64)) !void {
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(self.allocator);
    for (self.slots.items[1..], 1..) |info, slot| {
        if (!info.live) continue;
        if (self.frame -% info.last_used < eviction_age_frames) continue;
        try candidates.append(self.allocator, @intCast(slot));
    }
    std.mem.sort(u32, candidates.items, self, struct {
        fn lessThan(store: *GlyphStore, a: u32, b: u32) bool {
            return store.frame -% store.slots.items[a].last_used > store.frame -% store.slots.items[b].last_used;
        }
    }.lessThan);
    for (candidates.items) |slot| {
        if (self.liveBytes() <= self.budget_bytes) break;
        const info = &self.slots.items[slot];
        info.live = false;
        self.dead_words += info.words;
        try evicted.append(self.allocator, info.owner);
        try self.free_slots.append(self.allocator, slot);
        self.table.items[slot] = .empty;
    }
    // In-flight frames may still read evicted slots, so consumers replace their copy.
    self.dirty.full = true;
    if (evicted.items.len > 0) self.generation +%= 1;
    self.bumpRevision();
}

/// Moves live blobs down over dead space. Blobs are relative, so only table offsets change.
fn compact(self: *GlyphStore) !void {
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(self.allocator);
    for (self.slots.items[1..], 1..) |info, slot| {
        if (info.live) try order.append(self.allocator, @intCast(slot));
    }
    std.mem.sort(u32, order.items, self, struct {
        fn lessThan(store: *GlyphStore, a: u32, b: u32) bool {
            return store.slots.items[a].blob < store.slots.items[b].blob;
        }
    }.lessThan);
    var write: u32 = 1;
    for (order.items) |slot| {
        const info = &self.slots.items[slot];
        if (info.blob != write) std.mem.copyForwards(u32, self.words.items[write..][0..info.words], self.words.items[info.blob..][0..info.words]);
        info.blob = write;
        self.table.items[slot].blob = write;
        write += info.words;
    }
    self.words.shrinkRetainingCapacity(write);
    self.dead_words = 0;
    self.dirty.full = true;
    self.bumpRevision();
}

pub const Snapshot = struct {
    revision: u64,
    base_revision: u64,
    words: []const u8,
    table: []const u8,
    /// Byte ranges changed since `base_revision`, valid only for consumers holding that base.
    words_dirty: [2]usize,
    table_dirty: [2]usize,
    full: bool,
};

/// Data for the renderer, with changes since the previous snapshot. Marks the store clean.
pub fn snapshot(self: *GlyphStore) Snapshot {
    const result: Snapshot = .{
        .revision = self.revision_value,
        .base_revision = self.emitted_revision,
        .words = std.mem.sliceAsBytes(self.words.items),
        .table = std.mem.sliceAsBytes(self.table.items),
        .words_dirty = byteRange(self.dirty.words_start, self.dirty.words_end, 4),
        .table_dirty = byteRange(self.dirty.table_start, self.dirty.table_end, @sizeOf(Entry)),
        .full = self.dirty.full,
    };
    self.emitted_revision = self.revision_value;
    self.dirty = .{ .full = false };
    return result;
}

fn byteRange(start: usize, end: usize, size: usize) [2]usize {
    if (start >= end) return .{ 0, 0 };
    return .{ start * size, end * size };
}

const Encoded = struct {
    words: []u32,
    entry: Entry,
};

const quant_max: f32 = 65535;

fn quantize(value: f32, min: f32, extent: f32) u16 {
    const scaled = (value - min) / extent * quant_max;
    return @intFromFloat(std.math.clamp(@round(scaled), 0, quant_max));
}

pub fn dequantize(q: u16, min: f32, extent: f32) f32 {
    return min + @as(f32, @floatFromInt(q)) * (extent / quant_max);
}

const Bounds = struct { min: [2]f32, extent: [2]f32 };

fn boundsOf(curves: []const Curve) Bounds {
    var min: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var max: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (curves) |c| {
        inline for (.{ c.p1, c.p2, c.p3 }) |point| {
            min = .{ @min(min[0], point[0]), @min(min[1], point[1]) };
            max = .{ @max(max[0], point[0]), @max(max[1], point[1]) };
        }
    }
    var extent: [2]f32 = .{ max[0] - min[0], max[1] - min[1] };
    if (extent[0] <= 0) extent[0] = 1;
    if (extent[1] <= 0) extent[1] = 1;
    return .{ .min = min, .extent = extent };
}

const Point = [2]u16;

fn quantizePoint(point: [2]f32, bounds: Bounds) Point {
    return .{ quantize(point[0], bounds.min[0], bounds.extent[0]), quantize(point[1], bounds.min[1], bounds.extent[1]) };
}

fn decodePoint(point: Point, bounds: Bounds) [2]f32 {
    return .{ dequantize(point[0], bounds.min[0], bounds.extent[0]), dequantize(point[1], bounds.min[1], bounds.extent[1]) };
}

pub fn encode(allocator: std.mem.Allocator, curves_in: []const Curve) !Encoded {
    const bounds = boundsOf(curves_in);
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(allocator);
    const starts = try allocator.alloc(u32, curves_in.len);
    defer allocator.free(starts);
    const decoded = try allocator.alloc(Curve, curves_in.len);
    defer allocator.free(decoded);
    for (curves_in, 0..) |c, index| {
        const p1 = quantizePoint(c.p1, bounds);
        const p2 = quantizePoint(c.p2, bounds);
        const p3 = quantizePoint(c.p3, bounds);
        const shares = points.items.len > 0 and std.meta.eql(points.items[points.items.len - 1], p1);
        if (!shares) try points.append(allocator, p1);
        starts[index] = @intCast(points.items.len - 1);
        try points.append(allocator, p2);
        try points.append(allocator, p3);
        decoded[index] = .{ .p1 = decodePoint(p1, bounds), .p2 = decodePoint(p2, bounds), .p3 = decodePoint(p3, bounds) };
    }
    if (points.items.len > std.math.maxInt(u16)) return error.GlyphTooComplex;

    var partition_result = try band.partition(allocator, decoded);
    defer partition_result.deinit(allocator);
    const header_count = partition_result.horizontal_bands.len + partition_result.vertical_bands.len;
    var list_words: usize = 0;
    for (partition_result.horizontal_bands) |entries| list_words += (entries.len + 1) / 2;
    for (partition_result.vertical_bands) |entries| list_words += (entries.len + 1) / 2;
    const total = header_count + list_words + points.items.len;
    const words = try allocator.alloc(u32, total);
    errdefer allocator.free(words);
    @memset(words, 0);

    var cursor: usize = header_count;
    var header: usize = 0;
    for ([_][][]u32{ partition_result.horizontal_bands, partition_result.vertical_bands }) |bands| {
        for (bands) |entries| {
            words[header] = @as(u32, @intCast(entries.len)) | (@as(u32, @intCast(cursor)) << 16);
            for (entries, 0..) |curve_index, position| {
                const shift: u5 = @intCast((position % 2) * 16);
                words[cursor + position / 2] |= starts[curve_index] << shift;
            }
            cursor += (entries.len + 1) / 2;
            header += 1;
        }
    }
    if (cursor > std.math.maxInt(u16)) return error.GlyphTooComplex;
    const points_offset = cursor;
    for (points.items, 0..) |point, index| words[points_offset + index] = @as(u32, point[0]) | (@as(u32, point[1]) << 16);

    return .{
        .words = words,
        .entry = .{
            .bounds = .{ bounds.min[0], bounds.min[1], bounds.min[0] + bounds.extent[0], bounds.min[1] + bounds.extent[1] },
            .band = .{ partition_result.band_scale[0], partition_result.band_scale[1], partition_result.band_offset[0], partition_result.band_offset[1] },
            .blob = 0,
            .points = @intCast(points_offset),
            .band_max = @as(u32, partition_result.band_index_max[0]) | (@as(u32, partition_result.band_index_max[1]) << 8),
        },
    };
}

/// Reads curve `index` of band list entry back, the way the shader does.
pub fn decodeCurve(words: []const u32, entry: Entry, point_index: u32) Curve {
    const bounds: Bounds = .{ .min = .{ entry.bounds[0], entry.bounds[1] }, .extent = .{ entry.bounds[2] - entry.bounds[0], entry.bounds[3] - entry.bounds[1] } };
    var result: [3][2]f32 = undefined;
    for (&result, 0..) |*point, offset| {
        const word = words[entry.blob + entry.points + point_index + offset];
        point.* = decodePoint(.{ @truncate(word), @truncate(word >> 16) }, bounds);
    }
    return .{ .p1 = result[0], .p2 = result[1], .p3 = result[2] };
}

fn squareCurves() [4]Curve {
    return .{
        .{ .p1 = .{ 0, 0 }, .p2 = .{ 0.5, 0 }, .p3 = .{ 1, 0 } },
        .{ .p1 = .{ 1, 0 }, .p2 = .{ 1, 0.5 }, .p3 = .{ 1, 1 } },
        .{ .p1 = .{ 1, 1 }, .p2 = .{ 0.5, 1 }, .p3 = .{ 0, 1 } },
        .{ .p1 = .{ 0, 1 }, .p2 = .{ 0, 0.5 }, .p3 = .{ 0, 0 } },
    };
}

test "blobs share end points and decode back within quantization error" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    const curves = squareCurves();
    const added = try store.add(&curves, 1);
    const info = store.slots.items[added.slot];
    const headers = (added.entry.band_max & 0xFF) + 1 + (added.entry.band_max >> 8) + 1;
    try std.testing.expect(info.words - added.entry.points == 9);
    try std.testing.expect(headers > 0);
    const words = store.words.items;
    for (0..headers) |header| {
        const word = words[info.blob + header];
        const count = word & 0xFFFF;
        const list = word >> 16;
        for (0..count) |position| {
            const packed_word = words[info.blob + list + position / 2];
            const point_index = (packed_word >> @intCast((position % 2) * 16)) & 0xFFFF;
            const decoded = decodeCurve(words, store.table.items[added.slot], point_index);
            var matched = false;
            for (curves) |original| {
                if (@abs(original.p1[0] - decoded.p1[0]) < 1e-4 and @abs(original.p1[1] - decoded.p1[1]) < 1e-4 and
                    @abs(original.p3[0] - decoded.p3[0]) < 1e-4 and @abs(original.p3[1] - decoded.p3[1]) < 1e-4) matched = true;
            }
            try std.testing.expect(matched);
        }
    }
}

test "evicts cold glyphs over budget and compacts the store" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    var evicted: std.ArrayList(u64) = .empty;
    defer evicted.deinit(std.testing.allocator);
    const curves = squareCurves();
    const first = try store.add(&curves, 1);
    try store.endFrame(&evicted);
    try store.endFrame(&evicted);
    store.budget_bytes = store.bytes();
    const second = try store.add(&curves, 2);
    try store.endFrame(&evicted);
    try std.testing.expectEqualSlices(u64, &.{1}, evicted.items);
    try std.testing.expect(store.slots.items[second.slot].live);
    try std.testing.expect(!store.slots.items[first.slot].live);
    try std.testing.expectEqual(@as(u32, 1), store.table.items[second.slot].blob);
    try std.testing.expect(store.snapshot().full);
}

test "200k distinct glyphs fit a 4 MiB budget across frames" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    store.budget_bytes = 4 * 1024 * 1024;
    var evicted: std.ArrayList(u64) = .empty;
    defer evicted.deinit(std.testing.allocator);
    var curves = squareCurves();
    var count: u64 = 0;
    while (count < 200_000) : (count += 1) {
        curves[1].p2[0] = 1 + @as(f32, @floatFromInt(count % 97)) / 97;
        _ = try store.add(&curves, count);
        if (count % 1000 == 999) {
            try store.endFrame(&evicted);
            try std.testing.expect(store.bytes() <= store.budget_bytes + 1000 * 128);
        }
    }
}
