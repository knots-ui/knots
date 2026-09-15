const Frame = @import("../Frame.zig");
const Key = @import("ui").Key;
const Element = @import("layout").Element;

width: Element.sizing.Axis = .fixed(0),
height: Element.sizing.Axis = .fixed(0),
key: Key,

const Spacer = @This();

pub fn open(self: *const Spacer, frame: *Frame) !Element.Id {
    return try frame.ui().open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, .none);
}

pub fn close(_: *const Spacer, frame: *Frame) !void {
    frame.ui().close();
}
