//! Reserve a UI region for a renderer-specific callback carried by the render contract.
const Frame = @import("../root.zig").Frame;

const render = @import("render");
const Element = @import("../root.zig").layout.Element;
const Key = @import("../root.zig").Key;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
interactive: bool = false,
paint: render.PaintCallback,
key: Key,

const GPUCanvas = @This();

pub fn open(self: *const GPUCanvas, frame: *Frame) !Element.Id {
    self.paint.validate();
    return frame.ui().open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
        .interactive = self.interactive,
    }, .none);
}

pub fn close(self: *const GPUCanvas, frame: *Frame) !void {
    self.paint.validate();
    frame.ui().setDecoration(frame.ui().currentSlot(), .{ .gpu_canvas = self.paint });
    frame.ui().close();
}
