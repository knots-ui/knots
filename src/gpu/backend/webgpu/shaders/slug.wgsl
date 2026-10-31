// WGSL port of the Slug analytic font rendering algorithm.
// Reference: https://github.com/EricLengyel/Slug/tree/main

struct Uniforms {
    mvp_row0: vec4f,
    mvp_row1: vec4f,
    mvp_row2: vec4f,
    mvp_row3: vec4f,
    viewport: vec4f,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
struct GlyphEntry {
    bounds: vec4f,
    band: vec4f,
    blob: u32,
    points: u32,
    band_max: u32,
    flags: u32,
};

@group(1) @binding(0) var<storage, read> glyph_table: array<GlyphEntry>;
@group(1) @binding(1) var<storage, read> glyph_words: array<u32>;

struct ClipNode {
    rect: vec4f,
    radii: vec4f,
    parent: u32,
    pad0: u32,
    pad1: u32,
    pad2: u32,
}

@group(2) @binding(0)
var<storage, read> clip_nodes: array<ClipNode>;

const MAX_CLIP_DEPTH: u32 = 32u;

struct VsIn {
    @location(0) origin: vec2f,
    @location(1) size: f32,
    @location(2) slot: u32,
    @location(3) col: vec4f,
    @location(4) clip_node: f32,
};

struct VsOut {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
    @location(1) texcoord: vec2f,
    @interpolate(flat) @location(2) banding: vec4f,
    @interpolate(flat) @location(3) glyph: vec4u,
    @interpolate(flat) @location(4) quant: vec4f,
    @location(5) world_pos: vec2f,
    @location(6) clip_node: f32,
};

fn slug_dilate(
    pos: vec4f,
    tex: vec4f,
    jac: vec4f,
    m0: vec4f,
    m1: vec4f,
    m3: vec4f,
    dim: vec2f,
) -> vec4f {
    let n = normalize(pos.zw);
    let s = dot(m3.xy, pos.xy) + m3.w;
    let t = dot(m3.xy, n);

    let u_ = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    let v_ = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    let s2 = s * s;
    let st = s * t;
    let uv = u_ * u_ + v_ * v_;
    let denom = max(uv - st * st, 1.0e-12);
    let d = pos.zw * (s2 * (st + sqrt(uv)) / denom);

    let vpos = pos.xy + d;
    let vtex = vec2f(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
    return vec4f(vpos, vtex);
}

@vertex
fn vs_main(in: VsIn, @builtin(vertex_index) index: u32) -> VsOut {
    let right = index == 1u || index == 2u;
    let bottom = index == 2u || index == 3u;
    let entry = glyph_table[in.slot];
    let em = vec2f(select(entry.bounds.x, entry.bounds.z, right), select(entry.bounds.w, entry.bounds.y, bottom));
    let normal = vec2f(select(-0.70710677, 0.70710677, right), select(-0.70710677, 0.70710677, bottom));
    let pos = vec4f(in.origin + em * vec2f(in.size, -in.size), normal);
    let tex = vec4f(em, 0.0, 0.0);
    let jac = vec4f(1.0 / in.size, 0.0, 0.0, -1.0 / in.size);
    let dilated = slug_dilate(pos, tex, jac, u.mvp_row0, u.mvp_row1, u.mvp_row3, u.viewport.zw);
    let p = dilated.xy;

    var out: VsOut;
    out.clip_pos = vec4f(
        p.x * u.mvp_row0.x + p.y * u.mvp_row0.y + u.mvp_row0.w,
        p.x * u.mvp_row1.x + p.y * u.mvp_row1.y + u.mvp_row1.w,
        p.x * u.mvp_row2.x + p.y * u.mvp_row2.y + u.mvp_row2.w,
        p.x * u.mvp_row3.x + p.y * u.mvp_row3.y + u.mvp_row3.w,
    );
    out.texcoord = dilated.zw;
    out.banding = entry.band;
    out.glyph = vec4u(entry.blob, entry.points, entry.band_max & 0xFFu, (entry.band_max >> 8u) & 0xFFu);
    out.quant = vec4f(entry.bounds.xy, (entry.bounds.zw - entry.bounds.xy) / 65535.0);
    out.color = in.col;
    out.world_pos = p;
    out.clip_node = in.clip_node;
    return out;
}

fn normalizedRadii(radii: vec4f, size: vec2f) -> vec4f {
    let r = max(radii, vec4f(0.0));
    var scale: f32 = 1.0;
    if r.x + r.y > size.x && r.x + r.y > 0.0 {
        scale = min(scale, size.x / (r.x + r.y));
    }
    if r.y + r.z > size.y && r.y + r.z > 0.0 {
        scale = min(scale, size.y / (r.y + r.z));
    }
    if r.z + r.w > size.x && r.z + r.w > 0.0 {
        scale = min(scale, size.x / (r.z + r.w));
    }
    if r.w + r.x > size.y && r.w + r.x > 0.0 {
        scale = min(scale, size.y / (r.w + r.x));
    }
    return r * scale;
}

fn cornerRadius(p: vec2f, radii: vec4f) -> f32 {
    if p.y < 0.0 {
        if p.x < 0.0 {
            return radii.x;
        }
        return radii.y;
    }
    if p.x >= 0.0 {
        return radii.z;
    }
    return radii.w;
}

fn sdRoundedBox(p: vec2f, half_size: vec2f, radii: vec4f) -> f32 {
    let r = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    let q = abs(p) - half_size + r;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fn clipAlpha(world_pos: vec2f, clip_node: f32) -> f32 {
    var idx = u32(clip_node + 0.5);
    var alpha = 1.0;
    for (var i: u32 = 0u; i < MAX_CLIP_DEPTH && idx != 0u; i = i + 1u) {
        let node = clip_nodes[idx];
        let half_size = node.rect.zw * 0.5;
        let center = node.rect.xy + half_size;
        let d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha = alpha * (1.0 - smoothstep(-0.5, 0.5, d));
        idx = node.parent;
    }
    if idx != 0u {
        return 0.0;
    }
    return alpha;
}

fn calc_root_code(y1: f32, y2: f32, y3: f32) -> u32 {
    let i1 = bitcast<u32>(y1) >> 31u;
    let i2 = bitcast<u32>(y2) >> 30u;
    let i3 = bitcast<u32>(y3) >> 29u;

    var shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return (0x2E74u >> shift) & 0x0101u;
}

fn solve_horiz_poly(p12: vec4f, p3: vec2f) -> vec2f {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.y;
    let rb = 0.5 / b.y;

    let d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    var t1 = (b.y - d) * ra;
    var t2 = (b.y + d) * ra;

    if abs(a.y) < 1.0 / 65536.0 {
        let tt = p12.y * rb;
        t1 = tt;
        t2 = tt;
    }

    return vec2f(
        (a.x * t1 - b.x * 2.0) * t1 + p12.x,
        (a.x * t2 - b.x * 2.0) * t2 + p12.x,
    );
}

fn solve_vert_poly(p12: vec4f, p3: vec2f) -> vec2f {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.x;
    let rb = 0.5 / b.x;

    let d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    var t1 = (b.x - d) * ra;
    var t2 = (b.x + d) * ra;

    if abs(a.x) < 1.0 / 65536.0 {
        let tt = p12.x * rb;
        t1 = tt;
        t2 = tt;
    }

    return vec2f(
        (a.y * t1 - b.y * 2.0) * t1 + p12.y,
        (a.y * t2 - b.y * 2.0) * t2 + p12.y,
    );
}

fn glyph_point(base: u32, index: u32, quant: vec4f) -> vec2f {
    let word = glyph_words[base + index];
    return quant.xy + vec2f(f32(word & 0xFFFFu), f32(word >> 16u)) * quant.zw;
}

fn band_curve(blob: u32, list: u32, i: u32) -> u32 {
    let word = glyph_words[blob + list + (i >> 1u)];
    return (word >> ((i & 1u) * 16u)) & 0xFFFFu;
}

fn calc_coverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) -> f32 {
    let combined = abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0);
    let alt = min(abs(xcov), abs(ycov));
    let cov = max(combined, alt);
    return clamp(cov, 0.0, 1.0);
}

fn slug_render(render_coord: vec2f, banding: vec4f, glyph_data: vec4u, quant: vec4f) -> f32 {
    let ems_per_pixel = fwidth(render_coord);
    let pixels_per_em = vec2f(1.0, 1.0) / ems_per_pixel;

    let band_max = vec2i(glyph_data.zw);
    var band_index = vec2i(render_coord * banding.xy + banding.zw);
    band_index = clamp(band_index, vec2i(0, 0), band_max);
    let blob = glyph_data.x;
    let points = blob + glyph_data.y;

    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;

    let hband = glyph_words[blob + u32(band_index.y)];
    let hcount = hband & 0xFFFFu;
    let hlist = hband >> 16u;

    for (var i: u32 = 0u; i < hcount; i = i + 1u) {
        let curve = points + band_curve(blob, hlist, i);
        let p1 = glyph_point(curve, 0u, quant) - render_coord;
        let p2 = glyph_point(curve, 1u, quant) - render_coord;
        let p3 = glyph_point(curve, 2u, quant) - render_coord;
        let p12 = vec4f(p1, p2);

        if max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5 {
            break;
        }

        let code = calc_root_code(p12.y, p12.w, p3.y);
        if code != 0u {
            let r = solve_horiz_poly(p12, p3) * pixels_per_em.x;
            if (code & 1u) != 0u {
                xcov = xcov + clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if code > 1u {
                xcov = xcov - clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;

    let vband = glyph_words[blob + u32(band_max.y + 1 + band_index.x)];
    let vcount = vband & 0xFFFFu;
    let vlist = vband >> 16u;

    for (var i: u32 = 0u; i < vcount; i = i + 1u) {
        let curve = points + band_curve(blob, vlist, i);
        let p1 = glyph_point(curve, 0u, quant) - render_coord;
        let p2 = glyph_point(curve, 1u, quant) - render_coord;
        let p3 = glyph_point(curve, 2u, quant) - render_coord;
        let p12 = vec4f(p1, p2);

        if max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5 {
            break;
        }

        let code = calc_root_code(p12.x, p12.z, p3.x);
        if code != 0u {
            let r = solve_vert_poly(p12, p3) * pixels_per_em.y;
            if (code & 1u) != 0u {
                ycov = ycov - clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if code > 1u {
                ycov = ycov + clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calc_coverage(xcov, ycov, xwgt, ywgt);
}

fn shade_linear(in: VsOut) -> vec4f {
    let coverage = slug_render(in.texcoord, in.banding, in.glyph, in.quant);
    let alpha = in.color.a * coverage * clipAlpha(in.world_pos, in.clip_node);
    return vec4f(in.color.rgb * alpha, alpha);
}

fn linear_to_srgb(c: vec3f) -> vec3f {
    let cutoff = c <= vec3f(0.0031308);
    let lo = 12.92 * c;
    let hi = 1.055 * pow(c, vec3f(1.0 / 2.4)) - 0.055;
    return select(hi, lo, cutoff);
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4f {
    return shade_linear(in);
}

@fragment
fn fs_main_srgb_encode(in: VsOut) -> @location(0) vec4f {
    let c = shade_linear(in);
    return vec4f(linear_to_srgb(c.rgb), c.a);
}
