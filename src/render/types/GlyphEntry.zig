const std = @import("std");

/// One glyph store slot as the Slug shaders read it: ink bounds and band transform in
/// ems, then where the glyph's blob and point stream start in the word buffer.
pub const GlyphEntry = extern struct {
    bounds: [4]f32,
    band: [4]f32,
    blob: u32,
    points: u32,
    band_max: u32,
    flags: u32 = 0,

    pub const empty: GlyphEntry = .{ .bounds = @splat(0), .band = @splat(0), .blob = 0, .points = 0, .band_max = 0 };
};

comptime {
    std.debug.assert(@sizeOf(GlyphEntry) == 48);
}
