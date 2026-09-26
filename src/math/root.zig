const std = @import("std");

pub const Rect = @import("Rect.zig");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

fn Child(comptime T: type) type {
    return @typeInfo(T).vector.child;
}

pub fn Vec(comptime N: usize, comptime T: type) type {
    return @Vector(N, T);
}

pub fn vec2(x: f32, y: f32) Vec2 {
    return .{ x, y };
}

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub fn vec4(x: f32, y: f32, z: f32, w: f32) Vec4 {
    return .{ x, y, z, w };
}

pub fn splat(comptime V: type, value: Child(V)) V {
    return @splat(value);
}

pub fn dot(a: anytype, b: @TypeOf(a)) Child(@TypeOf(a)) {
    return @reduce(.Add, a * b);
}

pub fn lengthSq(v: anytype) Child(@TypeOf(v)) {
    return dot(v, v);
}

pub fn length(v: anytype) Child(@TypeOf(v)) {
    return @sqrt(lengthSq(v));
}

pub fn distance(a: anytype, b: @TypeOf(a)) Child(@TypeOf(a)) {
    return length(b - a);
}

pub fn normalize(v: anytype) @TypeOf(v) {
    return v / @as(@TypeOf(v), @splat(length(v)));
}

pub fn lerp(a: anytype, b: @TypeOf(a), t: anytype) @TypeOf(a) {
    if (@typeInfo(@TypeOf(a)) == .vector and @typeInfo(@TypeOf(t)) != .vector) {
        const tv: @TypeOf(a) = @splat(t);
        return a + (b - a) * tv;
    }
    return a + (b - a) * t;
}

pub fn saturate(v: anytype) @TypeOf(v) {
    return std.math.clamp(v, @as(@TypeOf(v), @splat(0)), @as(@TypeOf(v), @splat(1)));
}

pub fn select(mask: anytype, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(Child(@TypeOf(a)), mask, a, b);
}

pub fn cross2(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

pub fn isZero(v: anytype) bool {
    return @reduce(.And, v == @as(@TypeOf(v), @splat(0)));
}

pub const Ease = enum {
    smooth_step,
    ease_out_cubic,

    pub fn eval(self: Ease, t: f32) f32 {
        return switch (self) {
            .smooth_step => t * t * (3.0 - 2.0 * t),
            .ease_out_cubic => blk: {
                const u = 1.0 - t;
                break :blk 1.0 - u * u * u;
            },
        };
    }
};
