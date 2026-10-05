const std = @import("std");
const knots = @import("knots");

var frames: u32 = 0;

pub fn main(frame: *knots.Frame) !void {
    std.debug.assert(frames < 1000);
    std.debug.assert(frame.input().logical_extent.width > 0);
    if (frame.input().logical_extent.width == 7) return error.RejectedExtent;
    frames += 1;
    try frame.e(knots.component.Rect{
        .key = .str("counter"),
        .style = &.{ .width = .fixed(@floatFromInt(frames)), .height = .fixed(10), .background = .primary },
    });
}
