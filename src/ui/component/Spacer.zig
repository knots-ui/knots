const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const Element = @import("layout").Element;

key: Key,
style: *const Style = &.{},

pub const base = struct {
    pub const root: Style = .{ .width = .fixed(0), .height = .fixed(0) };
};

const Spacer = @This();

pub fn open(self: *const Spacer, frame: *Frame) !Element.Id {
    return (try frame.ui().openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{}, .{})).id;
}

pub fn close(_: *const Spacer, frame: *Frame) !void {
    frame.ui().close();
}
