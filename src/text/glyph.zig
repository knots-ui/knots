pub const GlyphRecord = struct {
    glyph_loc_x: u16,
    glyph_loc_y: u16,
    band_max_x: u8,
    band_max_y: u8,
    flags: u8,
    em_min: [2]f32,
    em_max: [2]f32,
    band_scale: [2]f32,
    band_offset: [2]f32,
    advance_em: f32,
    bearing_em: [2]f32,
    is_empty: bool,
};

pub const Shaped = struct {
    record: GlyphRecord,
    x: f32, // pen position in screen px
    advance: f32, // glyph advance in screen px (for cursor / hit-testing)
    cluster: u32, // byte offset into source UTF-8 text
};

pub const ShapedView = struct {
    glyphs: []const Shaped,
    width: f32,
    ascender: f32,
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    line_count: u32,
};
