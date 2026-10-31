//! Drawing helpers shared by knots' own UI shaders.

const spirv = @import("spirv");
const Vec4f = spirv.Vec4f;
const Vec3f = spirv.Vec3f;
const Vec2f = spirv.Vec2f;
const smoothstep = spirv.smoothstep;

pub const ClipNode = extern struct {
    rect: Vec4f,
    radii: Vec4f,
    parent: u32,
    pad0: u32,
    pad1: u32,
    pad2: u32,
};

pub const ClipNodes = extern struct {
    clip_nodes: @SpirvType(.{ .runtime_array = ClipNode }),
};

pub const GlyphEntry = extern struct {
    bounds: Vec4f,
    band: Vec4f,
    blob: u32,
    points: u32,
    band_max: u32,
    flags: u32,
};

pub const GlyphTable = extern struct {
    entries: @SpirvType(.{ .runtime_array = GlyphEntry }),
};

pub const GlyphWords = extern struct {
    words: @SpirvType(.{ .runtime_array = u32 }),
};

pub fn sdRoundedBox(p: Vec2f, half_size: Vec2f, radii: Vec4f) f32 {
    const radius = cornerRadius(p, normalizedRadii(radii, half_size * @as(Vec2f, @splat(2.0))));
    const q = absVec2f(p) - half_size + @as(Vec2f, @splat(radius));
    const outside = @max(q, @as(Vec2f, @splat(0.0)));
    const outside_len = @sqrt(outside[0] * outside[0] + outside[1] * outside[1]);
    return outside_len + @min(@max(q[0], q[1]), 0.0) - radius;
}

pub inline fn clipAlpha(clip_nodes: anytype, world_pos: Vec2f, clip_node: f32) f32 {
    var idx: u32 = @intFromFloat(clip_node + 0.5);
    var alpha: f32 = 1.0;
    var i: u32 = 0;
    while (i < 32 and idx != 0) : (i += 1) {
        const node = clip_nodes.*.clip_nodes[idx];
        const half_size: Vec2f = .{ node.rect[2] * 0.5, node.rect[3] * 0.5 };
        const center: Vec2f = .{ node.rect[0] + half_size[0], node.rect[1] + half_size[1] };
        const d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha *= 1.0 - smoothstep(-0.5, 0.5, d);
        idx = node.parent;
    }
    return if (idx == 0) alpha else 0.0;
}

pub fn linearToSrgb(c: Vec3f) Vec3f {
    return .{ linearToSrgbChannel(c[0]), linearToSrgbChannel(c[1]), linearToSrgbChannel(c[2]) };
}

fn normalizedRadii(radii: Vec4f, size: Vec2f) Vec4f {
    var r = @max(radii, @as(Vec4f, @splat(0.0)));
    var scale: f32 = 1.0;
    if (r[0] + r[1] > size[0] and r[0] + r[1] > 0.0) scale = @min(scale, size[0] / (r[0] + r[1]));
    if (r[1] + r[2] > size[1] and r[1] + r[2] > 0.0) scale = @min(scale, size[1] / (r[1] + r[2]));
    if (r[2] + r[3] > size[0] and r[2] + r[3] > 0.0) scale = @min(scale, size[0] / (r[2] + r[3]));
    if (r[3] + r[0] > size[1] and r[3] + r[0] > 0.0) scale = @min(scale, size[1] / (r[3] + r[0]));
    r *= @as(Vec4f, @splat(scale));
    return r;
}

fn cornerRadius(p: Vec2f, radii: Vec4f) f32 {
    if (p[1] < 0.0) {
        return if (p[0] < 0.0) radii[0] else radii[1];
    }
    return if (p[0] >= 0.0) radii[2] else radii[3];
}

fn absVec2f(v: Vec2f) Vec2f {
    return .{ @abs(v[0]), @abs(v[1]) };
}

fn linearToSrgbChannel(c: f32) f32 {
    if (c <= 0.0031308) return 12.92 * c;
    return 1.055 * @exp(@log(c) * (1.0 / 2.4)) - 0.055;
}
