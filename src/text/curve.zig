const std = @import("std");
const TrueType = @import("TrueType");

pub const Curve = struct {
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

// Eight fixed segments avoid recursive, input-dependent subdivision work.
const cubic_subdivision_depth: u32 = 3;
const cubic_segment_count = 1 << cubic_subdivision_depth;

const Cubic = struct {
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

comptime {
    std.debug.assert(cubic_subdivision_depth > 0);
    std.debug.assert(cubic_segment_count == 8);
}

fn midpoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

fn splitCubic(cubic: Cubic) [2]Cubic {
    const p01 = midpoint(cubic.p0, cubic.p1);
    const p12 = midpoint(cubic.p1, cubic.p2);
    const p23 = midpoint(cubic.p2, cubic.p3);
    const p012 = midpoint(p01, p12);
    const p123 = midpoint(p12, p23);
    const p0123 = midpoint(p012, p123);

    return .{
        .{ .p0 = cubic.p0, .p1 = p01, .p2 = p012, .p3 = p0123 },
        .{ .p0 = p0123, .p1 = p123, .p2 = p23, .p3 = cubic.p3 },
    };
}

fn appendCubic(curves: *std.ArrayList(Curve), allocator: std.mem.Allocator, cubic: Cubic) !void {
    var segments: [cubic_segment_count]Cubic = undefined;
    var subdivisions: [cubic_segment_count]Cubic = undefined;
    segments[0] = cubic;

    var segment_count: u32 = 1;
    for (0..cubic_subdivision_depth) |_| {
        for (segments[0..segment_count], 0..) |segment, index| {
            const halves = splitCubic(segment);
            subdivisions[index * 2] = halves[0];
            subdivisions[index * 2 + 1] = halves[1];
        }

        segment_count *= 2;
        @memcpy(segments[0..segment_count], subdivisions[0..segment_count]);
    }

    std.debug.assert(segment_count == cubic_segment_count);
    try curves.ensureUnusedCapacity(allocator, cubic_segment_count);
    for (segments) |segment| {
        const control_start = [2]f32{
            (3.0 * segment.p1[0] - segment.p0[0]) * 0.5,
            (3.0 * segment.p1[1] - segment.p0[1]) * 0.5,
        };
        const control_end = [2]f32{
            (3.0 * segment.p2[0] - segment.p3[0]) * 0.5,
            (3.0 * segment.p2[1] - segment.p3[1]) * 0.5,
        };
        curves.appendAssumeCapacity(.{
            .p1 = segment.p0,
            .p2 = midpoint(control_start, control_end),
            .p3 = segment.p3,
        });
    }
}

pub fn decomposeVertices(allocator: std.mem.Allocator, vertices: []const TrueType.Vertex, units_per_em: f32) ![]Curve {
    std.debug.assert(std.math.isFinite(units_per_em));
    std.debug.assert(units_per_em > 0);

    const units_per_em_inverse = 1.0 / units_per_em;
    var curves: std.ArrayList(Curve) = .empty;
    errdefer curves.deinit(allocator);

    var current_point: [2]f32 = .{ 0, 0 };

    for (vertices) |vertex| {
        const point = [2]f32{
            @as(f32, @floatFromInt(vertex.x)) * units_per_em_inverse,
            @as(f32, @floatFromInt(vertex.y)) * units_per_em_inverse,
        };
        switch (vertex.type) {
            .vmove => {
                current_point = point;
            },
            .vline => {
                try curves.append(allocator, .{
                    .p1 = current_point,
                    .p2 = midpoint(current_point, point),
                    .p3 = point,
                });
                current_point = point;
            },
            .vcurve => {
                try curves.append(allocator, .{
                    .p1 = current_point,
                    .p2 = .{
                        @as(f32, @floatFromInt(vertex.cx)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy)) * units_per_em_inverse,
                    },
                    .p3 = point,
                });
                current_point = point;
            },
            .vcubic => {
                try appendCubic(&curves, allocator, .{
                    .p0 = current_point,
                    .p1 = .{
                        @as(f32, @floatFromInt(vertex.cx)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy)) * units_per_em_inverse,
                    },
                    .p2 = .{
                        @as(f32, @floatFromInt(vertex.cx1)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy1)) * units_per_em_inverse,
                    },
                    .p3 = point,
                });
                current_point = point;
            },
            else => {},
        }
    }

    return curves.toOwnedSlice(allocator);
}

test "decomposeVertices produces line as degenerate quadratic" {
    const allocator = std.testing.allocator;

    const vertices = [_]TrueType.Vertex{
        .{ .x = 0, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vmove },
        .{ .x = 1024, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 1024, .y = 1024, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 0, .y = 1024, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 0, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
    };

    const curves = try decomposeVertices(allocator, &vertices, 1024.0);
    defer allocator.free(curves);

    try std.testing.expectEqual(4, curves.len);

    for (curves) |curve| {
        const expected_midpoint = [2]f32{
            (curve.p1[0] + curve.p3[0]) * 0.5,
            (curve.p1[1] + curve.p3[1]) * 0.5,
        };
        try std.testing.expectApproxEqAbs(expected_midpoint[0], curve.p2[0], 1e-6);
        try std.testing.expectApproxEqAbs(expected_midpoint[1], curve.p2[1], 1e-6);
    }
}
