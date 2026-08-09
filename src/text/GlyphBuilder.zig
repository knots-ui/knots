const std = @import("std");
const Curve = @import("curve.zig").Curve;
const band = @import("band.zig");
const glyph = @import("glyph.zig");

curve_data: std.ArrayList(CurveTexel),
band_data: std.ArrayList(BandTexel),
curve_dirty_min_y: u32,
curve_dirty_max_y_excl: u32,
band_dirty_min_y: u32,
band_dirty_max_y_excl: u32,
allocator: std.mem.Allocator,
revision_value: u64,

// A square 4096 atlas fits every supported backend and keeps coordinates compact.
pub const texture_width: u32 = 4096;

const texture_width_log2: u5 = 12;
const texture_texel_count_max: u64 = @as(u64, texture_width) * texture_width;
const GlyphBuilder = @This();

comptime {
    std.debug.assert(texture_width > 0);
    std.debug.assert(texture_width & (texture_width - 1) == 0);
    std.debug.assert(@as(u32, 1) << texture_width_log2 == texture_width);
}

pub const CurveTexel = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const BandTexel = extern struct {
    x: u32,
    y: u32,
    z: u32 = 0,
    w: u32 = 0,
};

pub const DirtyRange = struct {
    y_start: u32,
    y_end: u32,
};

const BandAppendResult = struct {
    glyph_location: u32,
    dirty_range: DirtyRange,
};

pub fn init(allocator: std.mem.Allocator) !GlyphBuilder {
    var glyph_builder = GlyphBuilder{
        .curve_data = .empty,
        .band_data = .empty,
        .curve_dirty_min_y = std.math.maxInt(u32),
        .curve_dirty_max_y_excl = 0,
        .band_dirty_min_y = std.math.maxInt(u32),
        .band_dirty_max_y_excl = 0,
        .allocator = allocator,
        .revision_value = 0,
    };

    // Empty glyphs point to this zero-curve header so the shader produces no coverage.
    try glyph_builder.band_data.append(allocator, .{ .x = 0, .y = 0 });
    glyph_builder.markBandDirty(0, 1);
    return glyph_builder;
}

pub fn deinit(self: *GlyphBuilder) void {
    self.curve_data.deinit(self.allocator);
    self.band_data.deinit(self.allocator);
}

pub fn isDirty(self: *const GlyphBuilder) bool {
    if (self.curve_dirty_min_y < self.curve_dirty_max_y_excl) return true;
    return self.band_dirty_min_y < self.band_dirty_max_y_excl;
}

/// Advanced by every mutation that dirties rows, letting consumers tell a
/// re-emitted dirty range from newly dirtied ones. Anything that widens a dirty
/// range must bump it.
pub fn revision(self: *const GlyphBuilder) u64 {
    return self.revision_value;
}

pub fn markClean(self: *GlyphBuilder) void {
    self.curve_dirty_min_y = std.math.maxInt(u32);
    self.curve_dirty_max_y_excl = 0;
    self.band_dirty_min_y = std.math.maxInt(u32);
    self.band_dirty_max_y_excl = 0;
}

pub fn markAllDirty(self: *GlyphBuilder) void {
    self.curve_dirty_min_y = 0;
    self.curve_dirty_max_y_excl = self.curveTextureHeight();
    self.band_dirty_min_y = 0;
    self.band_dirty_max_y_excl = self.bandTextureHeight();
    self.bumpRevision();
}

pub fn markCurveDirtyTo(self: *GlyphBuilder, y_exclusive: u32) void {
    std.debug.assert(y_exclusive <= texture_width);
    self.curve_dirty_min_y = 0;
    self.curve_dirty_max_y_excl = y_exclusive;
    self.bumpRevision();
}

pub fn markBandDirtyTo(self: *GlyphBuilder, y_exclusive: u32) void {
    std.debug.assert(y_exclusive <= texture_width);
    self.band_dirty_min_y = 0;
    self.band_dirty_max_y_excl = y_exclusive;
    self.bumpRevision();
}

pub fn curveTextureHeight(self: *const GlyphBuilder) u32 {
    return textureHeight(self.curve_data.items.len);
}

pub fn bandTextureHeight(self: *const GlyphBuilder) u32 {
    return textureHeight(self.band_data.items.len);
}

pub fn curveDirtyRange(self: *const GlyphBuilder) ?DirtyRange {
    if (self.curve_dirty_min_y < self.curve_dirty_max_y_excl) {
        return .{
            .y_start = self.curve_dirty_min_y,
            .y_end = self.curve_dirty_max_y_excl,
        };
    }
    return null;
}

