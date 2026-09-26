const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Style = ui_mod.Style;
const Key = ui_mod.Key;
const Element = @import("layout").Element;
const Grid = @import("layout").Grid;

pub const GridTrack = Grid.Track;
pub const GridTemplate = Grid.Template;
pub const GridPlacement = Grid.Placement;

key: Key,
style: *const Style = &.{},

pub const base = struct {
    pub const root: Style = .{};
};

const Rect = @This();

pub fn open(self: *const Rect, frame: *Frame) !Element.Id {
    return (try frame.ui().openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{}, .{})).id;
}

pub fn close(_: *const Rect, frame: *Frame) !void {
    frame.ui().close();
}
