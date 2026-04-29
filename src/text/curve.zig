const std = @import("std");
const ft = @import("freetype").c;

extern fn FT_Outline_Decompose(
    outline: *ft.FT_Outline,
    func_interface: *const ft.FT_Outline_Funcs,
    user: ?*anyopaque,
) c_int;

pub const Curve = struct {
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

const Builder = struct {
    curves: std.ArrayList(Curve),
    allocator: std.mem.Allocator,
    inv_units: f32,
    p_cur: [2]f32,
    p_start: [2]f32,
    err: ?anyerror,
};

fn vecToEm(v: *const ft.FT_Vector, inv_units: f32) [2]f32 {
    return .{
        @as(f32, @floatFromInt(v.x)) * inv_units,
        @as(f32, @floatFromInt(v.y)) * inv_units,
    };
}

fn moveToCb(to: [*c]const ft.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const b: *Builder = @ptrCast(@alignCast(user));
    const p = vecToEm(@ptrCast(to), b.inv_units);
    b.p_cur = p;
    b.p_start = p;
    return 0;
}

fn lineToCb(to: [*c]const ft.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const b: *Builder = @ptrCast(@alignCast(user));
    const p3 = vecToEm(@ptrCast(to), b.inv_units);
    const p1 = b.p_cur;
    const mp = [2]f32{ (p1[0] + p3[0]) * 0.5, (p1[1] + p3[1]) * 0.5 };
    b.curves.append(b.allocator, .{ .p1 = p1, .p2 = mp, .p3 = p3 }) catch |e| {
        b.err = e;
        return 1;
    };
    b.p_cur = p3;
    return 0;
}

fn conicToCb(c1: [*c]const ft.FT_Vector, to: [*c]const ft.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const b: *Builder = @ptrCast(@alignCast(user));
    const p2 = vecToEm(@ptrCast(c1), b.inv_units);
    const p3 = vecToEm(@ptrCast(to), b.inv_units);
    b.curves.append(b.allocator, .{ .p1 = b.p_cur, .p2 = p2, .p3 = p3 }) catch |e| {
        b.err = e;
        return 1;
    };
    b.p_cur = p3;
    return 0;
}

fn cubicToCb(c1: [*c]const ft.FT_Vector, c2: [*c]const ft.FT_Vector, to: [*c]const ft.FT_Vector, user: ?*anyopaque) callconv(.c) c_int {
    const b: *Builder = @ptrCast(@alignCast(user));
    const a_pt = b.p_cur;
    const b_pt = vecToEm(@ptrCast(c1), b.inv_units);
    const c_pt = vecToEm(@ptrCast(c2), b.inv_units);
    const d_pt = vecToEm(@ptrCast(to), b.inv_units);
    subdivideCubic(b, a_pt, b_pt, c_pt, d_pt, 3) catch |e| {
        b.err = e;
        return 1;
    };
    b.p_cur = d_pt;
    return 0;
}

fn lerp(a: [2]f32, c: [2]f32, t: f32) [2]f32 {
    return .{ a[0] + (c[0] - a[0]) * t, a[1] + (c[1] - a[1]) * t };
}

fn mid(a: [2]f32, c: [2]f32) [2]f32 {
    return .{ (a[0] + c[0]) * 0.5, (a[1] + c[1]) * 0.5 };
}

fn subdivideCubic(b: *Builder, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32, depth: u32) !void {
    if (depth == 0) {
        const q1 = [2]f32{ (3.0 * p1[0] - p0[0]) * 0.5, (3.0 * p1[1] - p0[1]) * 0.5 };
        const q2 = [2]f32{ (3.0 * p2[0] - p3[0]) * 0.5, (3.0 * p2[1] - p3[1]) * 0.5 };
        const qm = mid(q1, q2);
        try b.curves.append(b.allocator, .{ .p1 = p0, .p2 = qm, .p3 = p3 });
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p23 = mid(p2, p3);
    const p012 = mid(p01, p12);
    const p123 = mid(p12, p23);
    const p0123 = mid(p012, p123);
    try subdivideCubic(b, p0, p01, p012, p0123, depth - 1);
    try subdivideCubic(b, p0123, p123, p23, p3, depth - 1);
}

pub fn decomposeOutline(
    outline: *const ft.FT_Outline,
    units_per_em: f32,
    allocator: std.mem.Allocator,
) ![]Curve {
    const inv_units = 1.0 / units_per_em;
    var b = Builder{
        .curves = .empty,
        .allocator = allocator,
        .inv_units = inv_units,
        .p_cur = .{ 0, 0 },
        .p_start = .{ 0, 0 },
        .err = null,
    };
    errdefer b.curves.deinit(allocator);

    const funcs = ft.FT_Outline_Funcs{
        .move_to = &moveToCb,
        .line_to = &lineToCb,
        .conic_to = &conicToCb,
        .cubic_to = &cubicToCb,
        .shift = 0,
        .delta = 0,
    };

    const rc = FT_Outline_Decompose(@constCast(outline), &funcs, &b);
    if (rc != 0) return b.err orelse error.OutlineDecomposeFailed;

    return b.curves.toOwnedSlice(allocator);
}

test "decomposeOutline produces line as degenerate quadratic" {
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

    const curves = try decomposeOutline(&outline, 1024.0, allocator);
    defer allocator.free(curves);

    try std.testing.expectEqual(4, curves.len);

    for (curves) |cv| {
        const expected_mid = [2]f32{ (cv.p1[0] + cv.p3[0]) * 0.5, (cv.p1[1] + cv.p3[1]) * 0.5 };
        try std.testing.expectApproxEqAbs(expected_mid[0], cv.p2[0], 1e-6);
        try std.testing.expectApproxEqAbs(expected_mid[1], cv.p2[1], 1e-6);
    }
}