pub fn bandDirtyRange(self: *const GlyphBuilder) ?DirtyRange {
    if (self.band_dirty_min_y < self.band_dirty_max_y_excl) {
        return .{
            .y_start = self.band_dirty_min_y,
            .y_end = self.band_dirty_max_y_excl,
        };
    }
    return null;
}

pub fn curveBytes(self: *const GlyphBuilder, range: DirtyRange) []const u8 {
    const start: usize = @as(usize, range.y_start) * texture_width;
    const end_max: usize = @as(usize, range.y_end) * texture_width;
    const end = @min(end_max, self.curve_data.items.len);
    std.debug.assert(start <= end);
    return std.mem.sliceAsBytes(self.curve_data.items[start..end]);
}

pub fn bandBytes(self: *const GlyphBuilder, range: DirtyRange) []const u8 {
    const start: usize = @as(usize, range.y_start) * texture_width;
    const end_max: usize = @as(usize, range.y_end) * texture_width;
    const end = @min(end_max, self.band_data.items.len);
    std.debug.assert(start <= end);
    return std.mem.sliceAsBytes(self.band_data.items[start..end]);
}

fn textureHeight(texel_count: usize) u32 {
    std.debug.assert(texel_count <= texture_texel_count_max);
    const count: u32 = @intCast(texel_count);
    return (count + texture_width - 1) / texture_width;
}

fn markCurveDirty(self: *GlyphBuilder, y_start: u32, y_end: u32) void {
    std.debug.assert(y_start <= y_end);
    std.debug.assert(y_end <= texture_width);
    self.curve_dirty_min_y = @min(self.curve_dirty_min_y, y_start);
    self.curve_dirty_max_y_excl = @max(self.curve_dirty_max_y_excl, y_end);
    self.bumpRevision();
}

fn markBandDirty(self: *GlyphBuilder, y_start: u32, y_end: u32) void {
    std.debug.assert(y_start <= y_end);
    std.debug.assert(y_end <= texture_width);
    self.band_dirty_min_y = @min(self.band_dirty_min_y, y_start);
    self.band_dirty_max_y_excl = @max(self.band_dirty_max_y_excl, y_end);
    self.bumpRevision();
}

fn bumpRevision(self: *GlyphBuilder) void {
    self.revision_value +%= 1;
    if (self.revision_value == 0) self.revision_value = 1;
}

fn bandTexelCount(partition_result: *const band.PartitionResult) u64 {
    var count: u64 =
        partition_result.horizontal_bands.len + partition_result.vertical_bands.len;
    for (partition_result.horizontal_bands) |entries| count += entries.len;
    for (partition_result.vertical_bands) |entries| count += entries.len;
    return count;
}

fn ensureAtlasCapacity(self: *GlyphBuilder, curve_count: usize, band_texel_count: u64) !void {
    const curve_texel_count = @as(u64, @intCast(curve_count)) * 2;
    const curve_end = @as(u64, @intCast(self.curve_data.items.len)) + curve_texel_count;
    const band_end = @as(u64, @intCast(self.band_data.items.len)) + band_texel_count;
    if (curve_end > texture_texel_count_max) return error.GlyphBuilderFull;
    if (band_end > texture_texel_count_max) return error.GlyphBuilderFull;
}

fn appendCurveTexels(self: *GlyphBuilder, curves: []const Curve, curve_locations: []u32) DirtyRange {
    std.debug.assert(curves.len == curve_locations.len);
    std.debug.assert(self.curve_data.capacity - self.curve_data.items.len >= curves.len * 2);

    const y_start: u32 = @intCast(self.curve_data.items.len >> texture_width_log2);
    for (curves, curve_locations) |curve, *location| {
        location.* = @intCast(self.curve_data.items.len);
        self.curve_data.appendAssumeCapacity(.{
            .x = curve.p1[0],
            .y = curve.p1[1],
            .z = curve.p2[0],
            .w = curve.p2[1],
        });
        self.curve_data.appendAssumeCapacity(.{
            .x = curve.p3[0],
            .y = curve.p3[1],
            .z = 0,
            .w = 0,
        });
    }
    return .{ .y_start = y_start, .y_end = self.curveTextureHeight() };
}

