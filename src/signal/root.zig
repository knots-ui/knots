const std = @import("std");

pub const Graph = @import("Graph.zig");
pub const Limits = @import("Limits.zig");
pub const Tracking = @import("Tracking.zig");

pub const Value = u64;

pub const Subscriber = packed struct(u32) {
    index: u24,
    generation: u8,
};

pub const Id = packed struct(u32) {
    index: u24,
    generation: u8,
};

comptime {
    std.debug.assert(@bitSizeOf(Subscriber) == 32);
    std.debug.assert(@bitSizeOf(Id) == 32);
}

test {
    _ = Graph;
}
