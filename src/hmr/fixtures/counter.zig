const std = @import("std");
const knots = @import("knots");

pub const id = "test/counter";
pub const path = "counter.zig";
pub const text = @embedFile("counter.zig");

pub const source = struct {
    var frames: u32 = 0;
    pub fn main(frame: *knots.Frame) !void {
        std.debug.assert(frames < 1000);
        std.debug.assert(frame.input().logical_extent.width > 0);
        if (frames == 0) {
            if (frame.input().logical_extent.width == 13) return error.RejectedInitialExtent;
        }
        frames += 1;
        try frame.e(knots.component.Rect{
            .key = .str("counter"),
            .style = &.{ .width = .fixed(@floatFromInt(frames)), .height = .fixed(10), .background = .primary },
        });
    }
};
