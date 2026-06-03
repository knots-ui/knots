// glsl port of the Slug analytic font rendering algorithm.
// Reference: https://github.com/EricLengyel/Slug/tree/main

#version 450
#extension GL_EXT_samplerless_texture_functions : require

layout(constant_id = 0) const bool apply_srgb_encode = false;

const uint LOG_BAND_TEXTURE_WIDTH = 12u;

layout(set = 1, binding = 0) uniform texture2D curve_texture;
layout(set = 1, binding = 1) uniform utexture2D band_texture;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_texcoord;
layout(location = 2) flat in vec4 in_banding;
layout(location = 3) flat in ivec4 in_glyph;
layout(location = 4) in vec2 in_world_pos;
layout(location = 5) in float in_clip_node;

layout(location = 0) out vec4 frag_color;

uint calc_root_code(float y1, float y2, float y3) {
    uint i1 = floatBitsToUint(y1) >> 31u;
    uint i2 = floatBitsToUint(y2) >> 30u;
    uint i3 = floatBitsToUint(y3) >> 29u;

    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return (0x2E74u >> shift) & 0x0101u;
}

const uint MAX_CLIP_DEPTH = 32u;

struct ClipNode {
    vec4 rect;
    vec4 radii;
    uint parent;
    uint pad0;
    uint pad1;
    uint pad2;
};

layout(set = 2, binding = 0, std430) readonly buffer ClipNodes {
    ClipNode clip_nodes[];
};

vec4 normalizedRadii(vec4 radii, vec2 size) {
    vec4 r = max(radii, vec4(0.0));
    float scale = 1.0;
    if (r.x + r.y > size.x && r.x + r.y > 0.0) {
        scale = min(scale, size.x / (r.x + r.y));
    }
    if (r.y + r.z > size.y && r.y + r.z > 0.0) {
        scale = min(scale, size.y / (r.y + r.z));
    }
    if (r.z + r.w > size.x && r.z + r.w > 0.0) {
        scale = min(scale, size.x / (r.z + r.w));
    }
    if (r.w + r.x > size.y && r.w + r.x > 0.0) {
        scale = min(scale, size.y / (r.w + r.x));
    }
    return r * scale;
}

float cornerRadius(vec2 p, vec4 radii) {
    if (p.y < 0.0) {
        if (p.x < 0.0) return radii.x;
        return radii.y;
    }
    if (p.x >= 0.0) return radii.z;
    return radii.w;
}

float sdRoundedBox(vec2 p, vec2 half_size, vec4 radii) {
    float radius = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    vec2 q = abs(p) - half_size + radius;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

float clipAlpha(vec2 world_pos, float clip_node) {
    uint idx = uint(clip_node + 0.5);
    float alpha = 1.0;
    for (uint i = 0u; i < MAX_CLIP_DEPTH && idx != 0u; i++) {
        ClipNode node = clip_nodes[idx];
        vec2 half_size = node.rect.zw * 0.5;
        vec2 center = node.rect.xy + half_size;
        float d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha *= 1.0 - smoothstep(-0.5, 0.5, d);
        idx = node.parent;
    }
    return idx == 0u ? alpha : 0.0;
}

vec2 solve_horiz_poly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;

    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) {
        float tt = p12.y * rb;
        t1 = tt;
        t2 = tt;
    }

    return vec2(
        (a.x * t1 - b.x * 2.0) * t1 + p12.x,
        (a.x * t2 - b.x * 2.0) * t2 + p12.x
    );
}

vec2 solve_vert_poly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;

    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) {
        float tt = p12.x * rb;
        t1 = tt;
        t2 = tt;
    }

    return vec2(
        (a.y * t1 - b.y * 2.0) * t1 + p12.y,
        (a.y * t2 - b.y * 2.0) * t2 + p12.y
    );
}

ivec2 offset_texture_loc(ivec2 base, int offset) {
    int mask = (1 << LOG_BAND_TEXTURE_WIDTH) - 1;
    ivec2 loc = ivec2(base.x + offset, base.y);
    loc.y += loc.x >> int(LOG_BAND_TEXTURE_WIDTH);
    loc.x &= mask;
    return loc;
}

ivec2 calc_band_loc(ivec2 glyph_loc, uint offset) {
    return offset_texture_loc(glyph_loc, int(offset));
}

float calc_coverage(float xcov, float ycov, float xwgt, float ywgt) {
    float combined = abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0);
    float alt = min(abs(xcov), abs(ycov));
    return clamp(max(combined, alt), 0.0, 1.0);
}

float slug_render(vec2 render_coord, vec4 banding, ivec4 glyph_data) {
    vec2 ems_per_pixel = fwidth(render_coord);
    vec2 pixels_per_em = vec2(1.0) / ems_per_pixel;

    ivec2 band_max = glyph_data.zw;
    band_max.y = band_max.y & 0x00FF;

    ivec2 band_index = ivec2(render_coord * banding.xy + banding.zw);
    band_index = clamp(band_index, ivec2(0), band_max);
    ivec2 glyph_loc = glyph_data.xy;

    float xcov = 0.0;
    float xwgt = 0.0;

    uvec2 hband = texelFetch(band_texture, offset_texture_loc(glyph_loc, band_index.y), 0).xy;
    int hcount = int(hband.x);
    ivec2 hloc = calc_band_loc(glyph_loc, hband.y);

    for (int i = 0; i < hcount; i++) {
        ivec2 curve_loc = ivec2(texelFetch(band_texture, offset_texture_loc(hloc, i), 0).xy);
        vec4 p12 = texelFetch(curve_texture, curve_loc, 0) - vec4(render_coord, render_coord);
        vec2 p3 = texelFetch(curve_texture, offset_texture_loc(curve_loc, 1), 0).xy - render_coord;

        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) break;

        uint code = calc_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            vec2 r = solve_horiz_poly(p12, p3) * pixels_per_em.x;
            if ((code & 1u) != 0u) {
                xcov += clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                xcov -= clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float ycov = 0.0;
    float ywgt = 0.0;

    uvec2 vband = texelFetch(band_texture, offset_texture_loc(glyph_loc, band_max.y + 1 + band_index.x), 0).xy;
    int vcount = int(vband.x);
    ivec2 vloc = calc_band_loc(glyph_loc, vband.y);

    for (int i = 0; i < vcount; i++) {
        ivec2 curve_loc = ivec2(texelFetch(band_texture, offset_texture_loc(vloc, i), 0).xy);
        vec4 p12 = texelFetch(curve_texture, curve_loc, 0) - vec4(render_coord, render_coord);
        vec2 p3 = texelFetch(curve_texture, offset_texture_loc(curve_loc, 1), 0).xy - render_coord;

        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) break;

        uint code = calc_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            vec2 r = solve_vert_poly(p12, p3) * pixels_per_em.y;
            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                ycov += clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calc_coverage(xcov, ycov, xwgt, ywgt);
}

vec3 linear_to_srgb(vec3 c) {
    bvec3 cutoff = lessThanEqual(c, vec3(0.0031308));
    vec3 lo = 12.92 * c;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

void main() {
    float coverage = slug_render(in_texcoord, in_banding, in_glyph);
    float alpha = in_color.a * coverage * clipAlpha(in_world_pos, in_clip_node);
    vec4 col = vec4(in_color.rgb * alpha, alpha);
    if (apply_srgb_encode) {
        frag_color = vec4(linear_to_srgb(col.rgb), col.a);
    } else {
        frag_color = col;
    }
}
