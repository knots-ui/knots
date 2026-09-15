const Frame = @import("../Frame.zig");
const Element = @import("layout").Element;
const ui = @import("ui");

const COLLAPSIBLE_KEY_SALT: usize = 0x4001;

key: ui.Key,
open: bool,
animation: ui.animation.Options = .{
    .duration_ms = 250,
    .ease = .ease_out_cubic,
},
width: Element.sizing.Axis = .grow(),

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

    _ = try frame.ui().open(clip_key, .{
        .width = self.width,
        .height = clip_height,
        .direction = .column,
        .overflow = .hidden,
    }, .none);
    _ = try frame.ui().open(measure_key, .{ .width = self.width }, .none);
    return true;
}

pub fn closeContent(_: *const Collapsible, frame: *Frame) void {
    frame.ui().close();
    frame.ui().close();
}
