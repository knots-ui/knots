const std = @import("std");
const ft = @import("freetype").c;
const curve_mod = @import("curve.zig");
const band_mod = @import("band.zig");
const glyph = @import("glyph.zig");

const Curve = curve_mod.Curve;

pub const TEXTURE_WIDTH: u32 = 4096;
const LOG_TEXTURE_WIDTH: u5 = 12;

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

curve_data: std.ArrayList(CurveTexel),
band_data: std.ArrayList(BandTexel),
curve_dirty_min_y: u32,
curve_dirty_max_y_excl: u32,
band_dirty_min_y: u32,
band_dirty_max_y_excl: u32,
allocator: std.mem.Allocator,

const GlyphBuilder = @This();

pub fn init(allocator: std.mem.Allocator) !GlyphBuilder {
    var self = GlyphBuilder{
        .curve_data = .empty,
        .band_data = .empty,
        .curve_dirty_min_y = std.math.maxInt(u32),
        .curve_dirty_max_y_excl = 0,
        .band_dirty_min_y = std.math.maxInt(u32),
        .band_dirty_max_y_excl = 0,
        .allocator = allocator,
    };
    // Sentinel band-header texel (0 curves) at band index 0 so empty glyphs
    // can point there and produce zero coverage in the shader.
    try self.band_data.append(allocator, .{ .x = 0, .y = 0 });
    self.markBandDirty(0, 1);
    return self;
}

pub fn deinit(self: *GlyphBuilder) void {
    self.curve_data.deinit(self.allocator);
    self.band_data.deinit(self.allocator);
}

pub fn isDirty(self: *const GlyphBuilder) bool {
    return self.curve_dirty_min_y < self.curve_dirty_max_y_excl or
        self.band_dirty_min_y < self.band_dirty_max_y_excl;
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
}

pub fn curveTextureHeight(self: *const GlyphBuilder) u32 {
    const len: u32 = @intCast(self.curve_data.items.len);
    return (len + TEXTURE_WIDTH - 1) / TEXTURE_WIDTH;
}

pub fn bandTextureHeight(self: *const GlyphBuilder) u32 {
    const len: u32 = @intCast(self.band_data.items.len);
    return (len + TEXTURE_WIDTH - 1) / TEXTURE_WIDTH;
}

pub fn curveDirtyRange(self: *const GlyphBuilder) ?struct { y0: u32, y1: u32 } {
    if (self.curve_dirty_min_y >= self.curve_dirty_max_y_excl) return null;
    return .{ .y0 = self.curve_dirty_min_y, .y1 = self.curve_dirty_max_y_excl };
}

pub fn bandDirtyRange(self: *const GlyphBuilder) ?struct { y0: u32, y1: u32 } {
    if (self.band_dirty_min_y >= self.band_dirty_max_y_excl) return null;
    return .{ .y0 = self.band_dirty_min_y, .y1 = self.band_dirty_max_y_excl };
}

fn markCurveDirty(self: *GlyphBuilder, y0: u32, y1_excl: u32) void {
    self.curve_dirty_min_y = @min(self.curve_dirty_min_y, y0);
    self.curve_dirty_max_y_excl = @max(self.curve_dirty_max_y_excl, y1_excl);
}

fn markBandDirty(self: *GlyphBuilder, y0: u32, y1_excl: u32) void {
    self.band_dirty_min_y = @min(self.band_dirty_min_y, y0);
    self.band_dirty_max_y_excl = @max(self.band_dirty_max_y_excl, y1_excl);
}

