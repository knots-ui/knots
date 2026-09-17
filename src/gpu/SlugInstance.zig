const std = @import("std");

pub const SlugInstance = extern struct {
    bounds: [4]f32,
    origin_size: [4]f32,
    glyph: [2]f32,
    bnd: [4]f32,
    col: [4]f32,
    clip_node: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 76);
        std.debug.assert(@alignOf(@This()) == @alignOf(f32));
    }
};
