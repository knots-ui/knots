pub const Key = struct {
    codepoint: u32,
    size_px: u32, // fixed-point: actual_size * 64
};

pub const Metrics = struct {
    rect: Rect,
    bearing_x: f32,
    bearing_y: f32,
    advance: f32,
};

pub const Shaped = struct {
    metrics: Metrics,
    x: f32, // pen position
    y: f32,
    cluster: u32, // byte offset into source UTF-8 text
};

pub const ShapedKey = struct {
    text: []const u8,
    size_q: u32,
};

pub const ShapedEntry = struct {
    glyphs: []Shaped,
    width: f32,
    ascender: f32,
    last_used_frame: u32,
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

pub const Rect = struct {
    u: f32,
    v: f32,
    uw: f32,
    uh: f32,
    width: f32,
    height: f32,
};
