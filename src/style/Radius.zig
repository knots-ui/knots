const Theme = @import("Theme.zig");

pub const Input = union(enum) {
    pub const Corner = union(enum) {
        none,
        xs,
        sm,
        md,
        lg,
        xl,
        fixed: f32,

        inline fn resolve(self: Corner, theme: *const Theme, index: usize) f32 {
            return switch (self) {
                .none => 0,
                .xs => theme.radius.value[index] * 0.25,
                .sm => theme.radius.value[index] * 0.5,
                .md => theme.radius.value[index],
                .lg => theme.radius.value[index] * 1.5,
                .xl => theme.radius.value[index] * 2.0,
                .fixed => |v| v,
            };
        }
    };

    none,
    xs,
    sm,
    md,
    lg,
    xl,
    fixed: f32,
    radius: Radius,
    corners: [4]Corner,

    pub fn resolve(self: Input, theme: *const Theme) Radius {
        return switch (self) {
            .none => .zero,
            .xs => theme.radius.scale(0.25),
            .sm => theme.radius.scale(0.5),
            .md => theme.radius,
            .lg => theme.radius.scale(1.5),
            .xl => theme.radius.scale(2.0),
            .fixed => |v| Radius.all(v),
            .radius => |r| r,
            .corners => |v| Radius.corners(
                v[0].resolve(theme, 0),
                v[1].resolve(theme, 1),
                v[2].resolve(theme, 2),
                v[3].resolve(theme, 3),
            ),
        };
    }
};

value: [4]f32,

const Radius = @This();

pub const zero: Radius = .{ .value = .{ 0, 0, 0, 0 } };

pub fn all(v: f32) Radius {
    return .{ .value = .{ v, v, v, v } };
}

pub fn corners(tl: f32, tr: f32, br: f32, bl: f32) Radius {
    return .{ .value = .{ tl, tr, br, bl } };
}

pub fn scale(self: Radius, factor: f32) Radius {
    return .{ .value = .{
        self.value[0] * factor,
        self.value[1] * factor,
        self.value[2] * factor,
        self.value[3] * factor,
    } };
}

pub fn shrink(self: Radius, amount: f32) Radius {
    return .{ .value = .{
        @max(0, self.value[0] - amount),
        @max(0, self.value[1] - amount),
        @max(0, self.value[2] - amount),
        @max(0, self.value[3] - amount),
    } };
}

pub fn lerp(a: Radius, b: Radius, t: f32) Radius {
    return .{ .value = .{
        a.value[0] + (b.value[0] - a.value[0]) * t,
        a.value[1] + (b.value[1] - a.value[1]) * t,
        a.value[2] + (b.value[2] - a.value[2]) * t,
        a.value[3] + (b.value[3] - a.value[3]) * t,
    } };
}

pub fn isZero(self: Radius) bool {
    return self.value[0] == 0 and self.value[1] == 0 and self.value[2] == 0 and self.value[3] == 0;
}