pub fn addOutline(
    self: *GlyphBuilder,
    outline: *const ft.FT_Outline,
    units_per_em: f32,
) anyerror!glyph.GlyphRecord {
    const curves = try curve_mod.decomposeOutline(outline, units_per_em, self.allocator);
    defer self.allocator.free(curves);

    if (curves.len == 0) {
        return self.makeEmptyRecord();
    }

    var part = try band_mod.partition(curves, self.allocator);
    defer part.deinit(self.allocator);

    const band_count_x: u32 = @as(u32, part.band_max[0]) + 1;
    const band_count_y: u32 = @as(u32, part.band_max[1]) + 1;

    const curve_start_idx: u32 = @intCast(self.curve_data.items.len);
    const curve_y0: u32 = curve_start_idx >> LOG_TEXTURE_WIDTH;

    try self.curve_data.ensureUnusedCapacity(self.allocator, curves.len * 2);

    var curve_locs = try self.allocator.alloc(u32, curves.len);
    defer self.allocator.free(curve_locs);

    for (curves, 0..) |c, i| {
        const idx: u32 = @intCast(self.curve_data.items.len);
        curve_locs[i] = idx;
        self.curve_data.appendAssumeCapacity(.{ .x = c.p1[0], .y = c.p1[1], .z = c.p2[0], .w = c.p2[1] });
        self.curve_data.appendAssumeCapacity(.{ .x = c.p3[0], .y = c.p3[1], .z = 0, .w = 0 });
    }

    if (curve_start_idx != self.curve_data.items.len) {
        const curve_y1 = self.curveTextureHeight();
        self.markCurveDirty(curve_y0, curve_y1);
    }

    const band_start_idx: u32 = @intCast(self.band_data.items.len);
    const band_y0: u32 = band_start_idx >> LOG_TEXTURE_WIDTH;
    const glyph_loc_idx: u32 = band_start_idx;

    const header_count = band_count_x + band_count_y;
    var total_list_entries: u32 = 0;
    for (part.h_bands) |b| total_list_entries += @intCast(b.len);
    for (part.v_bands) |b| total_list_entries += @intCast(b.len);

    try self.band_data.ensureUnusedCapacity(self.allocator, header_count + total_list_entries);

    const headers_start: u32 = @intCast(self.band_data.items.len);
    for (0..header_count) |_| self.band_data.appendAssumeCapacity(.{ .x = 0, .y = 0 });

    var hi: u32 = 0;
    for (part.h_bands) |b| {
        const list_idx: u32 = @intCast(self.band_data.items.len);
        const offset_rel = list_idx - glyph_loc_idx;
        self.band_data.items[headers_start + hi] = .{
            .x = @intCast(b.len),
            .y = offset_rel,
        };
        for (b) |ci| {
            const cl = curve_locs[ci];
            self.band_data.appendAssumeCapacity(.{
                .x = cl & (TEXTURE_WIDTH - 1),
                .y = cl >> LOG_TEXTURE_WIDTH,
            });
        }
        hi += 1;
    }

    var vi: u32 = 0;
    for (part.v_bands) |b| {
        const list_idx: u32 = @intCast(self.band_data.items.len);
        const offset_rel = list_idx - glyph_loc_idx;
        self.band_data.items[headers_start + band_count_y + vi] = .{
            .x = @intCast(b.len),
            .y = offset_rel,
        };
        for (b) |ci| {
            const cl = curve_locs[ci];
            self.band_data.appendAssumeCapacity(.{
                .x = cl & (TEXTURE_WIDTH - 1),
                .y = cl >> LOG_TEXTURE_WIDTH,
            });
        }
        vi += 1;
    }

    const band_y1 = self.bandTextureHeight();
    self.markBandDirty(band_y0, band_y1);

    if ((glyph_loc_idx >> LOG_TEXTURE_WIDTH) >= TEXTURE_WIDTH) return error.GlyphBuilderFull;
    if (curve_start_idx != self.curve_data.items.len and
        ((curve_start_idx >> LOG_TEXTURE_WIDTH) >= TEXTURE_WIDTH))
        return error.GlyphBuilderFull;

    return .{
        .glyph_loc_x = @intCast(glyph_loc_idx & (TEXTURE_WIDTH - 1)),
        .glyph_loc_y = @intCast(glyph_loc_idx >> LOG_TEXTURE_WIDTH),
        .band_max_x = part.band_max[0],
        .band_max_y = part.band_max[1],
        .flags = 0,
        .em_min = part.bbox_min,
        .em_max = part.bbox_max,
        .band_scale = part.band_scale,
        .band_offset = part.band_offset,
        .advance_em = 0,
        .bearing_em = .{ 0, 0 },
        .is_empty = false,
    };
}

fn makeEmptyRecord(_: *GlyphBuilder) glyph.GlyphRecord {
    return .{
        .glyph_loc_x = 0,
        .glyph_loc_y = 0,
        .band_max_x = 0,
        .band_max_y = 0,
        .flags = 0,
        .em_min = .{ 0, 0 },
        .em_max = .{ 0, 0 },
        .band_scale = .{ 0, 0 },
        .band_offset = .{ 0, 0 },
        .advance_em = 0,
        .bearing_em = .{ 0, 0 },
        .is_empty = true,
    };
}

test "produces curves and bands" {
    const allocator = std.testing.allocator;

    var pts = [_]ft.FT_Vector{
        .{ .x = 0, .y = 0 },
        .{ .x = 1024, .y = 0 },
        .{ .x = 1024, .y = 1024 },
        .{ .x = 0, .y = 1024 },
    };
    var tags = [_]u8{ 1, 1, 1, 1 };
    var contours = [_]c_ushort{3};
    const outline = ft.FT_Outline{
        .n_contours = 1,
        .n_points = 4,
        .points = &pts,
        .tags = &tags,
        .contours = &contours,
        .flags = 0,
    };

    var gb = try GlyphBuilder.init(allocator);
    defer gb.deinit();

    const rec = try gb.addOutline(&outline, 1024.0);

    try std.testing.expect(!rec.is_empty);
    // 4 line as quadratics x 2 texels == 8 curve texels.
    try std.testing.expectEqual(8, gb.curve_data.items.len);
    // Bands should follow sentinel.
    try std.testing.expect(gb.band_data.items.len > 1);
    // Sentinel band texel occupies index 0, first glyph starts at index 1.
    try std.testing.expectEqual(1, rec.glyph_loc_x);
    try std.testing.expectEqual(0, rec.glyph_loc_y);
}
