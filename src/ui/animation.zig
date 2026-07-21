const std = @import("std");
const Element = @import("layout").Element;

pub const Ease = enum {
    smooth_step,
    ease_out_cubic,

    pub fn eval(self: Ease, t: f32) f32 {
        return switch (self) {
            .smooth_step => t * t * (3.0 - 2.0 * t),
            .ease_out_cubic => 1.0 - std.math.pow(f32, 1.0 - t, 3.0),
        };
    }
};

pub const Options = struct {
    duration_ms: u32 = 150,
    ease: Ease = .smooth_step,
};

pub fn channelId(widget_id: Element.Id, channel: []const u8) Element.Id {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&widget_id));
    hasher.update(channel);
    const final = hasher.final();
    return if (final == Element.INVALID_ID) final -% 1 else final;
}
