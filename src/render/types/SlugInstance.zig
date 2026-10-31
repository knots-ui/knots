const std = @import("std");

/// One glyph quad. Bounds and band data come from the glyph store's slot table.
pub const SlugInstance = extern struct {
    origin: [2]f32,
    /// Logical pixels per em.
    size: f32,
    slot: u32,
    col: [4]f16,
    clip_node: f32 = 0,
    _pad: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
        std.debug.assert(@alignOf(@This()) == @alignOf(f32));
    }
};
