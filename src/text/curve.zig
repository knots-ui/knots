const std = @import("std");
const TrueType = @import("TrueType");

pub const Curve = struct {
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

fn mid(a: [2]f32, c: [2]f32) [2]f32 {
    return .{ (a[0] + c[0]) * 0.5, (a[1] + c[1]) * 0.5 };
}

fn subdivideCubic(
    curves: *std.ArrayList(Curve),
    allocator: std.mem.Allocator,
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
    depth: u32,
) !void {
    if (depth == 0) {
        const q1 = [2]f32{ (3.0 * p1[0] - p0[0]) * 0.5, (3.0 * p1[1] - p0[1]) * 0.5 };
        const q2 = [2]f32{ (3.0 * p2[0] - p3[0]) * 0.5, (3.0 * p2[1] - p3[1]) * 0.5 };
        const qm = mid(q1, q2);
        try curves.append(allocator, .{ .p1 = p0, .p2 = qm, .p3 = p3 });
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p23 = mid(p2, p3);
    const p012 = mid(p01, p12);
    const p123 = mid(p12, p23);
    const p0123 = mid(p012, p123);
    try subdivideCubic(curves, allocator, p0, p01, p012, p0123, depth - 1);
    try subdivideCubic(curves, allocator, p0123, p123, p23, p3, depth - 1);
}

pub fn decomposeVertices(
    allocator: std.mem.Allocator,
    vertices: []const TrueType.Vertex,
    units_per_em: f32,
) ![]Curve {
    const inv_units = 1.0 / units_per_em;
    var curves: std.ArrayList(Curve) = .empty;
    errdefer curves.deinit(allocator);

    var p_cur: [2]f32 = .{ 0, 0 };

    for (vertices) |v| {
        const x = @as(f32, @floatFromInt(v.x)) * inv_units;
        const y = @as(f32, @floatFromInt(v.y)) * inv_units;
        switch (v.type) {
            .vmove => {
                p_cur = .{ x, y };
            },
            .vline => {
                const p3: [2]f32 = .{ x, y };
                try curves.append(allocator, .{ .p1 = p_cur, .p2 = mid(p_cur, p3), .p3 = p3 });
                p_cur = p3;
            },
            .vcurve => {
                const cx = @as(f32, @floatFromInt(v.cx)) * inv_units;
                const cy = @as(f32, @floatFromInt(v.cy)) * inv_units;
                const p3: [2]f32 = .{ x, y };
                try curves.append(allocator, .{ .p1 = p_cur, .p2 = .{ cx, cy }, .p3 = p3 });
                p_cur = p3;
            },
            .vcubic => {
                const cx = @as(f32, @floatFromInt(v.cx)) * inv_units;
                const cy = @as(f32, @floatFromInt(v.cy)) * inv_units;
                const cx1 = @as(f32, @floatFromInt(v.cx1)) * inv_units;
                const cy1 = @as(f32, @floatFromInt(v.cy1)) * inv_units;
                const p3: [2]f32 = .{ x, y };
                try subdivideCubic(&curves, allocator, p_cur, .{ cx, cy }, .{ cx1, cy1 }, p3, 3);
                p_cur = p3;
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

    for (curves) |cv| {
        const expected_mid = [2]f32{ (cv.p1[0] + cv.p3[0]) * 0.5, (cv.p1[1] + cv.p3[1]) * 0.5 };
        try std.testing.expectApproxEqAbs(expected_mid[0], cv.p2[0], 1e-6);
        try std.testing.expectApproxEqAbs(expected_mid[1], cv.p2[1], 1e-6);
    }
}
