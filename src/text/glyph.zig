/// A glyph's slot in the glyph store, plus its ink box in ems for culling.
pub const GlyphRecord = struct {
    slot: u32,
    bounds_em_min: [2]f32,
    bounds_em_max: [2]f32,

    pub const empty = GlyphRecord{ .slot = 0, .bounds_em_min = .{ 0, 0 }, .bounds_em_max = .{ 0, 0 } };

    pub fn isEmpty(self: GlyphRecord) bool {
        return self.slot == 0;
    }
};
