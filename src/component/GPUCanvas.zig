const Frame = @import("knots").Frame;
const gpu = @import("renderer").gpu;
const Element = @import("layout").Element;
const Key = @import("ui").Key;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
interactive: bool = false,
onDraw: gpu.DrawCallback,
user_data: ?*anyopaque = null,
key: Key,

const GPUCanvas = @This();

pub fn open(self: *const GPUCanvas, frame: *Frame) !Element.Id {
    return frame.ui().open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
        .interactive = self.interactive,
    }, .none);
}

pub fn close(self: *const GPUCanvas, frame: *Frame) !void {
    frame.ui().setDecoration(frame.ui().currentSlot(), .{ .gpu_canvas = .{
        .on_draw = @ptrCast(self.onDraw),
        .user_data = self.user_data,
    } });
    frame.ui().close();
}
