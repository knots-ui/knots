value: [4]f32,

const BorderWidth = @This();

pub const zero: BorderWidth = .{ .value = .{ 0, 0, 0, 0 } };

pub fn all(v: f32) BorderWidth {
    const w = @max(0, v);
    return .{ .value = .{ w, w, w, w } };
}

pub fn edges(top: f32, right: f32, bottom: f32, left: f32) BorderWidth {
    return .{ .value = .{
        @max(0, top),
        @max(0, right),
        @max(0, bottom),
        @max(0, left),
    } };
}

pub fn isZero(self: BorderWidth) bool {
    return self.value[0] == 0 and self.value[1] == 0 and self.value[2] == 0 and self.value[3] == 0;
}

pub fn max(self: BorderWidth) f32 {
    return @max(@max(self.value[0], self.value[1]), @max(self.value[2], self.value[3]));
}

pub fn lerp(a: BorderWidth, b: BorderWidth, t: f32) BorderWidth {
    return edges(
        a.value[0] + (b.value[0] - a.value[0]) * t,
        a.value[1] + (b.value[1] - a.value[1]) * t,
        a.value[2] + (b.value[2] - a.value[2]) * t,
        a.value[3] + (b.value[3] - a.value[3]) * t,
    );
}
