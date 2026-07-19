const std = @import("std");
const Curve = @import("curve.zig").Curve;

// The shader stores each axis's maximum band index in a u8.
pub const bands_per_axis_max: u32 = 16;

const band_epsilon: f32 = 1.0 / 65536.0;
const curves_per_band_target: f32 = 4.0;

comptime {
    std.debug.assert(bands_per_axis_max > 0);
    std.debug.assert(bands_per_axis_max - 1 <= std.math.maxInt(u8));
}

pub const PartitionResult = struct {
    band_index_max: [2]u8,
    band_scale: [2]f32,
    band_offset: [2]f32,
    horizontal_bands: [][]u32,
    vertical_bands: [][]u32,
    bounding_box_min: [2]f32,
    bounding_box_max: [2]f32,

    pub fn deinit(self: *PartitionResult, allocator: std.mem.Allocator) void {
        for (self.horizontal_bands) |band| allocator.free(band);
        for (self.vertical_bands) |band| allocator.free(band);
        allocator.free(self.horizontal_bands);
        allocator.free(self.vertical_bands);
    }
};

const Bounds = struct {
    min: [2]f32,
    max: [2]f32,
};

const FillOptions = struct {
    bands: [][]u32,
    origin: f32,
    span: f32,
    slab_axis: u1,
    sort_axis: u1,
};

fn curveExtent(curve: Curve, axis: u1) [2]f32 {
    const start = curve.p1[axis];
    const control = curve.p2[axis];
    const end = curve.p3[axis];
    return .{
        @min(@min(start, control), end),
        @max(@max(start, control), end),
    };
}

const SortContext = struct {
    curves: []const Curve,
    axis: u1,

    pub fn lessThan(self: SortContext, curve_a: u32, curve_b: u32) bool {
        const extent_a = curveExtent(self.curves[curve_a], self.axis);
        const extent_b = curveExtent(self.curves[curve_b], self.axis);
        return extent_a[1] > extent_b[1];
    }
};

fn emptyPartition(allocator: std.mem.Allocator) !PartitionResult {
    const horizontal_bands = try allocator.alloc([]u32, 1);
    errdefer allocator.free(horizontal_bands);
    horizontal_bands[0] = try allocator.alloc(u32, 0);
    errdefer allocator.free(horizontal_bands[0]);

    const vertical_bands = try allocator.alloc([]u32, 1);
    errdefer allocator.free(vertical_bands);
    vertical_bands[0] = try allocator.alloc(u32, 0);

    return .{
        .band_index_max = .{ 0, 0 },
        .band_scale = .{ 0, 0 },
        .band_offset = .{ 0, 0 },
        .horizontal_bands = horizontal_bands,
        .vertical_bands = vertical_bands,
        .bounding_box_min = .{ 0, 0 },
        .bounding_box_max = .{ 0, 0 },
    };
}

fn curveBounds(curves: []const Curve) Bounds {
    std.debug.assert(curves.len > 0);

    var bounds = Bounds{
        .min = .{ std.math.inf(f32), std.math.inf(f32) },
        .max = .{ -std.math.inf(f32), -std.math.inf(f32) },
    };
    for (curves) |curve| {
        inline for ([_][2]f32{ curve.p1, curve.p2, curve.p3 }) |point| {
            std.debug.assert(std.math.isFinite(point[0]));
            std.debug.assert(std.math.isFinite(point[1]));
            bounds.min[0] = @min(bounds.min[0], point[0]);
            bounds.min[1] = @min(bounds.min[1], point[1]);
            bounds.max[0] = @max(bounds.max[0], point[0]);
            bounds.max[1] = @max(bounds.max[1], point[1]);
        }
    }
    return bounds;
}

