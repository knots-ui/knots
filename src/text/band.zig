const std = @import("std");
const Curve = @import("curve.zig").Curve;

const BAND_EPSILON: f32 = 1.0 / 65536.0;
const MAX_BANDS: u32 = 16;

pub const PartitionResult = struct {
    band_max: [2]u8,
    band_scale: [2]f32,
    band_offset: [2]f32,
    h_bands: [][]u32,
    v_bands: [][]u32,
    bbox_min: [2]f32,
    bbox_max: [2]f32,

    pub fn deinit(self: *PartitionResult, allocator: std.mem.Allocator) void {
        for (self.h_bands) |b| allocator.free(b);
        for (self.v_bands) |b| allocator.free(b);
        allocator.free(self.h_bands);
        allocator.free(self.v_bands);
    }
};

fn curveExtent(c: Curve, axis: u1) [2]f32 {
    const x1 = c.p1[axis];
    const x2 = c.p2[axis];
    const x3 = c.p3[axis];
    return .{ @min(@min(x1, x2), x3), @max(@max(x1, x2), x3) };
}

const SortCtx = struct {
    curves: []const Curve,
    axis: u1,

    pub fn lessThan(self: SortCtx, a: u32, b: u32) bool {
        const ext_a = curveExtent(self.curves[a], self.axis);
        const ext_b = curveExtent(self.curves[b], self.axis);
        return ext_a[1] > ext_b[1];
    }
};

pub fn partition(curves: []const Curve, allocator: std.mem.Allocator) !PartitionResult {
    if (curves.len == 0) {
        const empty_h = try allocator.alloc([]u32, 1);
        empty_h[0] = try allocator.alloc(u32, 0);
        const empty_v = try allocator.alloc([]u32, 1);
        empty_v[0] = try allocator.alloc(u32, 0);
        return .{
            .band_max = .{ 0, 0 },
            .band_scale = .{ 0, 0 },
            .band_offset = .{ 0, 0 },
            .h_bands = empty_h,
            .v_bands = empty_v,
            .bbox_min = .{ 0, 0 },
            .bbox_max = .{ 0, 0 },
        };
    }

    var bbox_min = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var bbox_max = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for (curves) |c| {
        inline for ([_][2]f32{ c.p1, c.p2, c.p3 }) |p| {
            bbox_min[0] = @min(bbox_min[0], p[0]);
            bbox_min[1] = @min(bbox_min[1], p[1]);
            bbox_max[0] = @max(bbox_max[0], p[0]);
            bbox_max[1] = @max(bbox_max[1], p[1]);
        }
    }

    const cnt_f: f32 = @floatFromInt(curves.len);
    const raw_count: u32 = @intFromFloat(@round(cnt_f / 4.0));
    const band_count_x: u32 = @max(1, @min(raw_count, MAX_BANDS));
    const band_count_y: u32 = band_count_x;

    var span_x = bbox_max[0] - bbox_min[0];
    var span_y = bbox_max[1] - bbox_min[1];
    if (span_x <= 0) span_x = 1;
    if (span_y <= 0) span_y = 1;

    const band_scale = [2]f32{
        @as(f32, @floatFromInt(band_count_x)) / span_x,
        @as(f32, @floatFromInt(band_count_y)) / span_y,
    };
    const band_offset = [2]f32{
        -bbox_min[0] * band_scale[0],
        -bbox_min[1] * band_scale[1],
    };

    const h_bands = try allocator.alloc([]u32, band_count_y);
    errdefer allocator.free(h_bands);
    const v_bands = try allocator.alloc([]u32, band_count_x);
    errdefer allocator.free(v_bands);

    try fillBands(curves, allocator, h_bands, bbox_min[1], span_y, band_count_y, 1, 0);
    try fillBands(curves, allocator, v_bands, bbox_min[0], span_x, band_count_x, 0, 1);

    return .{
        .band_max = .{
            @intCast(band_count_x - 1),
            @intCast(band_count_y - 1),
        },
        .band_scale = band_scale,
        .band_offset = band_offset,
        .h_bands = h_bands,
        .v_bands = v_bands,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
    };
}

fn fillBands(
    curves: []const Curve,
    allocator: std.mem.Allocator,
    bands: [][]u32,
    origin: f32,
    span: f32,
    band_count: u32,
    slab_axis: u1,
    sort_axis: u1,
) !void {
    const h: f32 = span / @as(f32, @floatFromInt(band_count));

    var tmp: std.ArrayList(u32) = .empty;
    defer tmp.deinit(allocator);

    var filled: u32 = 0;
    errdefer {
        for (0..filled) |i| allocator.free(bands[i]);
    }

    for (0..band_count) |bi| {
        const lo = origin + @as(f32, @floatFromInt(bi)) * h - BAND_EPSILON;
        const hi = origin + @as(f32, @floatFromInt(bi + 1)) * h + BAND_EPSILON;

        tmp.clearRetainingCapacity();
        for (curves, 0..) |c, idx| {
            const ext = curveExtent(c, slab_axis);
            if (ext[1] >= lo and ext[0] <= hi) {
                try tmp.append(allocator, @intCast(idx));
            }
        }

        const ctx = SortCtx{ .curves = curves, .axis = sort_axis };
        std.mem.sort(u32, tmp.items, ctx, SortCtx.lessThan);

        bands[bi] = try allocator.dupe(u32, tmp.items);
        filled += 1;
    }
}

test "partition single horizontal line yields one band" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0, 0.5 }, .p2 = .{ 0.5, 0.5 }, .p3 = .{ 1, 0.5 } },
    };
    var res = try partition(curves, allocator);
    defer res.deinit(allocator);

    try std.testing.expectEqual(0, res.band_max[0]);
    try std.testing.expectEqual(0, res.band_max[1]);
    try std.testing.expectEqual(1, res.h_bands.len);
    try std.testing.expectEqual(1, res.h_bands[0].len);
    try std.testing.expectEqual(0, res.h_bands[0][0]);
}

test "partition sorts within band by descending max-x" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.05, 0.0 }, .p3 = .{ 0.1, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.45, 0.0 }, .p3 = .{ 0.9, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.25, 0.0 }, .p3 = .{ 0.5, 0.0 } },
    };
    var res = try partition(curves, allocator);
    defer res.deinit(allocator);

    var found_band: ?[]u32 = null;
    for (res.h_bands) |b| {
        if (b.len == 3) found_band = b;
    }
    const band = found_band orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(1, band[0]);
    try std.testing.expectEqual(2, band[1]);
    try std.testing.expectEqual(0, band[2]);
}

test "partition empty curves returns sentinel band" {
    const allocator = std.testing.allocator;
    var res = try partition(&[_]Curve{}, allocator);
    defer res.deinit(allocator);
    try std.testing.expectEqual(0, res.band_max[0]);
    try std.testing.expectEqual(1, res.h_bands.len);
    try std.testing.expectEqual(0, res.h_bands[0].len);
}
