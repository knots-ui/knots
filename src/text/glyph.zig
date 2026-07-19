pub const GlyphRecord = struct {
    glyph_location_x: u16,
    glyph_location_y: u16,
    band_x_max: u8,
    band_y_max: u8,
    bounds_em_min: [2]f32,
    bounds_em_max: [2]f32,
    band_scale: [2]f32,
    band_offset: [2]f32,
    advance_em: f32,
    is_empty: bool,

    pub const empty = GlyphRecord{
        .glyph_location_x = 0,
        .glyph_location_y = 0,
        .band_x_max = 0,
        .band_y_max = 0,
        .bounds_em_min = .{ 0, 0 },
        .bounds_em_max = .{ 0, 0 },
        .band_scale = .{ 0, 0 },
        .band_offset = .{ 0, 0 },
        .advance_em = 0,
        .is_empty = true,
    };
};

pub const Shaped = struct {
    record: GlyphRecord,
    x: f32, // Pen position in screen pixels.
    advance: f32, // Glyph advance in screen pixels for cursor placement and hit-testing.
    cluster: u32, // Byte offset into the source UTF-8 text.
};

pub const ShapedView = struct {
    glyphs: []const Shaped,
    width: f32,
    ascender: f32,
};

pub const Line = struct {
    glyphs: []const Shaped,
    byte_start: u32,
    byte_end: u32,
    width: f32,
    y: f32,
};

pub const ShapedWrappedView = struct {
    lines: []const Line,
    width: f32,
    height: f32,
    ascender: f32,
    line_height: f32,
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    line_count: u32,
};
