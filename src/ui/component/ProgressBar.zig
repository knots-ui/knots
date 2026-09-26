const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const Element = @import("layout").Element;

progress: f32,
key: Key,
style: *const Style = &.{},
parts: Parts = .{},

/// Style scopes drawn inside the single range decoration.
pub const Parts = struct {
    /// `background`, `radius`, `height`.
    track: *const Style = &.{},
    /// `background`; shares the track radius.
    fill: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{ .width = .grow(), .height = .fixed(8) };
    pub const track: Style = .{ .background = .toned, .radius = .{ .fixed = 4 } };
    pub const fill: Style = .{ .background = .accent };
};

const ProgressBar = @This();

pub fn open(self: *const ProgressBar, frame: *Frame) !Element.Id {
    const ui = frame.ui();
    const root = ui.resolveStyle(self.key.hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
    const track = ui.resolveStyle(self.key.indexed(1).hash(), .{ .base = &base.track, .user = self.parts.track }, .{}, null);
    const fill = ui.resolveStyle(self.key.indexed(2).hash(), .{ .base = &base.fill, .user = self.parts.fill }, .{}, null);
    return try ui.openWith(self.key, root.element(.{}), .{ .range = .{
        .progress = self.progress,
        .track_color = track.surface.color,
        .fill_color = fill.surface.color,
        .corner_radius = track.surface.corner_radius,
        .track_height = if (track.layout.height.kind == .fixed) track.layout.height.value else null,
    } }, .{ .content = root.content });
}

pub fn close(_: *const ProgressBar, frame: *Frame) !void {
    frame.ui().close();
}
