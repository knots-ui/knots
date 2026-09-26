//! Reserve a UI region for a renderer-specific callback carried by the render contract.
const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const Style = ui_mod.Style;

const render = @import("render");
const Element = @import("layout").Element;

paint: render.PaintCallback,
interactive: bool = false,
key: Key,
style: *const Style = &.{},

pub const base = struct {
    pub const root: Style = .{ .width = .grow(), .height = .grow(), .overflow = .hidden };
};

const GPUCanvas = @This();

pub fn open(self: *const GPUCanvas, frame: *Frame) !Element.Id {
    self.paint.validate();
    const ui = frame.ui();
    const resolved = ui.resolveStyle(self.key.hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
    return ui.openWith(self.key, resolved.element(.{ .interactive = self.interactive }), .none, .{ .content = resolved.content });
}

pub fn close(self: *const GPUCanvas, frame: *Frame) !void {
    self.paint.validate();
    frame.ui().setDecoration(frame.ui().currentSlot(), .{ .gpu_canvas = self.paint });
    frame.ui().close();
}