fn appendBandLists(
    self: *GlyphBuilder,
    bands: []const []u32,
    header_start: usize,
    header_offset: usize,
    glyph_location: u32,
    curve_locations: []const u32,
) void {
    for (bands, 0..) |entries, band_index| {
        const list_location: u32 = @intCast(self.band_data.items.len);
        self.band_data.items[header_start + header_offset + band_index] = .{
            .x = @intCast(entries.len),
            .y = list_location - glyph_location,
        };
        for (entries) |curve_index| {
            const curve_location = curve_locations[curve_index];
            self.band_data.appendAssumeCapacity(.{
                .x = curve_location & (texture_width - 1),
                .y = curve_location >> texture_width_log2,
            });
        }
    }
}

fn appendBandTexels(self: *GlyphBuilder, partition_result: *const band.PartitionResult, curve_locations: []const u32) BandAppendResult {
    const glyph_location: u32 = @intCast(self.band_data.items.len);
    const y_start: u32 = glyph_location >> texture_width_log2;
    const header_count =
        partition_result.horizontal_bands.len + partition_result.vertical_bands.len;
    const header_start = self.band_data.items.len;
    for (0..header_count) |_| self.band_data.appendAssumeCapacity(.{ .x = 0, .y = 0 });

    self.appendBandLists(
        partition_result.horizontal_bands,
        header_start,
        0,
        glyph_location,
        curve_locations,
    );
    self.appendBandLists(
        partition_result.vertical_bands,
        header_start,
        partition_result.horizontal_bands.len,
        glyph_location,
        curve_locations,
    );

    return .{
        .glyph_location = glyph_location,
        .dirty_range = .{ .y_start = y_start, .y_end = self.bandTextureHeight() },
    };
}

pub fn addCurves(self: *GlyphBuilder, curves: []const Curve) !glyph.GlyphRecord {
    if (curves.len == 0) return .empty;
    try self.ensureAtlasCapacity(curves.len, 0);

    var partition_result = try band.partition(self.allocator, curves);
    defer partition_result.deinit(self.allocator);

    const band_texel_count = bandTexelCount(&partition_result);
    try self.ensureAtlasCapacity(curves.len, band_texel_count);
    try self.curve_data.ensureUnusedCapacity(self.allocator, curves.len * 2);
    try self.band_data.ensureUnusedCapacity(
        self.allocator,
        @intCast(band_texel_count),
    );

    const curve_locations = try self.allocator.alloc(u32, curves.len);
    defer self.allocator.free(curve_locations);

    const curve_dirty_range = self.appendCurveTexels(curves, curve_locations);
    const band_result = self.appendBandTexels(&partition_result, curve_locations);
    self.markCurveDirty(curve_dirty_range.y_start, curve_dirty_range.y_end);
    self.markBandDirty(band_result.dirty_range.y_start, band_result.dirty_range.y_end);

    return .{
        .glyph_location_x = @intCast(
            band_result.glyph_location & (texture_width - 1),
        ),
        .glyph_location_y = @intCast(
            band_result.glyph_location >> texture_width_log2,
        ),
        .band_x_max = partition_result.band_index_max[0],
        .band_y_max = partition_result.band_index_max[1],
        .bounds_em_min = partition_result.bounding_box_min,
        .bounds_em_max = partition_result.bounding_box_max,
        .band_scale = partition_result.band_scale,
        .band_offset = partition_result.band_offset,
        .advance_em = 0,
        .is_empty = false,
    };
}

test "produces curves and bands" {
    const allocator = std.testing.allocator;

    const curves = [_]Curve{
        .{ .p1 = .{ 0, 0 }, .p2 = .{ 0.5, 0 }, .p3 = .{ 1, 0 } },
        .{ .p1 = .{ 1, 0 }, .p2 = .{ 1, 0.5 }, .p3 = .{ 1, 1 } },
        .{ .p1 = .{ 1, 1 }, .p2 = .{ 0.5, 1 }, .p3 = .{ 0, 1 } },
        .{ .p1 = .{ 0, 1 }, .p2 = .{ 0, 0.5 }, .p3 = .{ 0, 0 } },
    };

    var glyph_builder = try GlyphBuilder.init(allocator);
    defer glyph_builder.deinit();

    const record = try glyph_builder.addCurves(&curves);

    try std.testing.expect(!record.is_empty);
    try std.testing.expectEqual(8, glyph_builder.curve_data.items.len);
    try std.testing.expect(glyph_builder.band_data.items.len > 1);
    try std.testing.expectEqual(1, record.glyph_location_x);
    try std.testing.expectEqual(0, record.glyph_location_y);
}