pub fn partition(allocator: std.mem.Allocator, curves: []const Curve) !PartitionResult {
    if (curves.len == 0) return emptyPartition(allocator);
    if (curves.len > std.math.maxInt(u32)) return error.TooManyCurves;

    const bounds = curveBounds(curves);
    var span = [2]f32{
        bounds.max[0] - bounds.min[0],
        bounds.max[1] - bounds.min[1],
    };
    inline for (&span) |*axis_span| {
        if (axis_span.* <= 0) axis_span.* = 1;
    }

    const curve_count_float: f32 = @floatFromInt(curves.len);
    const band_count_raw: u32 = @intFromFloat(
        @round(curve_count_float / curves_per_band_target),
    );
    const band_count_x: u32 = @max(1, @min(band_count_raw, bands_per_axis_max));
    const band_count_y: u32 = band_count_x;

    const band_scale = [2]f32{
        @as(f32, @floatFromInt(band_count_x)) / span[0],
        @as(f32, @floatFromInt(band_count_y)) / span[1],
    };
    const band_offset = [2]f32{
        -bounds.min[0] * band_scale[0],
        -bounds.min[1] * band_scale[1],
    };

    const horizontal_bands = try allocator.alloc([]u32, band_count_y);
    errdefer allocator.free(horizontal_bands);
    const vertical_bands = try allocator.alloc([]u32, band_count_x);
    errdefer allocator.free(vertical_bands);

    try fillBands(allocator, curves, .{
        .bands = horizontal_bands,
        .origin = bounds.min[1],
        .span = span[1],
        .slab_axis = 1,
        .sort_axis = 0,
    });
    errdefer for (horizontal_bands) |band| allocator.free(band);

    try fillBands(allocator, curves, .{
        .bands = vertical_bands,
        .origin = bounds.min[0],
        .span = span[0],
        .slab_axis = 0,
        .sort_axis = 1,
    });

    return .{
        .band_index_max = .{
            @intCast(band_count_x - 1),
            @intCast(band_count_y - 1),
        },
        .band_scale = band_scale,
        .band_offset = band_offset,
        .horizontal_bands = horizontal_bands,
        .vertical_bands = vertical_bands,
        .bounding_box_min = bounds.min,
        .bounding_box_max = bounds.max,
    };
}

fn fillBands(allocator: std.mem.Allocator, curves: []const Curve, options: FillOptions) !void {
    std.debug.assert(options.bands.len > 0);
    std.debug.assert(options.bands.len <= bands_per_axis_max);
    std.debug.assert(options.span > 0);

    const band_height = options.span / @as(f32, @floatFromInt(options.bands.len));

    var curve_indices: std.ArrayList(u32) = .empty;
    defer curve_indices.deinit(allocator);

    var filled: u32 = 0;
    errdefer {
        for (options.bands[0..filled]) |band| allocator.free(band);
    }

    for (options.bands, 0..) |*band, band_index| {
        const band_min = options.origin +
            @as(f32, @floatFromInt(band_index)) * band_height - band_epsilon;
        const band_max = options.origin +
            @as(f32, @floatFromInt(band_index + 1)) * band_height + band_epsilon;

        curve_indices.clearRetainingCapacity();
        for (curves, 0..) |curve, curve_index| {
            const extent = curveExtent(curve, options.slab_axis);
            if (extent[1] < band_min) continue;
            if (extent[0] > band_max) continue;
            try curve_indices.append(allocator, @intCast(curve_index));
        }

        const context = SortContext{ .curves = curves, .axis = options.sort_axis };
        std.mem.sort(u32, curve_indices.items, context, SortContext.lessThan);

        band.* = try allocator.dupe(u32, curve_indices.items);
        filled += 1;
    }
}

test "partition single horizontal line yields one band" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0, 0.5 }, .p2 = .{ 0.5, 0.5 }, .p3 = .{ 1, 0.5 } },
    };
    var result = try partition(allocator, curves);
    defer result.deinit(allocator);

    try std.testing.expectEqual(0, result.band_index_max[0]);
    try std.testing.expectEqual(0, result.band_index_max[1]);
    try std.testing.expectEqual(1, result.horizontal_bands.len);
    try std.testing.expectEqual(1, result.horizontal_bands[0].len);
    try std.testing.expectEqual(0, result.horizontal_bands[0][0]);
}

test "partition sorts within band by descending max-x" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.05, 0.0 }, .p3 = .{ 0.1, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.45, 0.0 }, .p3 = .{ 0.9, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.25, 0.0 }, .p3 = .{ 0.5, 0.0 } },
    };
    var result = try partition(allocator, curves);
    defer result.deinit(allocator);

    var found_band: ?[]u32 = null;
    for (result.horizontal_bands) |candidate| {
        if (candidate.len == 3) found_band = candidate;
    }
    const matching_band = found_band orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(1, matching_band[0]);
    try std.testing.expectEqual(2, matching_band[1]);
    try std.testing.expectEqual(0, matching_band[2]);
}

test "partition empty curves returns sentinel band" {
    const allocator = std.testing.allocator;
    var result = try partition(allocator, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(0, result.band_index_max[0]);
    try std.testing.expectEqual(1, result.horizontal_bands.len);
    try std.testing.expectEqual(0, result.horizontal_bands[0].len);
}
