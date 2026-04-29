const glyph = @import("text").glyph;

pub fn xAtByte(glyphs: []const glyph.Shaped, byte: u32, content_scale: f32) f32 {
    for (glyphs) |gl| {
        if (gl.cluster >= byte) return gl.x / content_scale;
    }
    if (glyphs.len == 0) return 0;
    const last = glyphs[glyphs.len - 1];
    return (last.x + last.advance) / content_scale;
}

pub const XRange = struct { lo: f32, hi: f32 };

pub fn xRangeAtBytes(glyphs: []const glyph.Shaped, lo: u32, hi: u32, content_scale: f32) XRange {
    if (glyphs.len == 0) return .{ .lo = 0, .hi = 0 };

    var x_lo: ?f32 = null;
    var x_hi: ?f32 = null;
    for (glyphs) |gl| {
        if (x_lo == null and gl.cluster >= lo) x_lo = gl.x / content_scale;
        if (x_hi == null and gl.cluster >= hi) {
            x_hi = gl.x / content_scale;
            break;
        }
    }
    const last = glyphs[glyphs.len - 1];
    const end_x = (last.x + last.advance) / content_scale;
    return .{
        .lo = x_lo orelse end_x,
        .hi = x_hi orelse end_x,
    };
}

pub fn byteOffsetAtX(glyphs: []const glyph.Shaped, content: []const u8, local_x: f32, content_scale: f32) u32 {
    if (glyphs.len == 0) return 0;
    for (glyphs) |gl| {
        const gx = gl.x / content_scale;
        const gw = gl.advance / content_scale;
        const mid = gx + gw * 0.5;
        if (local_x < mid) return gl.cluster;
    }
    return @intCast(content.len);
}
