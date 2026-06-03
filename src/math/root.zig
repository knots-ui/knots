const std = @import("std");

pub const Rect = @import("Rect.zig");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

fn Child(comptime T: type) type {
    return @typeInfo(T).vector.child;
}

pub inline fn Vec(comptime N: usize, comptime T: type) type {
    return @Vector(N, T);
}

pub inline fn vec2(x: f32, y: f32) Vec2 {
    return .{ x, y };
}

pub inline fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub inline fn vec4(x: f32, y: f32, z: f32, w: f32) Vec4 {
    return .{ x, y, z, w };
}

pub inline fn splat(comptime V: type, value: Child(V)) V {
    return @splat(value);
}

pub inline fn dot(a: anytype, b: @TypeOf(a)) Child(@TypeOf(a)) {
    return @reduce(.Add, a * b);
}

pub inline fn lengthSq(v: anytype) Child(@TypeOf(v)) {
    return dot(v, v);
}

pub inline fn length(v: anytype) Child(@TypeOf(v)) {
    return @sqrt(lengthSq(v));
}

pub inline fn distance(a: anytype, b: @TypeOf(a)) Child(@TypeOf(a)) {
    return length(b - a);
}

pub inline fn normalize(v: anytype) @TypeOf(v) {
    return v / @as(@TypeOf(v), @splat(length(v)));
}

pub inline fn lerp(a: anytype, b: @TypeOf(a), t: anytype) @TypeOf(a) {
    if (@typeInfo(@TypeOf(a)) == .vector and @typeInfo(@TypeOf(t)) != .vector) {
        const tv: @TypeOf(a) = @splat(t);
        return a + (b - a) * tv;
    }
    return a + (b - a) * t;
}

pub inline fn saturate(v: anytype) @TypeOf(v) {
    return std.math.clamp(v, @as(@TypeOf(v), @splat(0)), @as(@TypeOf(v), @splat(1)));
}

pub inline fn select(mask: anytype, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(Child(@TypeOf(a)), mask, a, b);
}

pub inline fn cross2(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

pub inline fn isZero(v: anytype) bool {
    return @reduce(.And, v == @as(@TypeOf(v), @splat(0)));
}
