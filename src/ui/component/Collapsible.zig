const Frame = @import("../root.zig").Frame;

const Element = @import("layout").Element;
const ui = @import("../root.zig");

const COLLAPSIBLE_KEY_SALT: usize = 0x4001;

key: ui.Key,
open: bool,
animation: ui.animation.Options = .{
    .duration_ms = 250,
    .ease = .ease_out_cubic,
},
/// `width` of the clipped content.
style: *const ui.Style = &.{},

pub const base = struct {
    pub const root: ui.Style = .{ .width = .grow() };
};

const Collapsible = @This();

pub fn openContent(self: *const Collapsible, frame: *Frame) !bool {
    const measure_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 0);
    const tween_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 1);
    const clip_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 2);
    const measure_id = measure_key.hash();

    _ = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, measure_id);
    const measured_h: f32 = if (frame.ui().state.get(.measured, measure_id)) |s| s.height else 0;
    const target_h: f32 = if (self.open) measured_h else 0;
    const h = frame.ui().anim(tween_key.hash(), "h", target_h, self.animation);

    if (!self.open and h <= 0) return false;

    const need_remeasure = self.open and measured_h == 0;
    const clip_height: Element.sizing.Axis =
        if (need_remeasure) .fit() else .fixed(h);

    const resolved = frame.ui().resolveStyle(clip_key.hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
    const width = resolved.layout.width;
    _ = try frame.ui().openWith(clip_key, .{
        .width = width,
        .height = clip_height,
        .direction = .column,
        .overflow = .hidden,
    }, .none, .{ .content = resolved.content });
    _ = try frame.ui().open(measure_key, .{ .width = width }, .none);
    return true;
}

pub fn closeContent(_: *const Collapsible, frame: *Frame) void {
    frame.ui().close();
    frame.ui().close();
}
