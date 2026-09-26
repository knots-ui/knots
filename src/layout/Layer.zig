//! Typed form of `Element.Config.z_index`.
const std = @import("std");

z: u8,

const Layer = @This();

pub const count: usize = 256;

pub const base: Layer = .{ .z = 0 };
pub const dropdown: Layer = .{ .z = 1 };
pub const popup: Layer = .{ .z = 10 };
pub const modal: Layer = .{ .z = 200 };

pub fn fromIndex(i: usize) Layer {
    std.debug.assert(i < count);
    return .{ .z = @intCast(i) };
}

pub fn index(self: Layer) u8 {
    return self.z;
}

pub fn above(self: Layer, other: Layer) bool {
    return self.z > other.z;
}

pub fn eql(self: Layer, other: Layer) bool {
    return self.z == other.z;
}

pub fn max(a: Layer, b: Layer) Layer {
    return if (a.z >= b.z) a else b;
}
